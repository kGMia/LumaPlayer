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
#include <stdatomic.h>
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
#include "IIVERIFE.h"
#include "iive_surface.h"
#include "iive_latency.h"
#include "iive_profile.h"
#include "iive_queue_budget.h"
#include "iive_preroll.h"
#define CAPACITY 8
// Unique within this process, including filter recreation and multiple windows.
static _Atomic uint64_t next_error_id;
struct opts { int fps, tier, prefetch; bool fallback; };
struct batch {struct mp_frame frames[CAPACITY]; bool synthesized[CAPACITY]; double enqueued[CAPACITY]; int count;};
struct engine {
    struct mp_sws_context *sws;
    struct iive_normalizer normalizer;
    double input_ms, model_ms, output_ms, pair_span;
    double initialization_ms, preparation_ms[5];
    bool preparation_valid, compilation_cache_hit;
    bool timing_valid;
    double gpu_span_ms, cpu_wait_ms;
    void *stream;
    CVPixelBufferPoolRef input_pool;
    struct mp_image *previous;
    int width, height, bad, pairs, tier;
    bool fallback, nv12, native_output, switching;
    double switch_started;
    uint64_t shared_inputs, copied_inputs, normalized_inputs, preroll_bypassed;
    const char *input_surface;
    const char *state;
    const char *error_stage;
    int32_t error_code, input_error;
    uint64_t error_serial;
    double error_pts;
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
    double speed, job_speed, last_ms, total_ms, peak_ms, source_fps, pair_span;
    struct iive_latency_window latency;
    struct iive_profile_stages profile;
    double submitted_at;
    uint64_t output_frame_bytes;
    int memory_prefetch_limit, effective_prefetch_limit;
    struct iive_queue_timeline queue_timeline;
    double queue_ahead_ms, queue_budget_ms;
    bool time_prefetch_blocked;
    uint64_t time_prefetch_deferrals;
    int width, height, prefetch_limit;
    int requested_tier, active_tier;
    uint64_t tier_switches;
    double tier_switch_ms;
    uint64_t jobs, shared_inputs, copied_inputs, normalized_inputs, preroll_bypassed;
    uint64_t initializations, preparation_generation;
    double initialization_ms, preparation_ms[5];
    bool preparation_valid, compilation_cache_hit;
    double input_ms, model_ms, output_ms;
    bool timing_valid;
    double gpu_span_ms, cpu_wait_ms;
    const char *state, *input_path, *output_path, *input_surface;
    const char *error_stage;
    int32_t error_code;
    uint64_t error_events, error_serial, error_generation, error_id, canceled_preparations;
    double error_pts;
};
static void record_error(struct engine *e, const char *stage, int32_t code, double pts) {
    e->error_stage=stage;e->error_code=code?code:299;e->error_pts=pts;e->error_serial++;
}
static bool output_error(int32_t *error,int32_t code) {*error=code;return false;}
static double seconds(void) {struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static void discard(struct batch *b) {for(int i=0;i<b->count;i++)mp_frame_unref(&b->frames[i]);memset(b,0,sizeof(*b));}
static bool append(struct batch *b, struct mp_frame frame, bool synthesized) {
    if(b->count==CAPACITY){mp_frame_unref(&frame);return false;}
    b->frames[b->count]=frame;b->synthesized[b->count++]=synthesized;return true;
}
static void clear_engine(struct engine *e, bool destroy) {
    TA_FREEP(&e->previous);
    if(destroy){
        iive_stream_destroy(e->stream);e->stream=NULL;
        if(e->input_pool)CFRelease(e->input_pool);e->input_pool=NULL;
        iive_surface_normalizer_destroy(&e->normalizer);
    } else {
        if(e->stream)iive_stream_reset(e->stream);
        if(e->input_pool)CVPixelBufferPoolFlush(e->input_pool,kCVPixelBufferPoolFlushExcessBuffers);
    }
    e->bad=e->pairs=0;e->pair_span=0;e->fallback=false;e->switching=false;e->switch_started=0;e->native_output=false;e->state="warming";
}
static bool supported(struct mp_image *img, int fps)
{
    return img->w > 0 && img->h > 0 && img->w <= 4096 && img->h <= 4096 &&
        (img->params.color.primaries == PL_COLOR_PRIM_BT_709 ||
         img->params.color.primaries == PL_COLOR_PRIM_DISPLAY_P3 ||
         img->params.color.primaries == PL_COLOR_PRIM_BT_2020 ||
         img->params.color.primaries == PL_COLOR_PRIM_BT_601_525 ||
         img->params.color.primaries == PL_COLOR_PRIM_BT_601_625 ||
         img->params.color.primaries == PL_COLOR_PRIM_EBU_3213) &&
        (img->params.color.transfer == PL_COLOR_TRC_BT_1886 ||
         img->params.color.transfer == PL_COLOR_TRC_SRGB ||
         img->params.color.transfer == PL_COLOR_TRC_GAMMA22 ||
         img->params.color.transfer == PL_COLOR_TRC_GAMMA28) &&
        img->params.repr.sys != PL_COLOR_SYSTEM_DOLBYVISION &&
        img->pts != MP_NOPTS_VALUE && isfinite(img->pts) &&
        img->nominal_fps > 0 && img->nominal_fps < fps &&
        !img->params.rotate && iive_surface_supported_input(img);
}

// Zero-copy IOSurface acquisition for VT hwdec and upstream filters; swscale fallback into pooled NV12/BGRA.
static CVPixelBufferRef convert_input(struct engine *p, struct mp_image *img)
{
    p->input_error=0;
    if(p->nv12) {
        CVPixelBufferRef shared=iive_surface_acquire(img);
        if(shared){p->shared_inputs++;p->input_surface="shared-iosurface";return shared;}
    }
    if(!p->input_pool) {
        int w=img->w,h=img->h,format=p->nv12?kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:kCVPixelFormatType_32BGRA;
        CFNumberRef width=CFNumberCreate(NULL,kCFNumberIntType,&w);
        CFNumberRef height=CFNumberCreate(NULL,kCFNumberIntType,&h);
        CFNumberRef pixel_format=CFNumberCreate(NULL,kCFNumberIntType,&format);
        CFDictionaryRef empty=CFDictionaryCreate(NULL,NULL,NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
        const void *keys[]={kCVPixelBufferWidthKey,kCVPixelBufferHeightKey,kCVPixelBufferPixelFormatTypeKey,kCVPixelBufferIOSurfacePropertiesKey,kCVPixelBufferMetalCompatibilityKey};
        const void *values[]={width,height,pixel_format,empty,kCFBooleanTrue};
        CFDictionaryRef attrs=CFDictionaryCreate(NULL,keys,values,5,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
        CVPixelBufferPoolCreate(NULL,NULL,attrs,&p->input_pool);
        CFRelease(width);CFRelease(height);CFRelease(pixel_format);CFRelease(empty);CFRelease(attrs);
    }
    CVPixelBufferRef buffer=NULL;
    if(!p->input_pool || CVPixelBufferPoolCreatePixelBuffer(NULL,p->input_pool,&buffer)){p->input_error=301;return NULL;}
    if(p->nv12 && iive_surface_normalize(&p->normalizer,buffer,img)) {
        p->normalized_inputs++;p->input_surface="metal-normalized";return buffer;
    }
    p->copied_inputs++;p->input_surface="swscale-copy";
    if(CVPixelBufferLockBaseAddress(buffer,0)){p->input_error=302;CVPixelBufferRelease(buffer);return NULL;}
    struct mp_image view={0};mp_image_setfmt(&view,p->nv12?IMGFMT_NV12:IMGFMT_BGRA);mp_image_set_size(&view,img->w,img->h);
    view.params.color=img->params.color;view.params.repr=img->params.repr;
    view.params.repr.sys=p->nv12?PL_COLOR_SYSTEM_BT_709:PL_COLOR_SYSTEM_RGB;
    view.params.repr.levels=p->nv12?PL_COLOR_LEVELS_LIMITED:PL_COLOR_LEVELS_FULL;
    view.params.chroma_location=PL_CHROMA_CENTER;
    if(p->nv12){
        for(int i=0;i<2;i++){view.planes[i]=CVPixelBufferGetBaseAddressOfPlane(buffer,i);view.stride[i]=CVPixelBufferGetBytesPerRowOfPlane(buffer,i);}
        CVBufferSetAttachment(buffer,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(buffer,kCVImageBufferChromaLocationTopFieldKey,kCVImageBufferChromaLocation_Center,kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(buffer,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(buffer,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    }else{view.planes[0]=CVPixelBufferGetBaseAddress(buffer);view.stride[0]=CVPixelBufferGetBytesPerRow(buffer);}
    int result=iive_surface_scale_input(p->sws,&view,img);mp_image_unref_data(&view);
    CVPixelBufferUnlockBaseAddress(buffer,0);
    if(result<0){p->input_error=303;CVPixelBufferRelease(buffer);return NULL;}return buffer;
}
static bool drain(struct engine *e, struct batch *b, struct mp_image *attributes, int count, int fps, int32_t *error)
{
    if(count<0 || count>CAPACITY-b->count)return output_error(error,401);
    for(int n=0;n<count;n++) {
        double pts;int32_t synth=0;
        CVPixelBufferRef pixels=iive_stream_pop(e->stream,&pts,&synth);
        if(!pixels)return output_error(error,402);
        if(CVPixelBufferGetPixelFormatType(pixels)==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange){
            if(synth)e->native_output=true;
            struct mp_image *out=iive_surface_wrap(pixels,attributes);
            if(!out)return output_error(error,403);
            out->pts=pts;out->dts=MP_NOPTS_VALUE;out->nominal_fps=fps;out->pkt_duration=1.0/fps;
            append(b,(struct mp_frame){MP_FRAME_VIDEO,out},synth);continue;
        }
        if(CVPixelBufferGetPixelFormatType(pixels)!=kCVPixelFormatType_32BGRA) {
            iive_rife_release_frame(pixels);return output_error(error,407);
        }
        struct mp_image *img=mp_image_alloc(IMGFMT_BGRA,e->width,e->height);
        if(!img || CVPixelBufferLockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess){
            int32_t code=img?405:404;talloc_free(img);iive_rife_release_frame(pixels);return output_error(error,code);
        }
        uint8_t *base=CVPixelBufferGetBaseAddress(pixels);size_t stride=CVPixelBufferGetBytesPerRow(pixels);
        for(int y=0;y<e->height;y++)memcpy(img->planes[0]+y*img->stride[0],base+y*stride,e->width*4);
        CVPixelBufferUnlockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly);iive_rife_release_frame(pixels);
        mp_image_copy_attributes(img,attributes);
        img->params.repr.sys=PL_COLOR_SYSTEM_RGB;img->params.repr.levels=PL_COLOR_LEVELS_FULL;
        img->pts=pts;img->dts=MP_NOPTS_VALUE;img->nominal_fps=fps;img->pkt_duration=1.0/fps;
        // FSRCNNX hooks LUMA. Return YUV to expose an actual luma plane to mpv's
        // shader pipeline; BGRA output would silently skip that shader.
        struct mp_image *yuv=mp_image_alloc(IMGFMT_NV12,e->width,e->height);
        if(!yuv){talloc_free(img);return output_error(error,404);}
        mp_image_copy_attributes(yuv,img);
        yuv->params.repr.sys=PL_COLOR_SYSTEM_BT_709;
        yuv->params.repr.levels=PL_COLOR_LEVELS_LIMITED;
        yuv->params.chroma_location=PL_CHROMA_CENTER;
        if(mp_sws_scale(e->sws,yuv,img)<0){talloc_free(img);talloc_free(yuv);return output_error(error,406);}
        talloc_free(img);
        append(b,(struct mp_frame){MP_FRAME_VIDEO,yuv},synth);
    }
    return true;
}
static void tail(struct engine *e, struct batch *b) {
    if(e->previous){
        struct mp_image *out=e->previous;
        // A bypass/tail frame retains its original format and chroma metadata.
        // It is not a normalized model output and must not be relabeled as one.
        append(b,(struct mp_frame){MP_FRAME_VIDEO,out},false);e->previous=NULL;
    }
}
// Owns frame and all engine resources. Called exclusively by the worker.
// Reset may race a model compile/conversion. Check between expensive stages;
// already-submitted GPU work is allowed to finish and is discarded by the worker.
static bool job_canceled(struct priv *p, uint64_t generation) {
    pthread_mutex_lock(&p->mutex);
    bool canceled=p->stop || p->generation!=generation;
    pthread_mutex_unlock(&p->mutex);
    return canceled;
}
struct preparation_probe {struct priv *p;uint64_t generation;};
static int32_t preparation_canceled(void *context) {
    struct preparation_probe *probe=context;
    return job_canceled(probe->p,probe->generation)?1:0;
}
static void run_job(struct engine *e, const struct opts *o, struct mp_frame frame,
                    double speed, struct batch *b, struct priv *p, uint64_t generation)
{
    if(job_canceled(p,generation)){mp_frame_unref(&frame);return;}
    if(mp_frame_is_signaling(frame)) {
        if(e->previous) {
            double d=e->previous->pkt_duration;
            if(!(d>0 && d<=1))d=1.0/e->previous->nominal_fps;
            int n=e->stream&&!e->fallback?iive_stream_finish(e->stream,e->previous->pts+d):-1;
            if(job_canceled(p,generation)){mp_frame_unref(&frame);return;}
            int32_t error=n<0 && e->stream?iive_stream_last_error(e->stream):0;
            // Reserve one batch slot for the signal. finish() returns repeated
            // holds of the last source frame, never new AI frames. For a long
            // tail, emit that source once with its original duration instead of
            // filling the batch and silently dropping EOF in append(). The
            // subsequent reset releases all undrained Swift output references.
            if(n>=CAPACITY-b->count) {
                tail(e,b);
            } else if(n<0 || !drain(e,b,e->previous,n,o->fps,&error)){
                // n=-1 is deliberate when already bypassed; do not invent an EOF error.
                if(e->stream && !e->fallback)record_error(e,n<0?"finish":"output",error,e->previous->pts);
                discard(b);tail(e,b);
            }
        }
        bool fallback=e->fallback;clear_engine(e,false);e->fallback=fallback;
        e->state=fallback?"degraded-finished":"finished";append(b,frame,false);return;
    }
    if(frame.type!=MP_FRAME_VIDEO){append(b,frame,false);return;}
    struct mp_image *img=frame.data;
    bool usable=supported(img,o->fps);
    if(e->previous && (!usable || img->w!=e->width || img->h!=e->height ||
        img->pts<=e->previous->pts || img->pts-e->previous->pts>IIVE_MAX_PAIR_SPAN ||
        img->params.color.transfer!=e->previous->params.color.transfer ||
        img->params.color.primaries!=e->previous->params.color.primaries ||
        img->params.repr.sys!=e->previous->params.repr.sys ||
        img->params.repr.levels!=e->previous->params.repr.levels ||
        img->params.chroma_location!=e->previous->params.chroma_location)) {
        tail(e,b);clear_engine(e,true);
    }
    if(!usable){if(e->stream)clear_engine(e,true);e->state="bypassed";append(b,frame,false);return;}
    if(e->fallback){if(strcmp(e->state,"error-bypass"))e->state="degraded";append(b,frame,false);return;}
    if(img->iive_preroll) {
        // The decoder retains references needed to reach the seek target. mpv
        // still discards these outputs normally; do not allocate/compile AI or
        // convert pixels for them. Boundary context arrives with the hint off.
        if(e->previous){tail(e,b);clear_engine(e,false);}
        e->preroll_bypassed++;e->state="seek-preroll";append(b,frame,false);return;
    }
    if(e->stream && (img->w!=e->width || img->h!=e->height))clear_engine(e,true);
    double start=seconds();
    int32_t error=0;const char *error_stage=NULL;
    if(!e->stream){
        e->width=img->w;e->height=img->h;
        e->nv12=!(img->w%2) && !(img->h%2) &&
            img->params.color.primaries==PL_COLOR_PRIM_BT_709 &&
            img->params.color.transfer==PL_COLOR_TRC_BT_1886 &&
            img->params.repr.sys==PL_COLOR_SYSTEM_BT_709;
        // The adapter measures conversion+inference+copy, not just model time.
        // Synchronous callback only; this stack context stays alive until the
        // constructor returns. destroy() joins this worker before releasing p.
        struct preparation_probe probe={p,generation};
        double preparation_start=seconds();
        e->stream=iive_stream_create_cancellable(img->w,img->h,o->fps,o->tier,0,
            preparation_canceled,&probe,&error);
        e->initialization_ms=(seconds()-preparation_start)*1000;
        e->preparation_valid=e->stream && iive_stream_preparation_timing(e->stream,e->preparation_ms,5)==1;
        e->compilation_cache_hit=e->stream && iive_stream_compilation_cache_hit(e->stream)==1;
        if(error==102) {
            pthread_mutex_lock(&p->mutex);p->canceled_preparations++;pthread_mutex_unlock(&p->mutex);
        }
        if(!e->stream)error_stage="initialization";
    }
    if(job_canceled(p,generation)){mp_frame_unref(&frame);return;}
    double phase=seconds();
    CVPixelBufferRef pixels=e->stream?convert_input(e,img):NULL;
    if(e->stream && !pixels){error=e->input_error;error_stage="input";}
    e->input_ms=(seconds()-phase)*1000;phase=seconds();
    if(job_canceled(p,generation)){
        if(pixels)CVPixelBufferRelease(pixels);
        mp_frame_unref(&frame);return;
    }
    bool backstep_preroll=img->iive_backstep_preroll;
    int n=pixels?iive_stream_push_preroll(e->stream,pixels,img->pts,backstep_preroll):-1;
    if(backstep_preroll)e->preroll_bypassed++;
    if(pixels && n<0){error=iive_stream_last_error(e->stream);error_stage="push";}
    if(n>=0)e->timing_valid=iive_stream_timing(e->stream,&e->gpu_span_ms,&e->cpu_wait_ms)==1;
    e->model_ms=(seconds()-phase)*1000;phase=seconds();
    if(pixels)CVPixelBufferRelease(pixels);
    if(job_canceled(p,generation)){mp_frame_unref(&frame);return;}
    bool failed=n<0;
    if(n>0) {
        if(!e->previous){failed=true;error=200;}
        else failed=!drain(e,b,e->previous,n,o->fps,&error);
        if(failed)error_stage="output";
    }
    e->output_ms=(seconds()-phase)*1000;
    if(failed) {
        record_error(e,error_stage?error_stage:"push",error,img->pts);
        discard(b);tail(e,b);append(b,frame,false);clear_engine(e,true);
        e->fallback=true;e->state="error-bypass";return;
    }
    if(e->previous) {
        double dt=img->pts-e->previous->pts;
        if(isfinite(dt) && dt>=0.001 && dt<=0.5)
            e->pair_span=e->pair_span>0?(e->pair_span*0.7+dt*0.3):dt;
        else e->pair_span=0;
        double budget=dt/speed;
        if(!backstep_preroll)e->pairs++;
        if(!backstep_preroll && o->fallback && !e->switching && e->pairs>24){
            e->bad=seconds()-start>budget*1.25?e->bad+1:(e->bad>0?e->bad-1:0);
            if(e->bad>=8){
                discard(b);tail(e,b);append(b,frame,false);clear_engine(e,true);
                e->fallback=true;e->state="degraded";return;
            }
        }
    }
    TA_FREEP(&e->previous);e->previous=img;e->state=backstep_preroll?"backstep-preroll":e->switching?"switching-source":n?"active":"warming";
}
static void *worker(void *arg)
{
    struct mp_filter *f=arg;struct priv *p=f->priv;
    struct engine e={.sws=mp_sws_alloc(NULL),.state="warming",.tier=p->opts->tier};e.sws->log=f->log;
    pthread_mutex_lock(&p->mutex);
    while(!p->stop) {
        while(!p->stop && !p->job.type && !p->reset_pending)pthread_cond_wait(&p->cond,&p->mutex);
        if(p->stop)break;
        if(p->reset_pending){
            p->reset_pending=false;pthread_mutex_unlock(&p->mutex);
            clear_engine(&e,false);e.error_stage=NULL;e.error_code=0;pthread_mutex_lock(&p->mutex);continue;
        }
        struct mp_frame frame=p->job;p->job=MP_NO_FRAME;
        uint64_t generation=p->job_generation;double speed=p->job_speed;
        struct opts job_opts=*p->opts;job_opts.tier=p->requested_tier;
        double dispatch_ms=(seconds()-p->submitted_at)*1000;
        double input_pts=frame.type==MP_FRAME_VIDEO?((struct mp_image *)frame.data)->pts:MP_NOPTS_VALUE;
        pthread_mutex_unlock(&p->mutex);
        struct batch b={0};e.timing_valid=false;e.gpu_span_ms=e.cpu_wait_ms=-1;e.input_ms=e.model_ms=e.output_ms=0;
        e.initialization_ms=-1;e.preparation_valid=false;
        bool switched=false;double switch_ms=0;
        if(frame.type==MP_FRAME_VIDEO && (e.tier!=job_opts.tier || e.switching) && !job_canceled(p,generation)) {
            if(!e.switch_started)e.switch_started=seconds();
            int status=e.stream?iive_stream_request_tier(e.stream,job_opts.tier):0;
            e.switching=status>0;
            if(status==0) {
                switched=e.tier!=job_opts.tier;
                switch_ms=(seconds()-e.switch_started)*1000;e.switch_started=0;
                e.tier=job_opts.tier;e.fallback=false;e.bad=e.pairs=0;
            } else if(status<0) {
                // A failed preparation is explicitly reported as source bypass;
                // do not retry the expensive failure on every subsequent frame.
                switch_ms=(seconds()-e.switch_started)*1000;
                record_error(&e,"tier-preparation",iive_stream_last_error(e.stream),input_pts);
                tail(&e,&b);clear_engine(&e,true);e.tier=job_opts.tier;e.fallback=true;e.state="error-bypass";
            }
        }
        double start=seconds();
        if(e.fallback && e.state && !strcmp(e.state,"error-bypass") && switch_ms>0)append(&b,frame,false);
        else run_job(&e,&job_opts,frame,speed,&b,p,generation);
        double finished=seconds(),ms=(finished-start)*1000;
        pthread_mutex_lock(&p->mutex);
        // One completed worker batch may wait behind the bounded ready queue.
        // Consumption, seek/reset and shutdown all signal this condition.
        while(!p->stop && generation==p->generation && b.count>CAPACITY-p->ready.count)
            pthread_cond_wait(&p->cond,&p->mutex);
        p->busy=false;
        if(generation!=p->generation || p->stop){p->stale++;discard(&b);}
        else {
            // Retain the last accepted cold preparation, independently of the
            // rolling per-pair window. Never publish a canceled generation.
            if(e.initialization_ms>=0) {
                p->initializations++;p->preparation_generation=generation;
                p->initialization_ms=e.initialization_ms;p->preparation_valid=e.preparation_valid;
                p->compilation_cache_hit=e.compilation_cache_hit;
                if(e.preparation_valid)memcpy(p->preparation_ms,e.preparation_ms,sizeof(p->preparation_ms));
            }
            if(e.error_stage && e.error_serial!=p->error_serial) {
                p->error_serial=e.error_serial;p->error_events++;p->error_generation=generation;
                p->error_id=atomic_fetch_add_explicit(&next_error_id,1,memory_order_relaxed)+1;
                p->error_stage=e.error_stage;p->error_code=e.error_code;p->error_pts=e.error_pts;
                // Preserve timings of the failing job, not those of its predecessor.
                p->input_ms=e.input_ms;p->model_ms=e.model_ms;p->output_ms=e.output_ms;
                MP_WARN(f,"RIFE failure: stage=%s code=%d reason=%s generation=%llu pts=%.9f\n",
                    p->error_stage,p->error_code,iive_stream_error_name(p->error_code),
                    (unsigned long long)generation,p->error_pts);
            }
            p->active_tier=e.tier;
            if(switch_ms>0) {
                p->tier_switch_ms=switch_ms;
                if(switched) {
                    p->tier_switches++;
                    iive_latency_reset(&p->latency);p->jobs=0;p->total_ms=p->peak_ms=0;
                }
            }
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
            p->width=e.width;p->height=e.height;p->pair_span=e.pair_span;
            p->state=e.state;p->output_path=e.fallback?"source-bypass":e.native_output?"nv12-metal":"bgra-convert";p->input_path=e.nv12?"nv12-metal":"bgra-cpu";
            p->shared_inputs=e.shared_inputs;p->copied_inputs=e.copied_inputs;p->normalized_inputs=e.normalized_inputs;
            p->preroll_bypassed=e.preroll_bypassed;
            if(e.input_surface)p->input_surface=e.input_surface;
            if(!e.fallback && !e.switching && strcmp(e.state,"backstep-preroll") && (e.input_ms>0 || e.model_ms>0 || e.output_ms>0)) {
                p->input_ms=e.input_ms;p->model_ms=e.model_ms;p->output_ms=e.output_ms;
                p->last_ms=ms;p->total_ms+=ms;p->peak_ms=fmax(p->peak_ms,ms);p->jobs++;
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
                    "rife",(unsigned long long)p->generation,(unsigned long long)p->jobs,
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
    p->timing_valid=false;p->error_stage=NULL;p->error_code=0;
    p->generation++;p->input_ended=false;discard(&p->ready);
    p->output_frame_bytes=0;p->memory_prefetch_limit=p->effective_prefetch_limit=0;
    memset(&p->profile,0,sizeof(p->profile));
    memset(&p->queue_timeline,0,sizeof(p->queue_timeline));
    p->queue_ahead_ms=p->queue_budget_ms=-1;p->time_prefetch_blocked=false;
    p->time_prefetch_deferrals=0;
    iive_latency_reset(&p->latency);p->source_fps=0;p->pair_span=0;p->prefetch_limit=4;
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
                "rife",(unsigned long long)p->generation,((struct mp_image*)output.data)->pts,seconds(),ready_ms,p->ready.count,synth);

            MP_VERBOSE(f,"output pts=%.9f synthesized=%d generation=%llu\n",((struct mp_image*)output.data)->pts,synth,(unsigned long long)p->generation);
        }
        pthread_cond_signal(&p->cond);
    }
    // Adaptive prefetch budget: bound queued IOSurfaces by resolution and measured P95 latency
    // so 4K / high-P95 streams avoid holding excess NV12 surfaces while preserving worker overlap.
    // Avoid sorting the rolling window on every output while the worker is busy.
    double p50_est = 0, p95_est = -1;
    if(!p->busy && !p->input_ended && !p->opts->prefetch) {
        // A few cold samples must not drive adaptive queue changes.
        if(p->latency.count>=8)iive_latency_read(&p->latency, &p50_est, &p95_est);
        p->prefetch_limit = iive_prefetch_limit_hysteresis(
            p->width, p->height, p->prefetch_limit, p->pair_span, p->source_fps, p->speed, p95_est);
    }
    if(p->opts->prefetch)p->prefetch_limit=p->opts->prefetch;
    uint64_t frame_bytes=p->output_frame_bytes;
    // A resolution change may leave larger old frames in the ready queue.
    for(int i=0;i<p->ready.count;i++)if(p->ready.frames[i].type==MP_FRAME_VIDEO) {
        struct mp_image *img=p->ready.frames[i].data;
        uint64_t bytes=iive_queue_frame_estimate(img->w,img->h);
        if(bytes>frame_bytes)frame_bytes=bytes;
    }
    p->memory_prefetch_limit=iive_queue_prefetch_limit(frame_bytes,CAPACITY+1,CAPACITY/2);
    int requested_prefetch=p->prefetch_limit > 0 ? p->prefetch_limit : 4;
    int max_prefetch=p->memory_prefetch_limit<requested_prefetch?p->memory_prefetch_limit:requested_prefetch;
    p->effective_prefetch_limit=max_prefetch;
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
            if(frame.type==MP_FRAME_VIDEO)
                p->source_fps=((struct mp_image *)frame.data)->nominal_fps;
            p->submitted_at=seconds();
            p->job=frame;p->busy=true;p->job_generation=p->generation;p->job_speed=p->speed;
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
    if(cmd->type==MP_FILTER_COMMAND_TEXT && !strcmp(cmd->cmd,"tier")) {
        int tier=cmd->arg&&!strcmp(cmd->arg,"fast")?0:cmd->arg&&!strcmp(cmd->arg,"balanced")?1:
            cmd->arg&&!strcmp(cmd->arg,"hq")?2:-1;
        if(tier<0)return false;
        pthread_mutex_lock(&p->mutex);p->requested_tier=tier;pthread_cond_signal(&p->cond);
        pthread_mutex_unlock(&p->mutex);mp_filter_wakeup(f);return true;
    }
    if(cmd->type==MP_FILTER_COMMAND_TEXT && !strcmp(cmd->cmd,"speed")){
        char *end;double speed=strtod(cmd->arg?cmd->arg:"",&end);
        if(!cmd->arg || end==cmd->arg || *end || !isfinite(speed) || speed<=0)return false;
        pthread_mutex_lock(&p->mutex);p->speed=speed;pthread_mutex_unlock(&p->mutex);return true;
    }
    if(cmd->type!=MP_FILTER_COMMAND_GET_META)return false;
    struct mp_tags *tags=talloc_zero(NULL,struct mp_tags);pthread_mutex_lock(&p->mutex);
    mp_tags_set_str(tags,"state",p->state);
    mp_tags_set_str(tags,"error_events",mp_tprintf(32,"%llu",(unsigned long long)p->error_events));
    mp_tags_set_str(tags,"canceled_preparations",mp_tprintf(32,"%llu",(unsigned long long)p->canceled_preparations));
    mp_tags_set_str(tags,"preroll_bypassed",mp_tprintf(32,"%llu",(unsigned long long)p->preroll_bypassed));
    mp_tags_set_str(tags,"initializations",mp_tprintf(32,"%llu",(unsigned long long)p->initializations));
    if(p->initializations) {
        mp_tags_set_str(tags,"preparation_generation",mp_tprintf(32,"%llu",(unsigned long long)p->preparation_generation));
        mp_tags_set_str(tags,"initialization_ms",mp_tprintf(32,"%.3f",p->initialization_ms));
        if(p->preparation_valid)mp_tags_set_str(tags,"compilation_cache_hit",p->compilation_cache_hit?"yes":"no");
        const char *keys[]={"prepare_weights_ms","prepare_context_ms","prepare_pool_ms","prepare_compile_ms","prepare_probe_ms"};
        if(p->preparation_valid)for(int i=0;i<5;i++)if(p->preparation_ms[i]>=0)
            mp_tags_set_str(tags,keys[i],mp_tprintf(32,"%.3f",p->preparation_ms[i]));
    }
    if(p->error_stage) {
        mp_tags_set_str(tags,"error_id",mp_tprintf(32,"%llu",(unsigned long long)p->error_id));
        mp_tags_set_str(tags,"error_stage",p->error_stage);
        mp_tags_set_str(tags,"error_code",mp_tprintf(32,"%d",p->error_code));
        mp_tags_set_str(tags,"error_reason",iive_stream_error_name(p->error_code));
        mp_tags_set_str(tags,"error_generation",mp_tprintf(32,"%llu",(unsigned long long)p->error_generation));
        if(isfinite(p->error_pts) && p->error_pts!=MP_NOPTS_VALUE)
            mp_tags_set_str(tags,"error_input_pts",mp_tprintf(48,"%.9f",p->error_pts));
    }
    mp_tags_set_str(tags,"requested_tier",p->active_tier==0?"fast":p->active_tier==1?"balanced":"hq");
    mp_tags_set_str(tags,"tier_switch_pending",p->requested_tier!=p->active_tier?"yes":"no");
    mp_tags_set_str(tags,"tier_switches",mp_tprintf(32,"%llu",(unsigned long long)p->tier_switches));
    mp_tags_set_str(tags,"tier_switch_ms",mp_tprintf(32,"%.3f",p->tier_switch_ms));
    mp_tags_set_str(tags,"input_path",p->input_path?p->input_path:"pending");
    mp_tags_set_str(tags,"output_path",p->output_path?p->output_path:"pending");
    mp_tags_set_str(tags,"input_surface",p->input_surface?p->input_surface:"pending");
    mp_tags_set_str(tags,"shared_inputs",mp_tprintf(32,"%llu",(unsigned long long)p->shared_inputs));
    mp_tags_set_str(tags,"copied_inputs",mp_tprintf(32,"%llu",(unsigned long long)p->copied_inputs));
    mp_tags_set_str(tags,"generated",mp_tprintf(32,"%llu",(unsigned long long)p->generated));
    mp_tags_set_str(tags,"emitted",mp_tprintf(32,"%llu",(unsigned long long)p->emitted));
    mp_tags_set_str(tags,"generation",mp_tprintf(32,"%llu",(unsigned long long)p->generation));
    mp_tags_set_str(tags,"stale_jobs_discarded",mp_tprintf(32,"%llu",(unsigned long long)p->stale));
    mp_tags_set_str(tags,"queued",mp_tprintf(32,"%d",p->ready.count));
    if(p->queue_ahead_ms>=0)mp_tags_set_str(tags,"queue_ahead_ms",mp_tprintf(32,"%.3f",p->queue_ahead_ms));
    if(p->queue_budget_ms>=0)mp_tags_set_str(tags,"queue_budget_ms",mp_tprintf(32,"%.3f",p->queue_budget_ms));
    mp_tags_set_str(tags,"time_prefetch_blocked",p->time_prefetch_blocked?"1":"0");
    mp_tags_set_str(tags,"time_prefetch_deferrals",mp_tprintf(32,"%llu",(unsigned long long)p->time_prefetch_deferrals));
    mp_tags_set_str(tags,"prefetch_limit",mp_tprintf(32,"%d",p->effective_prefetch_limit));
    mp_tags_set_str(tags,"pair_budget_ms",mp_tprintf(32,"%.3f",iive_pair_budget_ms(p->pair_span,p->source_fps,p->speed)));
    mp_tags_set_str(tags,"queue_surface_target_bytes",mp_tprintf(32,"%llu",(unsigned long long)IIVE_QUEUE_SURFACE_TARGET));
    mp_tags_set_str(tags,"queue_frame_estimate_bytes",mp_tprintf(32,"%llu",(unsigned long long)p->output_frame_bytes));
    mp_tags_set_str(tags,"memory_prefetch_limit",mp_tprintf(32,"%d",p->memory_prefetch_limit));
    mp_tags_set_str(tags,"queue_reserved_frames",mp_tprintf(32,"%d",CAPACITY+1));
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
    MP_INFO(f,"RIFE totals: emitted=%llu synthesized=%llu stale_jobs=%llu\n",(unsigned long long)p->emitted,(unsigned long long)p->generated,(unsigned long long)p->stale);
}
static const struct mp_filter_info info={.name="iive-rife",.priv_size=sizeof(struct priv),.process=process,.reset=reset,.destroy=destroy,.command=command};
static struct mp_filter *create(struct mp_filter *parent, void *options)
{
    struct mp_filter *f=mp_filter_create(parent,&info);
    if(!f){talloc_free(options);return NULL;}
    struct priv *p=f->priv;p->opts=talloc_steal(p,options);p->speed=1;p->prefetch_limit=4;p->state="warming";
    p->requested_tier=p->active_tier=p->opts->tier;
    p->opts->prefetch=iive_profile_prefetch(p->opts->prefetch);
    p->queue_ahead_ms=p->queue_budget_ms=-1;
    pthread_mutex_init(&p->mutex,NULL);pthread_cond_init(&p->cond,NULL);
    mp_filter_add_pin(f,MP_PIN_IN,"in");mp_filter_add_pin(f,MP_PIN_OUT,"out");
    if(pthread_create(&p->thread,NULL,worker,f)){talloc_free(f);return NULL;}
    p->started=true;return f;
}
#define OPT_BASE_STRUCT struct opts
static const struct m_option options[]={
    {"fps",OPT_CHOICE(fps,{"48",48},{"60",60})},
    {"tier",OPT_CHOICE(tier,{"fast",0},{"balanced",1},{"hq",2})},
    {"prefetch",OPT_CHOICE(prefetch,{"auto",0},{"1",1},{"2",2},{"4",4})},
    {"fallback",OPT_BOOL(fallback)}, {0}
};
static const struct opts defaults={.fps=48,.tier=0,.fallback=true};
const struct mp_user_filter_entry vf_iive_rife={
    .desc={.name="iive-rife",.description="Experimental asynchronous RIFE Metal SDR interpolation",
    .priv_size=sizeof(struct opts),.priv_defaults=&defaults,.options=options},.create=create,
};
