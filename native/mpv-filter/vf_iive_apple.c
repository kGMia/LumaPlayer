/* SPDX-License-Identifier: GPL-3.0-or-later
 * Separate mpv build. One serial inference worker, one job, <=8 output frames.
 * The worker never accesses mpv pins; reset invalidates results by generation.
 * CPU conversion/copies remain explicit. No IINA.app replacement or zero-copy claim.
 */
#include <math.h>
#include <string.h>
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
#define CAPACITY 8
struct opts { int mode; float scale; bool fallback; };
struct batch {struct mp_frame frames[CAPACITY]; bool synthesized[CAPACITY]; int count;};
struct engine {
    struct mp_sws_context *sws;
    void *stream;
    struct mp_image *previous;
    CVPixelBufferRef previous_pixels;
    int width, height, bad, pairs, mode;
    bool fallback;
    uint64_t shared_inputs, copied_inputs;
    const char *input_surface;
    const char *state;
};
struct priv {
    struct opts *opts;
    pthread_t thread;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    bool started, stop, busy, reset_pending;
    struct mp_frame job;
    struct batch ready;
    uint64_t generation, job_generation, emitted, generated, stale;
    double speed, job_speed, last_ms, total_ms, peak_ms;
    uint64_t jobs, shared_inputs, copied_inputs;
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
    TA_FREEP(&e->previous);
    if(e->previous_pixels)CVPixelBufferRelease(e->previous_pixels);
    e->previous_pixels=NULL;
    if(destroy){if(e->mode>=2)iive_fsr_destroy(e->stream);else iive_apple_destroy(e->stream);e->stream=NULL;}
    e->bad=e->pairs=0;e->fallback=false;e->state="warming";
}
static bool supported(struct mp_image *img, bool fi) {
    return img->w>0 && img->h>0 && !(img->w%2) && !(img->h%2) &&
        (img->params.color.primaries==PL_COLOR_PRIM_BT_709 ||
         img->params.color.primaries==PL_COLOR_PRIM_DISPLAY_P3 ||
         img->params.color.primaries==PL_COLOR_PRIM_BT_2020 ||
         img->params.color.primaries==PL_COLOR_PRIM_BT_601_525 ||
         img->params.color.primaries==PL_COLOR_PRIM_BT_601_625 ||
         img->params.color.primaries==PL_COLOR_PRIM_EBU_3213) &&
        (img->params.color.transfer==PL_COLOR_TRC_BT_1886 ||
         img->params.color.transfer==PL_COLOR_TRC_SRGB ||
         img->params.color.transfer==PL_COLOR_TRC_GAMMA22 ||
         img->params.color.transfer==PL_COLOR_TRC_GAMMA28) &&
        img->params.repr.sys!=PL_COLOR_SYSTEM_DOLBYVISION && !img->params.rotate &&
        img->pts!=MP_NOPTS_VALUE && isfinite(img->pts) &&
        img->nominal_fps>0 && (!fi || img->nominal_fps<=30.01) && iive_surface_supported_input(img);
}
// Zero-copy IOSurface acquisition for VT hwdec and upstream filters; swscale fallback into pooled NV12.
static CVPixelBufferRef convert_input(struct engine *e, struct mp_image *img) {
    CVPixelBufferRef shared=iive_surface_acquire(img);
    if(shared){e->shared_inputs++;e->input_surface="shared-iosurface";return shared;}
    e->copied_inputs++;e->input_surface="swscale-copy";
    CVPixelBufferRef pixels=e->mode>=2?iive_fsr_input(e->stream):iive_apple_input(e->stream);
    if(!pixels)return NULL;
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
static void run_job(struct engine *e,const struct opts *o,struct mp_frame frame,double speed,struct batch *b) {
    bool fi=o->mode==1;
    if(mp_frame_is_signaling(frame)) {bool degraded=e->fallback;tail(e,b);clear_engine(e,false);e->fallback=degraded;e->state=degraded?"degraded-finished":"finished";append(b,frame,false);return;}
    if(frame.type!=MP_FRAME_VIDEO){append(b,frame,false);return;}
    struct mp_image *img=frame.data;bool usable=supported(img,fi);
    if(e->stream && (img->w!=e->width || img->h!=e->height || !usable ||
        (e->previous && (img->pts<=e->previous->pts || img->pts-e->previous->pts>0.1 ||
        img->params.color.transfer!=e->previous->params.color.transfer)))) {tail(e,b);clear_engine(e,true);}
    if(!usable){e->state="bypassed-format";append(b,frame,false);return;}
    if(e->fallback){append(b,frame,false);return;}
    double start=seconds();
    if(!e->stream){e->width=img->w;e->height=img->h;e->stream=e->mode>=2?iive_fsr_create(img->w,img->h,e->mode==2?8:16):iive_apple_create(img->w,img->h,fi,o->scale);}
    if(!e->stream){e->fallback=true;e->state="unsupported-or-model-unavailable";append(b,frame,false);return;}
    CVPixelBufferRef input=convert_input(e,img);
    if(!input){tail(e,b);clear_engine(e,true);e->fallback=true;e->state="error-bypass";append(b,frame,false);return;}
    bool cut=fi&&e->previous&&scene_cut(input,e->previous_pixels);
    bool needs_output=!fi || (e->previous && !cut);
    struct mp_image *out=NULL;
    if(needs_output) {
        CVPixelBufferRef pixels=e->mode>=2?iive_fsr_process(e->stream,input):iive_apple_process(e->stream,input,e->previous_pixels,img->pts,e->previous?e->previous->pts:0);
        out=iive_surface_wrap(pixels,img);
    }
    e->pairs++;
    double budget=1.0/img->nominal_fps/speed;
    if(o->fallback && e->pairs>3)e->bad=seconds()-start>budget*1.25?e->bad+1:0;
    if((needs_output&&!out) || e->bad>=5) {
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
        uint64_t generation=p->job_generation;double speed=p->job_speed;
        pthread_mutex_unlock(&p->mutex);
        struct batch b={0};double start=seconds();run_job(&e,p->opts,frame,speed,&b);
        double ms=(seconds()-start)*1000;
        pthread_mutex_lock(&p->mutex);
        p->busy=false;
        if(generation!=p->generation || p->stop){p->stale++;discard(&b);}
        else {
            p->ready=b;p->state=e.state;p->shared_inputs=e.shared_inputs;p->copied_inputs=e.copied_inputs;p->input_surface=e.input_surface;p->last_ms=ms;p->total_ms+=ms;
            p->peak_ms=fmax(p->peak_ms,ms);p->jobs++;
        }
        mp_filter_wakeup(f);
    }
    mp_frame_unref(&p->job);pthread_mutex_unlock(&p->mutex);
    clear_engine(&e,true);talloc_free(e.sws);return NULL;
}
static void reset(struct mp_filter *f)
{
    struct priv *p=f->priv;pthread_mutex_lock(&p->mutex);
    p->generation++;discard(&p->ready);
    if(p->job.type){mp_frame_unref(&p->job);p->busy=false;}
    p->reset_pending=true;p->state="warming";
    pthread_cond_signal(&p->cond);pthread_mutex_unlock(&p->mutex);
}
static void process(struct mp_filter *f)
{
    struct priv *p=f->priv;
    if(!mp_pin_in_needs_data(f->ppins[1]))return;
    pthread_mutex_lock(&p->mutex);
    if(p->ready.count) {
        struct mp_frame frame=p->ready.frames[0];bool synth=p->ready.synthesized[0];
        memmove(p->ready.frames,p->ready.frames+1,(p->ready.count-1)*sizeof(struct mp_frame));
        memmove(p->ready.synthesized,p->ready.synthesized+1,(p->ready.count-1)*sizeof(bool));p->ready.count--;
        if(frame.type==MP_FRAME_VIDEO){
            p->emitted++;p->generated+=synth;
            MP_VERBOSE(f,"output pts=%.9f synthesized=%d generation=%llu\n",((struct mp_image*)frame.data)->pts,synth,(unsigned long long)p->generation);
        }
        pthread_mutex_unlock(&p->mutex);mp_pin_in_write(f->ppins[1],frame);return;
    }
    if(!p->busy) {
        struct mp_frame frame=mp_pin_out_read(f->ppins[0]);
        if(frame.type){p->job=frame;p->busy=true;p->job_generation=p->generation;p->job_speed=p->speed;pthread_cond_signal(&p->cond);}
    }
    pthread_mutex_unlock(&p->mutex);
}
static bool command(struct mp_filter *f, struct mp_filter_command *cmd)
{
    struct priv *p=f->priv;
    if(cmd->type==MP_FILTER_COMMAND_TEXT && !strcmp(cmd->cmd,"speed")){
        char *end;double speed=strtod(cmd->arg?cmd->arg:"",&end);
        if(!cmd->arg || end==cmd->arg || *end || !isfinite(speed) || speed<=0)return false;
        pthread_mutex_lock(&p->mutex);p->speed=speed;pthread_mutex_unlock(&p->mutex);return true;
    }
    if(cmd->type!=MP_FILTER_COMMAND_GET_META)return false;
    struct mp_tags *tags=talloc_zero(NULL,struct mp_tags);pthread_mutex_lock(&p->mutex);
    mp_tags_set_str(tags,"state",p->state);
    mp_tags_set_str(tags,"input_surface",p->input_surface?p->input_surface:"pending");
    mp_tags_set_str(tags,"shared_inputs",mp_tprintf(32,"%llu",(unsigned long long)p->shared_inputs));
    mp_tags_set_str(tags,"copied_inputs",mp_tprintf(32,"%llu",(unsigned long long)p->copied_inputs));
    mp_tags_set_str(tags,"backend",p->opts->mode==2?"fsrcnnx8-mpsgraph":p->opts->mode==3?"fsrcnnx16-mpsgraph":"apple-videotoolbox");
    mp_tags_set_str(tags,"generated",mp_tprintf(32,"%llu",(unsigned long long)p->generated));
    mp_tags_set_str(tags,"emitted",mp_tprintf(32,"%llu",(unsigned long long)p->emitted));
    mp_tags_set_str(tags,"generation",mp_tprintf(32,"%llu",(unsigned long long)p->generation));
    mp_tags_set_str(tags,"stale_jobs_discarded",mp_tprintf(32,"%llu",(unsigned long long)p->stale));
    mp_tags_set_str(tags,"queued",mp_tprintf(32,"%d",p->ready.count));
    mp_tags_set_str(tags,"inflight",p->busy?"1":"0");
    mp_tags_set_str(tags,"processing_ms",mp_tprintf(32,"%.3f",p->last_ms));
    mp_tags_set_str(tags,"mean_processing_ms",mp_tprintf(32,"%.3f",p->jobs?p->total_ms/p->jobs:0));
    mp_tags_set_str(tags,"peak_processing_ms",mp_tprintf(32,"%.3f",p->peak_ms));
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
    struct priv *p=f->priv;p->opts=talloc_steal(p,options);p->speed=1;p->state="warming";
    pthread_mutex_init(&p->mutex,NULL);pthread_cond_init(&p->cond,NULL);
    mp_filter_add_pin(f,MP_PIN_IN,"in");mp_filter_add_pin(f,MP_PIN_OUT,"out");
    if(pthread_create(&p->thread,NULL,worker,f)){talloc_free(f);return NULL;}
    p->started=true;return f;
}
#define OPT_BASE_STRUCT struct opts
static const struct m_option options[]={
    {"mode",OPT_CHOICE(mode,{"sr",0},{"fi",1})},
    {"scale",OPT_FLOAT(scale),M_RANGE(1.0,4.0)},
    {"fallback",OPT_BOOL(fallback)}, {0}
};
static const struct opts defaults={.mode=0,.scale=2,.fallback=true};
const struct mp_user_filter_entry vf_iive_apple={
    .desc={.name="iive-apple",.description="Apple low-latency SDR super resolution / midpoint interpolation",
    .priv_size=sizeof(struct opts),.priv_defaults=&defaults,.options=options},.create=create,
};

// Shares the bounded worker, cancellation generation and color conversion with
// the Apple adapter; model execution is a distinct Swift/MPSGraph C ABI.
static const struct m_option fsr_options[]={
    {"tier",OPT_CHOICE(mode,{"fast",2},{"quality",3})},
    {"fallback",OPT_BOOL(fallback)}, {0}
};
static const struct opts fsr_defaults={.mode=2,.scale=2,.fallback=true};
const struct mp_user_filter_entry vf_iive_fsrcnnx={
    .desc={.name="iive-fsrcnnx",.description="Native FSRCNNX 8/16 MPSGraph 2x SDR super resolution",
    .priv_size=sizeof(struct opts),.priv_defaults=&fsr_defaults,.options=fsr_options},.create=create,
};
