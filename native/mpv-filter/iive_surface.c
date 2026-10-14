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
    if (out->params.repr.sys==PL_COLOR_SYSTEM_UNKNOWN)
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
static bool iive_is_supported_sdr(const struct mp_image *img) {
    if (!img) return false;
    enum pl_color_levels levels = img->params.repr.levels;
    if (levels != PL_COLOR_LEVELS_LIMITED && levels != PL_COLOR_LEVELS_UNKNOWN)
        return false;
    enum pl_color_system sys = img->params.repr.sys;
    if (sys != PL_COLOR_SYSTEM_BT_709 &&
        sys != PL_COLOR_SYSTEM_BT_601 &&
        sys != PL_COLOR_SYSTEM_BT_2020_NC &&
        sys != PL_COLOR_SYSTEM_UNKNOWN)
        return false;
    enum pl_color_transfer trc = img->params.color.transfer;
    if (trc != PL_COLOR_TRC_BT_1886 &&
        trc != PL_COLOR_TRC_SRGB &&
        trc != PL_COLOR_TRC_GAMMA22 &&
        trc != PL_COLOR_TRC_GAMMA28 &&
        trc != PL_COLOR_TRC_UNKNOWN)
        return false;
    return true;
}
static void iive_apply_cv_color_attachments(CVPixelBufferRef p, const struct mp_image *img) {
    CFStringRef matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2;
    if (img->params.repr.sys == PL_COLOR_SYSTEM_BT_601)
        matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4;
    else if (img->params.repr.sys == PL_COLOR_SYSTEM_BT_2020_NC)
        matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020;

    CFStringRef primaries = kCVImageBufferColorPrimaries_ITU_R_709_2;
    switch (img->params.color.primaries) {
    case PL_COLOR_PRIM_BT_601_525:
        primaries = kCVImageBufferColorPrimaries_SMPTE_C;
        break;
    case PL_COLOR_PRIM_BT_601_625:
        primaries = kCVImageBufferColorPrimaries_EBU_3213;
        break;
    case PL_COLOR_PRIM_DISPLAY_P3:
        primaries = kCVImageBufferColorPrimaries_P3_D65;
        break;
    case PL_COLOR_PRIM_BT_2020:
        primaries = kCVImageBufferColorPrimaries_ITU_R_2020;
        break;
    default:
        break;
    }

    CFStringRef transfer = kCVImageBufferTransferFunction_ITU_R_709_2;
    if (img->params.color.transfer == PL_COLOR_TRC_SRGB)
        transfer = kCVImageBufferTransferFunction_sRGB;

    CVBufferSetAttachment(p, kCVImageBufferYCbCrMatrixKey, matrix, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(p, kCVImageBufferColorPrimariesKey, primaries, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(p, kCVImageBufferTransferFunctionKey, transfer, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(p, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center, kCVAttachmentMode_ShouldPropagate);
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
        iive_apply_cv_color_attachments(p, img);
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
