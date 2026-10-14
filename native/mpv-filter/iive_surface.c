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
    out->params.repr.sys=PL_COLOR_SYSTEM_BT_709;out->params.repr.levels=PL_COLOR_LEVELS_LIMITED;
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
bool iive_surface_supported_input(const struct mp_image *img) {
    if (!img) return false;
    if (!(img->fmt.flags & MP_IMGFLAG_HWACCEL)) return mp_sws_supported_format(img->imgfmt);
    if (img->imgfmt!=IMGFMT_VIDEOTOOLBOX || !img->planes[3]) return false;
    CVPixelBufferRef p=(CVPixelBufferRef)img->planes[3];
    enum mp_imgfmt sw_fmt=vt_software_imgfmt(p);
    return sw_fmt && img->w==(int)CVPixelBufferGetWidth(p) && img->h==(int)CVPixelBufferGetHeight(p) &&
        mp_sws_supported_format(sw_fmt);
}
int iive_surface_scale_input(struct mp_sws_context *sws, struct mp_image *dst, struct mp_image *src) {
    if (!(src->fmt.flags & MP_IMGFLAG_HWACCEL)) return mp_sws_scale(sws,dst,src);
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
CVPixelBufferRef iive_surface_acquire(const struct mp_image *img) {
    if (!img ||
        img->params.repr.sys!=PL_COLOR_SYSTEM_BT_709 || img->params.repr.levels!=PL_COLOR_LEVELS_LIMITED ||
        img->params.color.primaries!=PL_COLOR_PRIM_BT_709 || img->params.color.transfer!=PL_COLOR_TRC_BT_1886)
        return NULL;
    if (img->imgfmt==IMGFMT_VIDEOTOOLBOX && img->planes[3]) {
        CVPixelBufferRef p=(CVPixelBufferRef)img->planes[3];
        if (CVPixelBufferGetPixelFormatType(p)!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
            CVPixelBufferGetPlaneCount(p)!=2 || !CVPixelBufferGetIOSurface(p) ||
            img->w!=(int)CVPixelBufferGetWidth(p) || img->h!=(int)CVPixelBufferGetHeight(p))
            return NULL;
        CVBufferSetAttachment(p,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(p,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(p,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(p,kCVImageBufferChromaLocationTopFieldKey,kCVImageBufferChromaLocation_Center,kCVAttachmentMode_ShouldPropagate);
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
