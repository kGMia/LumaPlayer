/* SPDX-License-Identifier: GPL-3.0-or-later
 * Separate mpv build. One serial worker, one job, <=8 ready + <=8 worker output frames.
 * The worker never accesses mpv pins; reset invalidates results by generation.
 * CPU conversion/copies remain explicit. No IINA.app replacement or zero-copy claim.
 */
#include <math.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <time.h>
#include <CoreVideo/CoreVideo.h>
#include "common/common.h"
#include "common/msg.h"
#include "common/tags.h"
#include "filters/filter.h"
#include "filters/filter_internal.h"
#include "filters/user_filters.h"
#include "options/m_option.h"
#include "video/mp_image.h"
#include "video/img_format.h"
#include "video/sws_utils.h"
#include "IIVEApple.h"
#include "IIVEFSR.h"
#include "iive_surface.h"
#include "iive_latency.h"
#include "iive_profile.h"
#include "iive_queue_budget.h"
#include "iive_preroll.h"
#define CAPACITY 8
struct opts { int mode, prefetch; float scale; float split; bool fallback; };
struct batch {struct mp_frame frames[CAPACITY]; bool synthesized[CAPACITY]; double enqueued[CAPACITY]; int count;};
struct engine {
    struct mp_sws_context *sws;
    struct iive_normalizer normalizer;
    double input_ms, model_ms, output_ms;
    bool timing_valid;
    double gpu_span_ms, cpu_wait_ms;
    void *stream;
    struct mp_image *previous;
    CVPixelBufferRef previous_pixels, cached_input, cached_output;
    bool cached_left;
    float cached_split;
    uint64_t reused_outputs, preroll_bypassed;
    int width, height, bad, pairs, mode;
    bool fallback, input_left;
    uint64_t shared_inputs, copied_inputs, normalized_inputs;
    const char *input_surface;
    const char *state;
};
struct priv {
    struct opts *opts;
    pthread_t thread;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    bool started, stop, busy, reset_pending, input_ended;
    struct mp_frame job;
    struct batch ready;
    uint64_t generation, job_generation, emitted, generated, stale;
    double speed, job_speed, last_ms, total_ms, peak_ms;
    struct iive_latency_window latency;
    struct iive_profile_stages profile;
    double submitted_at;
    uint64_t output_frame_bytes;
    int memory_prefetch_limit, effective_prefetch_limit;
    struct iive_queue_timeline queue_timeline;
    double queue_ahead_ms, queue_budget_ms;
    bool time_prefetch_blocked;
    uint64_t time_prefetch_deferrals;
    float split, job_split;
    uint64_t jobs, shared_inputs, copied_inputs, normalized_inputs, reused_outputs, preroll_bypassed;
    double input_ms, model_ms, output_ms;
    bool timing_valid;
    double gpu_span_ms, cpu_wait_ms;
    const char *input_surface;
    const char *state;
};
static double seconds(void) {struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static void discard(struct batch *b) {for(int i=0;i<b->count;i++)mp_frame_unref(&b->frames[i]);memset(b,0,sizeof(*b));}
static bool append(struct batch *b, struct mp_frame frame, bool synthesized) {
    if(b->count==CAPACITY){mp_frame_unref(&frame);return false;}
    b->frames[b->count]=frame;b->synthesized[b->count++]=synthesized;return true;
}
static void clear_engine(struct engine *e, bool destroy) {
    if(e->cached_input)CVPixelBufferRelease(e->cached_input);
    if(e->cached_output)CVPixelBufferRelease(e->cached_output);
    e->cached_input=e->cached_output=NULL;
    TA_FREEP(&e->previous);
    if(e->previous_pixels)CVPixelBufferRelease(e->previous_pixels);
    e->previous_pixels=NULL;
    if(destroy){
        if(e->mode>=2)iive_fsr_destroy(e->stream);else iive_apple_destroy(e->stream);
        e->stream=NULL;iive_surface_normalizer_destroy(&e->normalizer);
    } else if(e->stream) {
        if(e->mode>=2)iive_fsr_trim(e->stream);else iive_apple_trim(e->stream);
    }
    e->bad=e->pairs=0;e->fallback=false;e->state="warming";
}
static bool supported(struct mp_image *img, bool fi, int mode) {
    if(!(img->w>0 && img->h>0 && !(img->w%2) && !(img->h%2) &&
         img->params.repr.sys!=PL_COLOR_SYSTEM_DOLBYVISION && !img->params.rotate &&
         img->pts!=MP_NOPTS_VALUE && isfinite(img->pts) &&
         img->nominal_fps>0 && (!fi || img->nominal_fps<=30.01) && iive_surface_supported_input(img)))
        return false;
    if(mode>=2) {
        enum pl_color_transfer trc=img->params.color.transfer;
        if(trc==PL_COLOR_TRC_PQ || trc==PL_COLOR_TRC_HLG || trc==PL_COLOR_TRC_V_LOG ||
           trc==PL_COLOR_TRC_S_LOG1 || trc==PL_COLOR_TRC_S_LOG2)
            return false;
        return true;
    }
    return img->params.color.primaries==PL_COLOR_PRIM_BT_709 &&
        img->params.color.transfer==PL_COLOR_TRC_BT_1886;
}
// Zero-copy IOSurface acquisition for VT hwdec and upstream filters; swscale fallback into pooled NV12.
static CVPixelBufferRef convert_input(struct engine *e, struct mp_image *img) {
    e->input_left=false;
    CVPixelBufferRef shared=iive_surface_acquire(img);
    if(shared){e->shared_inputs++;e->input_surface="shared-iosurface";return shared;}
    if(e->mode>=2 && (shared=iive_surface_acquire_fsr_left(img))) {
        e->input_left=true;e->shared_inputs++;e->input_surface="fused-metal-chroma";return shared;
    }
    if(e->mode>=2 && (shared=iive_surface_acquire_fsr_p010(img,&e->input_left))) {
        e->shared_inputs++;
        e->input_surface=e->input_left?"fused-metal-p010-chroma":"shared-p010-iosurface";
        return shared;
    }
    CVPixelBufferRef pixels=e->mode>=2?iive_fsr_input(e->stream):iive_apple_input(e->stream);
    if(!pixels)return NULL;
    if(iive_surface_normalize(&e->normalizer,pixels,img)) {
        e->normalized_inputs++;e->input_surface="metal-normalized";return pixels;
    }
    e->copied_inputs++;e->input_surface="swscale-copy";
    if(CVPixelBufferLockBaseAddress(pixels,0)){CVPixelBufferRelease(pixels);return NULL;}
    struct mp_image view={0};mp_image_setfmt(&view,IMGFMT_NV12);mp_image_set_size(&view,img->w,img->h);
    view.params.color=img->params.color;view.params.repr=img->params.repr;
    view.params.chroma_location=PL_CHROMA_CENTER;
    view.params.repr.sys=PL_COLOR_SYSTEM_BT_709;view.params.repr.levels=PL_COLOR_LEVELS_LIMITED;
    for(int i=0;i<2;i++){view.planes[i]=CVPixelBufferGetBaseAddressOfPlane(pixels,i);view.stride[i]=CVPixelBufferGetBytesPerRowOfPlane(pixels,i);}
    int result=iive_surface_scale_input(e->sws,&view,img);mp_image_unref_data(&view);
    CVPixelBufferUnlockBaseAddress(pixels,0);
    if(result<0){CVPixelBufferRelease(pixels);return NULL;}
    CVBufferSetAttachment(pixels,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixels,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixels,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixels,kCVImageBufferChromaLocationTopFieldKey,kCVImageBufferChromaLocation_Center,kCVAttachmentMode_ShouldPropagate);
    return pixels;
}
static bool scene_cut(CVPixelBufferRef a,CVPixelBufferRef b) {
    if(!a||!b)return true;
    if(CVPixelBufferLockBaseAddress(a,kCVPixelBufferLock_ReadOnly))return true;
    if(CVPixelBufferLockBaseAddress(b,kCVPixelBufferLock_ReadOnly)){CVPixelBufferUnlockBaseAddress(a,kCVPixelBufferLock_ReadOnly);return true;}
    const uint8_t *pa=CVPixelBufferGetBaseAddressOfPlane(a,0),*pb=CVPixelBufferGetBaseAddressOfPlane(b,0);
    int w=CVPixelBufferGetWidth(a),h=CVPixelBufferGetHeight(a),sa=CVPixelBufferGetBytesPerRowOfPlane(a,0),sb=CVPixelBufferGetBytesPerRowOfPlane(b,0);
    double sum=0;int count=0;for(int y=0;y<h;y+=32)for(int x=0;x<w;x+=32){sum+=abs(pa[y*sa+x]-pb[y*sb+x]);count++;}
    CVPixelBufferUnlockBaseAddress(a,kCVPixelBufferLock_ReadOnly);CVPixelBufferUnlockBaseAddress(b,kCVPixelBufferLock_ReadOnly);
    return count && sum/count>45;
}
static void tail(struct engine *e, struct batch *b) {
    if(e->previous){
        struct mp_image *out=e->previous;
        if(e->previous_pixels){
            struct mp_image *wrapped=iive_surface_wrap(CVPixelBufferRetain(e->previous_pixels),out);
            if(wrapped){talloc_free(out);out=wrapped;}
        }
        append(b,(struct mp_frame){MP_FRAME_VIDEO,out},false);e->previous=NULL;
    }
}
// Reset may race a model compile/conversion. Check between expensive stages;
// already-submitted GPU work is allowed to finish and is discarded by the worker.
static bool job_canceled(struct priv *p, uint64_t generation) {
    pthread_mutex_lock(&p->mutex);
    bool canceled=p->stop || p->generation!=generation;
    pthread_mutex_unlock(&p->mutex);
    return canceled;
}
static void run_job(struct engine *e,const struct opts *o,struct mp_frame frame,double speed,float split,struct batch *b,struct priv *p,uint64_t generation) {
    if(job_canceled(p,generation)){mp_frame_unref(&frame);return;}
    bool fi=o->mode==1;
    if(mp_frame_is_signaling(frame)) {bool degraded=e->fallback;tail(e,b);clear_engine(e,false);e->fallback=degraded;e->state=degraded?"degraded-finished":"finished";append(b,frame,false);return;}
    if(frame.type!=MP_FRAME_VIDEO){append(b,frame,false);return;}
    struct mp_image *img=frame.data;bool usable=supported(img,fi,e->mode);
    if(e->stream && (img->w!=e->width || img->h!=e->height || !usable ||
        (e->previous && (img->pts<=e->previous->pts || img->pts-e->previous->pts>IIVE_MAX_PAIR_SPAN ||
        img->params.color.transfer!=e->previous->params.color.transfer ||
        img->params.color.primaries!=e->previous->params.color.primaries ||
        img->params.repr.sys!=e->previous->params.repr.sys ||
        img->params.repr.levels!=e->previous->params.repr.levels ||
        img->params.chroma_location!=e->previous->params.chroma_location)))) {tail(e,b);clear_engine(e,true);}
    if(!usable){e->state="bypassed-format";append(b,frame,false);return;}
    if(e->fallback){append(b,frame,false);return;}
    if(img->iive_preroll) {
        if(e->previous){tail(e,b);clear_engine(e,false);}
        e->preroll_bypassed++;e->state="seek-preroll";append(b,frame,false);return;
    }
    double start=seconds();
    if(!e->stream){e->width=img->w;e->height=img->h;e->stream=e->mode>=2?iive_fsr_create(img->w,img->h,e->mode==2?8:16):iive_apple_create(img->w,img->h,fi,o->scale);}
    if(!e->stream){e->fallback=true;e->state="unsupported-or-model-unavailable";append(b,frame,false);return;}
    if(job_canceled(p,generation)){mp_frame_unref(&frame);return;}
    double phase=seconds();
    CVPixelBufferRef input=convert_input(e,img);
    e->input_ms=(seconds()-phase)*1000;
    if(!input){tail(e,b);clear_engine(e,true);e->fallback=true;e->state="error-bypass";append(b,frame,false);return;}
    if(job_canceled(p,generation)){CVPixelBufferRelease(input);mp_frame_unref(&frame);return;}
    bool cut=fi&&e->previous&&scene_cut(input,e->previous_pixels);
    bool needs_output=!fi || (e->previous && !cut);
    struct mp_image *out=NULL;
    if(needs_output) {
        phase=seconds();
        CVPixelBufferRef pixels=NULL;
        // Frame holds emitted by interpolation can reference the exact same retained
        // immutable surface. FSRCNNX is spatial: reuse its result, with fresh mpv PTS.
        if(e->mode>=2 && input==e->cached_input && e->input_left==e->cached_left && fabsf(split-e->cached_split)<1e-4f && e->cached_output) {
            pixels=CVPixelBufferRetain(e->cached_output);e->reused_outputs++;
        } else {
            pixels=e->mode>=2?iive_fsr_process_split(e->stream,input,e->input_left,split):iive_apple_process(e->stream,input,e->previous_pixels,img->pts,e->previous?e->previous->pts:0);
            if(e->mode>=2) {
                if(pixels)e->timing_valid=iive_fsr_timing(e->stream,&e->gpu_span_ms,&e->cpu_wait_ms)==1;
                if(e->cached_input)CVPixelBufferRelease(e->cached_input);
                if(e->cached_output)CVPixelBufferRelease(e->cached_output);
                e->cached_input=e->cached_output=NULL;
                // Resolution-only memory policy; P95 is not consulted here.
                // Avoid retaining another large SR surface for inputs above 1080p.
                bool allow_sr_cache = (e->width * e->height <= 1920 * 1080);
                if(allow_sr_cache && pixels && (!strcmp(e->input_surface,"shared-iosurface") ||
                              !strcmp(e->input_surface,"fused-metal-chroma") ||
                              !strcmp(e->input_surface,"shared-p010-iosurface") ||
                              !strcmp(e->input_surface,"fused-metal-p010-chroma"))) {
                    e->cached_input=CVPixelBufferRetain(input);e->cached_output=CVPixelBufferRetain(pixels);e->cached_left=e->input_left;e->cached_split=split;
                }
            }
        }
        e->model_ms=(seconds()-phase)*1000;phase=seconds();
        if(job_canceled(p,generation)){
            if(pixels)CVPixelBufferRelease(pixels);
            CVPixelBufferRelease(input);mp_frame_unref(&frame);return;
        }
        out=iive_surface_wrap(pixels,img);
        e->output_ms=(seconds()-phase)*1000;
    }
    e->pairs++;
    double budget=1.0/img->nominal_fps/speed;
    if(o->fallback && e->pairs>48)e->bad=seconds()-start>budget*1.25?e->bad+1:(e->bad>0?e->bad-1:0);
    if((needs_output&&!out) || e->bad>=8) {
        bool error=!out; talloc_free(out);CVPixelBufferRelease(input);tail(e,b);clear_engine(e,true);
        e->fallback=true;e->state=error?"error-bypass":"degraded";append(b,frame,false);return;
    }
    if(fi) {
        if(e->previous) {
            double mid=(e->previous->pts+img->pts)/2;
            e->previous->nominal_fps=img->nominal_fps*2;
            e->previous->pkt_duration=mid-e->previous->pts;
            if(cut) {out=iive_surface_wrap(CVPixelBufferRetain(e->previous_pixels),e->previous);if(out)out->pts=mid;}
            else if(out) {out->pts=mid;out->dts=MP_NOPTS_VALUE;out->nominal_fps=img->nominal_fps*2;out->pkt_duration=img->pts-mid;}
            tail(e,b);if(out)append(b,(struct mp_frame){MP_FRAME_VIDEO,out},!cut);
        }
        if(e->previous_pixels)CVPixelBufferRelease(e->previous_pixels);
        e->previous_pixels=input;e->previous=img;
        e->state=cut?"scene-cut-hold":out?"active":"warming";
    } else {
        CVPixelBufferRelease(input);talloc_free(img);append(b,(struct mp_frame){MP_FRAME_VIDEO,out},false);e->state="active";
    }
}
static void *worker(void *arg)
{
    struct mp_filter *f=arg;struct priv *p=f->priv;
    struct engine e={.sws=mp_sws_alloc(NULL),.state="warming",.mode=p->opts->mode};e.sws->log=f->log;
    pthread_mutex_lock(&p->mutex);
    while(!p->stop) {
        while(!p->stop && !p->job.type && !p->reset_pending)pthread_cond_wait(&p->cond,&p->mutex);
        if(p->stop)break;
        if(p->reset_pending){
            p->reset_pending=false;pthread_mutex_unlock(&p->mutex);
            clear_engine(&e,false);pthread_mutex_lock(&p->mutex);continue;
        }
        struct mp_frame frame=p->job;p->job=MP_NO_FRAME;
        uint64_t generation=p->job_generation;double speed=p->job_speed;float split=p->job_split;
        double dispatch_ms=(seconds()-p->submitted_at)*1000;
        double input_pts=frame.type==MP_FRAME_VIDEO?((struct mp_image *)frame.data)->pts:MP_NOPTS_VALUE;
        pthread_mutex_unlock(&p->mutex);
        struct batch b={0};e.timing_valid=false;e.gpu_span_ms=e.cpu_wait_ms=-1;e.input_ms=e.model_ms=e.output_ms=0;double start=seconds();run_job(&e,p->opts,frame,speed,split,&b,p,generation);
        double finished=seconds(),ms=(finished-start)*1000;
        pthread_mutex_lock(&p->mutex);
        // One completed worker batch may wait behind the bounded ready queue.
        // Consumption, seek/reset and shutdown all signal this condition.
        while(!p->stop && generation==p->generation && b.count>CAPACITY-p->ready.count)
            pthread_cond_wait(&p->cond,&p->mutex);
        p->busy=false;
        if(generation!=p->generation || p->stop){p->stale++;discard(&b);}
        else {
            uint64_t output_bytes=0;
            for(int i=0;i<b.count;i++)if(b.frames[i].type==MP_FRAME_VIDEO) {
                struct mp_image *img=b.frames[i].data;
                uint64_t bytes=iive_queue_frame_estimate(img->w,img->h);
                if(bytes>output_bytes)output_bytes=bytes;
            }
            if(output_bytes)p->output_frame_bytes=output_bytes;
            for(int i=0;i<b.count;i++) {
                p->ready.frames[p->ready.count]=b.frames[i];
                p->ready.enqueued[p->ready.count]=seconds();
                p->ready.synthesized[p->ready.count++]=b.synthesized[i];
            }
            p->reused_outputs=e.reused_outputs;p->state=e.state;p->shared_inputs=e.shared_inputs;p->copied_inputs=e.copied_inputs;p->normalized_inputs=e.normalized_inputs;p->input_ms=e.input_ms;p->model_ms=e.model_ms;p->output_ms=e.output_ms;p->input_surface=e.input_surface;p->last_ms=ms;
            p->preroll_bypassed=e.preroll_bypassed;
            if(strcmp(e.state,"seek-preroll")) {
                p->total_ms+=ms;p->peak_ms=fmax(p->peak_ms,ms);p->jobs++;
            }
            p->timing_valid=e.timing_valid && !e.fallback;
            p->gpu_span_ms=e.gpu_span_ms;p->cpu_wait_ms=e.cpu_wait_ms;
            double backpressure_ms=(seconds()-finished)*1000;
            iive_latency_add(&p->profile.dispatch,dispatch_ms);
            iive_latency_add(&p->profile.backpressure,backpressure_ms);
            if((unsigned)p->ready.count>p->profile.ready_peak)p->profile.ready_peak=p->ready.count;
            if(iive_profile_enabled()) {
                char gpu[40]="null",wait[40]="null";
                if(p->timing_valid) {
                    snprintf(gpu,sizeof(gpu),"%.6f",p->gpu_span_ms);
                    snprintf(wait,sizeof(wait),"%.6f",p->cpu_wait_ms);
                }
                MP_INFO(f,"IIVE_PROFILE {\"stage\":\"%s\",\"event\":\"job\",\"generation\":%llu,\"job\":%llu,\"pts\":%.9f,\"time_s\":%.9f,\"state\":\"%s\",\"outputs\":%d,\"dispatch_ms\":%.6f,\"processing_ms\":%.6f,\"input_ms\":%.6f,\"model_call_ms\":%.6f,\"gpu_span_ms\":%s,\"cpu_wait_ms\":%s,\"output_ms\":%.6f,\"backpressure_ms\":%.6f}\n",
                    (p->opts->mode==1?"apple-fi":"sr"),(unsigned long long)p->generation,(unsigned long long)p->jobs,
                    input_pts,seconds(),e.state,b.count,dispatch_ms,ms,e.input_ms,e.model_ms,gpu,wait,e.output_ms,backpressure_ms);
            }

            // Exclude EOF, warm-up without output, bypass and canceled generations.
            // A job may generate several frames; this is not per-output-frame latency.
            if(frame.type==MP_FRAME_VIDEO && b.count>0 &&
               (!strcmp(e.state,"active") || !strcmp(e.state,"scene-cut-hold")))
                iive_latency_add(&p->latency,ms);
        }
        mp_filter_wakeup(f);
    }
    mp_frame_unref(&p->job);pthread_mutex_unlock(&p->mutex);
    clear_engine(&e,true);iive_surface_normalizer_destroy(&e.normalizer);talloc_free(e.sws);return NULL;
}
static void reset(struct mp_filter *f)
{
    struct priv *p=f->priv;pthread_mutex_lock(&p->mutex);
    p->timing_valid=false;
    p->generation++;p->input_ended=false;discard(&p->ready);
    p->output_frame_bytes=0;p->memory_prefetch_limit=p->effective_prefetch_limit=0;
    memset(&p->profile,0,sizeof(p->profile));
    memset(&p->queue_timeline,0,sizeof(p->queue_timeline));
    p->queue_ahead_ms=p->queue_budget_ms=-1;p->time_prefetch_blocked=false;
    p->time_prefetch_deferrals=0;
    iive_latency_reset(&p->latency);
    if(p->job.type){mp_frame_unref(&p->job);p->busy=false;}
    p->reset_pending=true;p->state="warming";
    pthread_cond_signal(&p->cond);pthread_mutex_unlock(&p->mutex);
}
static void process(struct mp_filter *f)
{
    struct priv *p=f->priv;
    if(!mp_pin_in_needs_data(f->ppins[1]))return;
    pthread_mutex_lock(&p->mutex);
    struct mp_frame output=MP_NO_FRAME;
    if(p->ready.count) {
        output=p->ready.frames[0];bool synth=p->ready.synthesized[0];
        double ready_ms=(seconds()-p->ready.enqueued[0])*1000;
        memmove(p->ready.enqueued,p->ready.enqueued+1,(p->ready.count-1)*sizeof(double));
        memmove(p->ready.frames,p->ready.frames+1,(p->ready.count-1)*sizeof(struct mp_frame));
        memmove(p->ready.synthesized,p->ready.synthesized+1,(p->ready.count-1)*sizeof(bool));p->ready.count--;
        if(output.type==MP_FRAME_VIDEO){
            struct mp_image *delivered=output.data;
            iive_queue_note_output(&p->queue_timeline,
                delivered->pts==MP_NOPTS_VALUE?NAN:delivered->pts,delivered->nominal_fps);
            p->emitted++;p->generated+=synth;
            iive_latency_add(&p->profile.ready,ready_ms);
            if(iive_profile_enabled())MP_INFO(f,"IIVE_PROFILE {\"stage\":\"%s\",\"event\":\"output\",\"generation\":%llu,\"pts\":%.9f,\"time_s\":%.9f,\"ready_ms\":%.6f,\"queued\":%d,\"synthesized\":%d}\n",
                (p->opts->mode==1?"apple-fi":"sr"),(unsigned long long)p->generation,((struct mp_image*)output.data)->pts,seconds(),ready_ms,p->ready.count,synth);

            MP_VERBOSE(f,"output pts=%.9f synthesized=%d generation=%llu\n",((struct mp_image*)output.data)->pts,synth,(unsigned long long)p->generation);
        }
        pthread_cond_signal(&p->cond);
    }
    // Start the next input while downstream processes the emitted frame. At
    // most one job is in flight; a full ready queue applies backpressure above.
    uint64_t frame_bytes=p->output_frame_bytes;
    // A resolution change may leave larger old frames in the ready queue.
    for(int i=0;i<p->ready.count;i++)if(p->ready.frames[i].type==MP_FRAME_VIDEO) {
        struct mp_image *img=p->ready.frames[i].data;
        uint64_t bytes=iive_queue_frame_estimate(img->w,img->h);
        if(bytes>frame_bytes)frame_bytes=bytes;
    }
    p->memory_prefetch_limit=iive_queue_prefetch_limit(frame_bytes,p->opts->mode==1?3:2,CAPACITY/2);
    int requested_prefetch=p->opts->prefetch?p->opts->prefetch:CAPACITY/2;
    int max_prefetch=p->memory_prefetch_limit<requested_prefetch?p->memory_prefetch_limit:requested_prefetch;
    p->effective_prefetch_limit=max_prefetch;
    double p50_est=0,p95_est=-1;
    if(!p->busy && !p->input_ended && !p->opts->prefetch && p->latency.count>=8)
        iive_latency_read(&p->latency,&p50_est,&p95_est);
    double tail_pts=NAN;
    for(int i=0;i<p->ready.count;i++) {
        // An EOF/non-video tail cannot supply a future presentation timestamp.
        if(p->ready.frames[i].type==MP_FRAME_VIDEO) {
            double pts=((struct mp_image *)p->ready.frames[i].data)->pts;
            tail_pts=pts==MP_NOPTS_VALUE?NAN:pts;
        } else tail_pts=NAN;
    }
    bool time_admit=iive_queue_time_admit(&p->queue_timeline,tail_pts,p->ready.count,
        p->speed,p95_est,&p->queue_ahead_ms,&p->queue_budget_ms);
    // Fixed prefetch remains an explicit diagnostics override, still memory-bound.
    p->time_prefetch_blocked=!p->opts->prefetch && !time_admit;
    if(!p->busy && !p->input_ended && p->time_prefetch_blocked)p->time_prefetch_deferrals++;
    if(!p->busy && !p->input_ended && p->ready.count<=max_prefetch && !p->time_prefetch_blocked) {
        struct mp_frame frame=mp_pin_out_read(f->ppins[0]);
        if(frame.type){
            p->submitted_at=seconds();
            p->job=frame;p->busy=true;p->job_generation=p->generation;p->job_speed=p->speed;p->job_split=p->split;
            if(frame.type==MP_FRAME_EOF)p->input_ended=true;
            pthread_cond_signal(&p->cond);
        }
    }
    pthread_mutex_unlock(&p->mutex);
    if(output.type)mp_pin_in_write(f->ppins[1],output);
}
static bool command(struct mp_filter *f, struct mp_filter_command *cmd)
{
    struct priv *p=f->priv;
    if(cmd->type==MP_FILTER_COMMAND_TEXT && !strcmp(cmd->cmd,"speed")){
        char *end;double speed=strtod(cmd->arg?cmd->arg:"",&end);
        if(!cmd->arg || end==cmd->arg || *end || !isfinite(speed) || speed<=0)return false;
        pthread_mutex_lock(&p->mutex);p->speed=speed;pthread_mutex_unlock(&p->mutex);return true;
    }
    if(cmd->type==MP_FILTER_COMMAND_TEXT && !strcmp(cmd->cmd,"split")){
        char *end;double split=strtod(cmd->arg?cmd->arg:"",&end);
        if(!cmd->arg || end==cmd->arg || *end || !isfinite(split) || split<0 || split>1)return false;
        pthread_mutex_lock(&p->mutex);p->split=(float)split;pthread_mutex_unlock(&p->mutex);return true;
    }
    if(cmd->type!=MP_FILTER_COMMAND_GET_META)return false;
    struct mp_tags *tags=talloc_zero(NULL,struct mp_tags);pthread_mutex_lock(&p->mutex);
    mp_tags_set_str(tags,"state",p->state);
    mp_tags_set_str(tags,"input_surface",p->input_surface?p->input_surface:"pending");
    mp_tags_set_str(tags,"reused_outputs",mp_tprintf(32,"%llu",(unsigned long long)p->reused_outputs));
    mp_tags_set_str(tags,"preroll_bypassed",mp_tprintf(32,"%llu",(unsigned long long)p->preroll_bypassed));
    mp_tags_set_str(tags,"shared_inputs",mp_tprintf(32,"%llu",(unsigned long long)p->shared_inputs));
    mp_tags_set_str(tags,"copied_inputs",mp_tprintf(32,"%llu",(unsigned long long)p->copied_inputs));
    mp_tags_set_str(tags,"backend",p->opts->mode==2?"fsrcnnx8-mpsgraph":p->opts->mode==3?"fsrcnnx16-mpsgraph":"apple-videotoolbox");
    mp_tags_set_str(tags,"split_ratio",mp_tprintf(32,"%.3f",p->split));
    mp_tags_set_str(tags,"generated",mp_tprintf(32,"%llu",(unsigned long long)p->generated));
    mp_tags_set_str(tags,"emitted",mp_tprintf(32,"%llu",(unsigned long long)p->emitted));
    mp_tags_set_str(tags,"generation",mp_tprintf(32,"%llu",(unsigned long long)p->generation));
    mp_tags_set_str(tags,"stale_jobs_discarded",mp_tprintf(32,"%llu",(unsigned long long)p->stale));
    mp_tags_set_str(tags,"queued",mp_tprintf(32,"%d",p->ready.count));
    if(p->queue_ahead_ms>=0)mp_tags_set_str(tags,"queue_ahead_ms",mp_tprintf(32,"%.3f",p->queue_ahead_ms));
    if(p->queue_budget_ms>=0)mp_tags_set_str(tags,"queue_budget_ms",mp_tprintf(32,"%.3f",p->queue_budget_ms));
    mp_tags_set_str(tags,"time_prefetch_blocked",p->time_prefetch_blocked?"1":"0");
    mp_tags_set_str(tags,"time_prefetch_deferrals",mp_tprintf(32,"%llu",(unsigned long long)p->time_prefetch_deferrals));
    mp_tags_set_str(tags,"queue_surface_target_bytes",mp_tprintf(32,"%llu",(unsigned long long)IIVE_QUEUE_SURFACE_TARGET));
    mp_tags_set_str(tags,"queue_frame_estimate_bytes",mp_tprintf(32,"%llu",(unsigned long long)p->output_frame_bytes));
    mp_tags_set_str(tags,"memory_prefetch_limit",mp_tprintf(32,"%d",p->memory_prefetch_limit));
    mp_tags_set_str(tags,"queue_reserved_frames",mp_tprintf(32,"%d",p->opts->mode==1?3:2));
    mp_tags_set_str(tags,"inflight",p->busy?"1":"0");
    mp_tags_set_str(tags,"normalized_inputs",mp_tprintf(32,"%llu",(unsigned long long)p->normalized_inputs));
    mp_tags_set_str(tags,"input_ms",mp_tprintf(32,"%.3f",p->input_ms));
    mp_tags_set_str(tags,"model_call_ms",mp_tprintf(32,"%.3f",p->model_ms));
    if(p->timing_valid) {
        mp_tags_set_str(tags,"gpu_span_ms",mp_tprintf(32,"%.3f",p->gpu_span_ms));
        mp_tags_set_str(tags,"cpu_wait_ms",mp_tprintf(32,"%.3f",p->cpu_wait_ms));
    }
    mp_tags_set_str(tags,"output_ms",mp_tprintf(32,"%.3f",p->output_ms));
    mp_tags_set_str(tags,"processing_ms",mp_tprintf(32,"%.3f",p->last_ms));
    mp_tags_set_str(tags,"mean_processing_ms",mp_tprintf(32,"%.3f",p->jobs?p->total_ms/p->jobs:0));
    mp_tags_set_str(tags,"peak_processing_ms",mp_tprintf(32,"%.3f",p->peak_ms));
    mp_tags_set_str(tags,"latency_samples",mp_tprintf(32,"%u",p->latency.count));
    mp_tags_set_str(tags,"ready_peak",mp_tprintf(32,"%u",p->profile.ready_peak));
    mp_tags_set_str(tags,"prefetch_mode",p->opts->prefetch?"fixed":"default");
    mp_tags_set_str(tags,"prefetch_limit",mp_tprintf(32,"%d",p->effective_prefetch_limit));
    struct iive_latency_window *stages[]={&p->profile.dispatch,&p->profile.ready,&p->profile.backpressure};
    const char *names[]={"p95_dispatch_ms","p95_ready_ms","p95_backpressure_ms"};
    for(int i=0;i<3;i++) {double median,tail;
        if(iive_latency_read(stages[i],&median,&tail))mp_tags_set_str(tags,names[i],mp_tprintf(32,"%.3f",tail));
    }

    double p50,p95;
    if(iive_latency_read(&p->latency,&p50,&p95)) {
        mp_tags_set_str(tags,"p50_processing_ms",mp_tprintf(32,"%.3f",p50));
        mp_tags_set_str(tags,"p95_processing_ms",mp_tprintf(32,"%.3f",p95));
    }
    mp_tags_set_str(tags,"fallback",(!strncmp(p->state,"degraded",8)||!strcmp(p->state,"error-bypass"))?"yes":"no");
    pthread_mutex_unlock(&p->mutex);*(struct mp_tags**)cmd->res=tags;return true;
}
static void destroy(struct mp_filter *f)
{
    struct priv *p=f->priv;pthread_mutex_lock(&p->mutex);p->stop=true;
    pthread_cond_signal(&p->cond);pthread_mutex_unlock(&p->mutex);
    if(p->started)pthread_join(p->thread,NULL);
    discard(&p->ready);pthread_cond_destroy(&p->cond);pthread_mutex_destroy(&p->mutex);
    MP_INFO(f,"Native enhancement totals: emitted=%llu synthesized=%llu stale_jobs=%llu\n",(unsigned long long)p->emitted,(unsigned long long)p->generated,(unsigned long long)p->stale);
}
static const struct mp_filter_info info={.name="iive-apple",.priv_size=sizeof(struct priv),.process=process,.reset=reset,.destroy=destroy,.command=command};
static struct mp_filter *create(struct mp_filter *parent, void *options)
{
    struct mp_filter *f=mp_filter_create(parent,&info);
    if(!f){talloc_free(options);return NULL;}
    struct priv *p=f->priv;p->opts=talloc_steal(p,options);p->speed=1;p->split=p->opts->split;p->state="warming";
    p->opts->prefetch=iive_profile_prefetch(p->opts->prefetch);
    p->queue_ahead_ms=p->queue_budget_ms=-1;
    pthread_mutex_init(&p->mutex,NULL);pthread_cond_init(&p->cond,NULL);
    mp_filter_add_pin(f,MP_PIN_IN,"in");mp_filter_add_pin(f,MP_PIN_OUT,"out");
    if(pthread_create(&p->thread,NULL,worker,f)){talloc_free(f);return NULL;}
    p->started=true;return f;
}
#define OPT_BASE_STRUCT struct opts
static const struct m_option options[]={
    {"mode",OPT_CHOICE(mode,{"sr",0},{"fi",1})},
    {"scale",OPT_FLOAT(scale),M_RANGE(1.0,4.0)},
    {"prefetch",OPT_CHOICE(prefetch,{"auto",0},{"1",1},{"2",2},{"4",4})},
    {"fallback",OPT_BOOL(fallback)}, {0}
};
static const struct opts defaults={.mode=0,.scale=2,.split=0,.fallback=true};
const struct mp_user_filter_entry vf_iive_apple={
    .desc={.name="iive-apple",.description="Apple low-latency SDR super resolution / midpoint interpolation",
    .priv_size=sizeof(struct opts),.priv_defaults=&defaults,.options=options},.create=create,
};

// Shares the bounded worker, cancellation generation and color conversion with
// the Apple adapter; model execution is a distinct Swift/MPSGraph C ABI.
static const struct m_option fsr_options[]={
    {"tier",OPT_CHOICE(mode,{"fast",2},{"quality",3})},
    {"split",OPT_FLOAT(split),M_RANGE(0.0,1.0)},
    {"prefetch",OPT_CHOICE(prefetch,{"auto",0},{"1",1},{"2",2},{"4",4})},
    {"fallback",OPT_BOOL(fallback)}, {0}
};
static const struct opts fsr_defaults={.mode=2,.scale=2,.split=0,.fallback=true};
const struct mp_user_filter_entry vf_iive_fsrcnnx={
    .desc={.name="iive-fsrcnnx",.description="Native FSRCNNX 8/16 MPSGraph 2x SDR super resolution",
    .priv_size=sizeof(struct opts),.priv_defaults=&fsr_defaults,.options=fsr_options},.create=create,
};
