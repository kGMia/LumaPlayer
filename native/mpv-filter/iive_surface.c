/* SPDX-License-Identifier: GPL-3.0-or-later
 * Share IOSurfaces between our filters without guessing AVBuffer opaque layouts,
 * and directly ingest zero-copy VideoToolbox hardware-decoded CVPixelBuffers.
 * The registry does not own extra frames. Entries live exactly as long as their
 * read-only AVBuffer; the mutex covers lookup/retain and final removal.
 */
#include <stdlib.h>
#include <math.h>
#include <pthread.h>
#include <libavutil/buffer.h>
#include "video/mp_image.h"
#include "video/img_format.h"
#include "video/sws_utils.h"
#include "iive_surface.h"
#include "IIVEApple.h"
struct surface {
    AVBuffer *identity;
    CVPixelBufferRef pixels;
    struct surface *next;
};
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static struct surface *surfaces;
static void release_surface(void *opaque, uint8_t *unused) {
    struct surface *entry=opaque;
    pthread_mutex_lock(&mutex);
    struct surface **link=&surfaces;
    while (*link && *link!=entry) link=&(*link)->next;
    if (*link) *link=entry->next;
    pthread_mutex_unlock(&mutex);
    CVPixelBufferUnlockBaseAddress(entry->pixels,kCVPixelBufferLock_ReadOnly);
    CVPixelBufferRelease(entry->pixels);
    free(entry);
}
struct mp_image *iive_surface_wrap(CVPixelBufferRef pixels, struct mp_image *attributes) {
    if (!pixels) return NULL;
    if (CVPixelBufferGetPixelFormatType(pixels)!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        CVPixelBufferGetPlaneCount(pixels)!=2 || !CVPixelBufferGetIOSurface(pixels) ||
        CVPixelBufferLockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly)) {
        CVPixelBufferRelease(pixels); return NULL;
    }
    struct surface *entry=calloc(1,sizeof(*entry));
    if (!entry) {CVPixelBufferUnlockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly);CVPixelBufferRelease(pixels);return NULL;}
    entry->pixels=pixels;
    struct mp_image view={0}; mp_image_setfmt(&view,IMGFMT_NV12);
    mp_image_set_size(&view,CVPixelBufferGetWidth(pixels),CVPixelBufferGetHeight(pixels));
    for (int i=0;i<2;i++) {view.planes[i]=CVPixelBufferGetBaseAddressOfPlane(pixels,i);view.stride[i]=CVPixelBufferGetBytesPerRowOfPlane(pixels,i);}
    struct mp_image *out=mp_image_new_dummy_ref(&view);
    out->bufs[0]=av_buffer_create(NULL,0,release_surface,entry,AV_BUFFER_FLAG_READONLY);
    if (!out->bufs[0]) {talloc_free(out);release_surface(entry,NULL);return NULL;}
    entry->identity=out->bufs[0]->buffer;
    pthread_mutex_lock(&mutex);entry->next=surfaces;surfaces=entry;pthread_mutex_unlock(&mutex);
    mp_image_copy_attributes(out,attributes);
    out->params.hw_subfmt=0;
    // All buffers wrapped here are model outputs or our normalized input pool.
    out->params.repr.sys=PL_COLOR_SYSTEM_BT_709;
    out->params.repr.levels=PL_COLOR_LEVELS_LIMITED;
    out->params.chroma_location=PL_CHROMA_CENTER;
    struct mp_rect crop=attributes->params.crop;
    out->params.crop=(struct mp_rect){
        .x0=lrint((double)crop.x0*out->w/attributes->w),.y0=lrint((double)crop.y0*out->h/attributes->h),
        .x1=lrint((double)crop.x1*out->w/attributes->w),.y1=lrint((double)crop.y1*out->h/attributes->h)};
    return out;
}
static enum mp_imgfmt vt_software_imgfmt(CVPixelBufferRef p) {
    if (!p || CVPixelBufferGetPlaneCount(p)!=2 || !CVPixelBufferGetIOSurface(p)) return 0;
    OSType fmt=CVPixelBufferGetPixelFormatType(p);
    if (fmt==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        fmt==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) return IMGFMT_NV12;
    if (fmt==kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
        fmt==kCVPixelFormatType_420YpCbCr10BiPlanarFullRange) return IMGFMT_P010;
    return 0;
}
bool iive_surface_normalize(struct iive_normalizer *normalizer, CVPixelBufferRef dst, const struct mp_image *img) {
    if (!img || (img->fields & MP_IMGFIELD_INTERLACED) || img->imgfmt!=IMGFMT_VIDEOTOOLBOX || !img->planes[3] ||
        img->params.color.primaries!=PL_COLOR_PRIM_BT_709 ||
        img->params.color.transfer!=PL_COLOR_TRC_BT_1886 ||
        img->params.repr.sys!=PL_COLOR_SYSTEM_BT_709 ||
        (img->params.chroma_location!=PL_CHROMA_CENTER && img->params.chroma_location!=PL_CHROMA_LEFT) ||
        (img->params.repr.levels!=PL_COLOR_LEVELS_LIMITED && img->params.repr.levels!=PL_COLOR_LEVELS_FULL))return false;
    CVPixelBufferRef source=(CVPixelBufferRef)img->planes[3];
    enum mp_imgfmt sw_fmt=vt_software_imgfmt(source);
    if (img->w!=(int)CVPixelBufferGetWidth(source) || img->h!=(int)CVPixelBufferGetHeight(source) ||
        (sw_fmt!=IMGFMT_NV12 && sw_fmt!=IMGFMT_P010))return false;
    if (!normalizer->attempted) {
        normalizer->attempted=true;
        normalizer->engine=iive_nv12_create();
    }
    return iive_nv12_normalize(normalizer->engine,source,dst,
        img->params.repr.levels==PL_COLOR_LEVELS_FULL,img->params.chroma_location==PL_CHROMA_LEFT);
}
void iive_surface_normalizer_destroy(struct iive_normalizer *normalizer) {
    iive_nv12_destroy(normalizer->engine);
    *normalizer=(struct iive_normalizer){0};
}
bool iive_surface_supported_input(const struct mp_image *img) {
    if (!img) return false;
    // mp_image_sethwfmt() sets img->fmt to the *software* subformat descriptor.
    // Test the storage format instead, or VT NV12/P010 is sent to swscale as if
    // planes[0..1] held pixels (the CVPixelBuffer actually lives in planes[3]).
    if (!(mp_imgfmt_get_desc(img->imgfmt).flags & MP_IMGFLAG_HWACCEL))
        return mp_sws_supported_format(img->imgfmt);
    if (img->imgfmt!=IMGFMT_VIDEOTOOLBOX || !img->planes[3]) return false;
    CVPixelBufferRef p=(CVPixelBufferRef)img->planes[3];
    enum mp_imgfmt sw_fmt=vt_software_imgfmt(p);
    return sw_fmt && img->w==(int)CVPixelBufferGetWidth(p) && img->h==(int)CVPixelBufferGetHeight(p) &&
        mp_sws_supported_format(sw_fmt);
}
int iive_surface_scale_input(struct mp_sws_context *sws, struct mp_image *dst, struct mp_image *src) {
    if (!src || !dst) return -1;
    if (!(mp_imgfmt_get_desc(src->imgfmt).flags & MP_IMGFLAG_HWACCEL))
        return mp_sws_scale(sws,dst,src);
    if (src->imgfmt!=IMGFMT_VIDEOTOOLBOX || !src->planes[3]) return -1;
    CVPixelBufferRef p=(CVPixelBufferRef)src->planes[3];
    enum mp_imgfmt sw_fmt=vt_software_imgfmt(p);
    if (!sw_fmt || CVPixelBufferLockBaseAddress(p,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess) return -1;
    struct mp_image view=*src;
    mp_image_setfmt(&view,sw_fmt);
    mp_image_set_size(&view,src->w,src->h);
    view.params.hw_subfmt=0;
    for (int i=0;i<2;i++) {
        view.planes[i]=CVPixelBufferGetBaseAddressOfPlane(p,i);
        view.stride[i]=CVPixelBufferGetBytesPerRowOfPlane(p,i);
    }
    int result=mp_sws_scale(sws,dst,&view);
    CVPixelBufferUnlockBaseAddress(p,kCVPixelBufferLock_ReadOnly);
    return result;
}
// Shared inputs must already satisfy the model's pixel contract. Attachments on
// decoder-owned buffers are read-only here: relabeling chroma is not resampling.
static bool iive_is_supported_sdr(const struct mp_image *img) {
    return img && img->params.repr.levels == PL_COLOR_LEVELS_LIMITED &&
        img->params.repr.sys == PL_COLOR_SYSTEM_BT_709 &&
        img->params.color.primaries == PL_COLOR_PRIM_BT_709 &&
        img->params.color.transfer == PL_COLOR_TRC_BT_1886 &&
        img->params.chroma_location == PL_CHROMA_CENTER;
}
static bool attachment_matches(CVPixelBufferRef pixels, CFStringRef key, CFStringRef expected) {
    CFTypeRef value = CVBufferCopyAttachment(pixels, key, NULL);
    bool matches = value && CFEqual(value, expected);
    if (value) CFRelease(value);
    return matches;
}
CVPixelBufferRef iive_surface_acquire_fsr_left(const struct mp_image *img) {
    if(!img || (img->fields & MP_IMGFIELD_INTERLACED) || img->imgfmt!=IMGFMT_VIDEOTOOLBOX || !img->planes[3] ||
       img->params.repr.levels!=PL_COLOR_LEVELS_LIMITED || img->params.repr.sys!=PL_COLOR_SYSTEM_BT_709 ||
       img->params.color.primaries!=PL_COLOR_PRIM_BT_709 || img->params.color.transfer!=PL_COLOR_TRC_BT_1886 ||
       img->params.chroma_location!=PL_CHROMA_LEFT)return NULL;
    CVPixelBufferRef pixels=(CVPixelBufferRef)img->planes[3];
    if(CVPixelBufferGetPixelFormatType(pixels)!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
       CVPixelBufferGetPlaneCount(pixels)!=2 || !CVPixelBufferGetIOSurface(pixels) ||
       img->w!=(int)CVPixelBufferGetWidth(pixels) || img->h!=(int)CVPixelBufferGetHeight(pixels))return NULL;
    return CVPixelBufferRetain(pixels);
}
CVPixelBufferRef iive_surface_acquire_fsr_p010(const struct mp_image *img, bool *out_left) {
    if(!img || (img->fields & MP_IMGFIELD_INTERLACED) || img->imgfmt!=IMGFMT_VIDEOTOOLBOX || !img->planes[3] ||
       img->params.repr.levels!=PL_COLOR_LEVELS_LIMITED || img->params.repr.sys!=PL_COLOR_SYSTEM_BT_709 ||
       img->params.color.primaries!=PL_COLOR_PRIM_BT_709 || img->params.color.transfer!=PL_COLOR_TRC_BT_1886 ||
       (img->params.chroma_location!=PL_CHROMA_CENTER && img->params.chroma_location!=PL_CHROMA_LEFT))return NULL;
    CVPixelBufferRef pixels=(CVPixelBufferRef)img->planes[3];
    if(CVPixelBufferGetPixelFormatType(pixels)!=kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
       CVPixelBufferGetPlaneCount(pixels)!=2 || !CVPixelBufferGetIOSurface(pixels) ||
       img->w!=(int)CVPixelBufferGetWidth(pixels) || img->h!=(int)CVPixelBufferGetHeight(pixels))return NULL;
    if(out_left)*out_left=(img->params.chroma_location==PL_CHROMA_LEFT);
    return CVPixelBufferRetain(pixels);
}
CVPixelBufferRef iive_surface_acquire(const struct mp_image *img) {
    if (!iive_is_supported_sdr(img))
        return NULL;
    if (img->imgfmt==IMGFMT_VIDEOTOOLBOX && img->planes[3]) {
        CVPixelBufferRef p=(CVPixelBufferRef)img->planes[3];
        if (CVPixelBufferGetPixelFormatType(p)!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
            CVPixelBufferGetPlaneCount(p)!=2 || !CVPixelBufferGetIOSurface(p) ||
            img->w!=(int)CVPixelBufferGetWidth(p) || img->h!=(int)CVPixelBufferGetHeight(p))
            return NULL;
        if (!attachment_matches(p, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2) ||
            !attachment_matches(p, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2) ||
            !attachment_matches(p, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2) ||
            !attachment_matches(p, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center))
            return NULL;
        return CVPixelBufferRetain(p);
    }
    if (img->imgfmt!=IMGFMT_NV12 || !img->bufs[0] || img->params.chroma_location!=PL_CHROMA_CENTER) return NULL;
    CVPixelBufferRef result=NULL;
    pthread_mutex_lock(&mutex);
    for (struct surface *s=surfaces;s;s=s->next) {
        if (s->identity!=img->bufs[0]->buffer) continue;
        CVPixelBufferRef p=s->pixels;
        bool same=img->w==CVPixelBufferGetWidth(p) && img->h==CVPixelBufferGetHeight(p);
        for (int i=0;i<2;i++) same= same && img->planes[i]==CVPixelBufferGetBaseAddressOfPlane(p,i) && img->stride[i]==CVPixelBufferGetBytesPerRowOfPlane(p,i);
        if (same) result=CVPixelBufferRetain(p);
        break;
    }
    pthread_mutex_unlock(&mutex);
    return result;
}
