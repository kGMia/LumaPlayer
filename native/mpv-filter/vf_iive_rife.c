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
#include "IIVERIFE.h"
#include "iive_surface.h"
#define CAPACITY 8
struct opts { int fps, tier; bool fallback; };
struct batch {struct mp_frame frames[CAPACITY]; bool synthesized[CAPACITY]; int count;};
struct engine {
    struct mp_sws_context *sws;
    void *stream;
    CVPixelBufferPoolRef input_pool;
    struct mp_image *previous;
    int width, height, bad, pairs;
    bool fallback, nv12, native_output;
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
    uint64_t jobs;
    const char *state, *input_path, *output_path;
};
static double seconds(void) {struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static void discard(struct batch *b) {for(int i=0;i<b->count;i++)mp_frame_unref(&b->frames[i]);memset(b,0,sizeof(*b));}
static bool append(struct batch *b, struct mp_frame frame, bool synthesized) {
    if(b->count==CAPACITY){mp_frame_unref(&frame);return false;}
    b->frames[b->count]=frame;b->synthesized[b->count++]=synthesized;return true;
}
static void clear_engine(struct engine *e, bool destroy) {
    TA_FREEP(&e->previous);
    if(destroy){iive_stream_destroy(e->stream);e->stream=NULL;if(e->input_pool)CFRelease(e->input_pool);e->input_pool=NULL;}
    else if(e->stream)iive_stream_reset(e->stream);
    e->bad=e->pairs=0;e->fallback=false;e->native_output=false;e->state="warming";
}
static bool supported(struct mp_image *img, int fps)
{
    return img->w > 0 && img->h > 0 && img->w <= 4096 && img->h <= 4096 &&
        !(img->fmt.flags & MP_IMGFLAG_HWACCEL) &&
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
        !img->params.rotate && mp_sws_supported_format(img->imgfmt);
}

// Software decoding still requires a layout copy into an IOSurface pool.
// The NV12 route avoids BGRA staging and lets Metal write the FP16 input tensor.
static CVPixelBufferRef convert_input(struct engine *p, struct mp_image *img)
{
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
    if(!p->input_pool || CVPixelBufferPoolCreatePixelBuffer(NULL,p->input_pool,&buffer))return NULL;
    if(CVPixelBufferLockBaseAddress(buffer,0)){CVPixelBufferRelease(buffer);return NULL;}
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
    int result=mp_sws_scale(p->sws,&view,img);mp_image_unref_data(&view);
    CVPixelBufferUnlockBaseAddress(buffer,0);
    if(result<0){CVPixelBufferRelease(buffer);return NULL;}return buffer;
}
static bool drain(struct engine *e, struct batch *b, struct mp_image *attributes, int count, int fps)
{
    if(count<0 || count>CAPACITY-b->count)return false;
    for(int n=0;n<count;n++) {
        double pts;int32_t synth=0;
        CVPixelBufferRef pixels=iive_stream_pop(e->stream,&pts,&synth);
        if(!pixels)return false;
        if(CVPixelBufferGetPixelFormatType(pixels)==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange){
            if(synth)e->native_output=true;
            struct mp_image *out=iive_surface_wrap(pixels,attributes);
            if(!out)return false;
            out->pts=pts;out->dts=MP_NOPTS_VALUE;out->nominal_fps=fps;out->pkt_duration=1.0/fps;
            append(b,(struct mp_frame){MP_FRAME_VIDEO,out},synth);continue;
        }
        struct mp_image *img=mp_image_alloc(IMGFMT_BGRA,e->width,e->height);
        if(!img || CVPixelBufferLockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess){
            talloc_free(img);iive_rife_release_frame(pixels);return false;
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
        if(!yuv){talloc_free(img);return false;}
        mp_image_copy_attributes(yuv,img);
        yuv->params.repr.sys=PL_COLOR_SYSTEM_BT_709;
        yuv->params.repr.levels=PL_COLOR_LEVELS_LIMITED;
        yuv->params.chroma_location=PL_CHROMA_CENTER;
        if(mp_sws_scale(e->sws,yuv,img)<0){talloc_free(img);talloc_free(yuv);return false;}
        talloc_free(img);
        append(b,(struct mp_frame){MP_FRAME_VIDEO,yuv},synth);
    }
    return true;
}
static void tail(struct engine *e, struct batch *b) {
    if(e->previous){append(b,(struct mp_frame){MP_FRAME_VIDEO,e->previous},false);e->previous=NULL;}
}
// Owns frame and all engine resources. Called exclusively by the worker.
static void run_job(struct engine *e, const struct opts *o, struct mp_frame frame,
                    double speed, struct batch *b)
{
    if(mp_frame_is_signaling(frame)) {
        if(e->previous) {
            double d=e->previous->pkt_duration;
            if(!(d>0 && d<=1))d=1.0/e->previous->nominal_fps;
            int n=e->stream&&!e->fallback?iive_stream_finish(e->stream,e->previous->pts+d):-1;
            if(n<0 || !drain(e,b,e->previous,n,o->fps)){discard(b);tail(e,b);}
        }
        bool fallback=e->fallback;clear_engine(e,false);e->fallback=fallback;
        e->state=fallback?"degraded-finished":"finished";append(b,frame,false);return;
    }
    if(frame.type!=MP_FRAME_VIDEO){append(b,frame,false);return;}
    struct mp_image *img=frame.data;
    bool usable=supported(img,o->fps);
    if(e->previous && (!usable || img->w!=e->width || img->h!=e->height ||
        img->pts<=e->previous->pts || img->pts-e->previous->pts>0.1 ||
        img->params.color.transfer!=e->previous->params.color.transfer ||
        img->params.color.primaries!=e->previous->params.color.primaries ||
        img->params.repr.sys!=e->previous->params.repr.sys ||
        img->params.repr.levels!=e->previous->params.repr.levels)) {
        tail(e,b);clear_engine(e,true);
    }
    if(!usable){e->state="bypassed";append(b,frame,false);return;}
    if(e->fallback){e->state="degraded";append(b,frame,false);return;}
    if(e->stream && (img->w!=e->width || img->h!=e->height))clear_engine(e,true);
    double start=seconds();
    if(!e->stream){
        e->width=img->w;e->height=img->h;
        e->nv12=!(img->w%2) && !(img->h%2) &&
            img->params.color.primaries==PL_COLOR_PRIM_BT_709 &&
            img->params.color.transfer==PL_COLOR_TRC_BT_1886 &&
            img->params.repr.sys==PL_COLOR_SYSTEM_BT_709;
        // The adapter measures conversion+inference+copy, not just model time.
        e->stream=iive_stream_create(img->w,img->h,o->fps,o->tier,0);
    }
    CVPixelBufferRef pixels=e->stream?convert_input(e,img):NULL;
    int n=pixels?iive_stream_push(e->stream,pixels,img->pts):-1;
    if(pixels)CVPixelBufferRelease(pixels);
    if(n<0 || (n && (!e->previous || !drain(e,b,e->previous,n,o->fps)))) {
        discard(b);tail(e,b);append(b,frame,false);clear_engine(e,true);
        e->fallback=true;e->state="error-bypass";return;
    }
    if(e->previous) {
        double budget=(img->pts-e->previous->pts)/speed;
        e->pairs++;
        // Ignore three cold-start pairs; five successive full-pipeline misses latch fallback.
        if(o->fallback && e->pairs>3){
            e->bad=seconds()-start>budget*1.25?e->bad+1:0;
            if(e->bad>=5){
                discard(b);tail(e,b);append(b,frame,false);clear_engine(e,true);
                e->fallback=true;e->state="degraded";return;
            }
        }
    }
    TA_FREEP(&e->previous);e->previous=img;e->state=n?"active":"warming";
}
static void *worker(void *arg)
{
    struct mp_filter *f=arg;struct priv *p=f->priv;
    struct engine e={.sws=mp_sws_alloc(NULL),.state="warming"};e.sws->log=f->log;
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
            p->ready=b;p->state=e.state;p->output_path=e.native_output?"nv12-metal":"bgra-convert";p->input_path=e.nv12?"nv12-metal":"bgra-cpu";p->last_ms=ms;p->total_ms+=ms;
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
    mp_tags_set_str(tags,"input_path",p->input_path?p->input_path:"pending");
    mp_tags_set_str(tags,"output_path",p->output_path?p->output_path:"pending");
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
    MP_INFO(f,"RIFE totals: emitted=%llu synthesized=%llu stale_jobs=%llu\n",(unsigned long long)p->emitted,(unsigned long long)p->generated,(unsigned long long)p->stale);
}
static const struct mp_filter_info info={.name="iive-rife",.priv_size=sizeof(struct priv),.process=process,.reset=reset,.destroy=destroy,.command=command};
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
    {"fps",OPT_CHOICE(fps,{"48",48},{"60",60})},
    {"tier",OPT_CHOICE(tier,{"fast",0},{"balanced",1},{"hq",2})},
    {"fallback",OPT_BOOL(fallback)}, {0}
};
static const struct opts defaults={.fps=48,.tier=0,.fallback=true};
const struct mp_user_filter_entry vf_iive_rife={
    .desc={.name="iive-rife",.description="Experimental asynchronous RIFE Metal SDR interpolation",
    .priv_size=sizeof(struct opts),.priv_defaults=&defaults,.options=options},.create=create,
};
