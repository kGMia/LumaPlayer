/* SPDX-License-Identifier: GPL-3.0-or-later
 * Share IOSurfaces between our filters without guessing AVBuffer opaque layouts.
 * The registry does not own extra frames. Entries live exactly as long as their
 * read-only AVBuffer; the mutex covers lookup/retain and final removal.
 */
#include <stdlib.h>
#include <math.h>
#include <pthread.h>
#include <libavutil/buffer.h>
#include "video/mp_image.h"
#include "video/img_format.h"
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
    out->params.repr.sys=PL_COLOR_SYSTEM_BT_709;out->params.repr.levels=PL_COLOR_LEVELS_LIMITED;
    out->params.chroma_location=PL_CHROMA_CENTER;
    struct mp_rect crop=attributes->params.crop;
    out->params.crop=(struct mp_rect){
        .x0=lrint((double)crop.x0*out->w/attributes->w),.y0=lrint((double)crop.y0*out->h/attributes->h),
        .x1=lrint((double)crop.x1*out->w/attributes->w),.y1=lrint((double)crop.y1*out->h/attributes->h)};
    return out;
}
CVPixelBufferRef iive_surface_acquire(const struct mp_image *img) {
    if (img->imgfmt!=IMGFMT_NV12 || !img->bufs[0] ||
        img->params.repr.sys!=PL_COLOR_SYSTEM_BT_709 || img->params.repr.levels!=PL_COLOR_LEVELS_LIMITED ||
        img->params.color.primaries!=PL_COLOR_PRIM_BT_709 || img->params.color.transfer!=PL_COLOR_TRC_BT_1886 ||
        img->params.chroma_location!=PL_CHROMA_CENTER) return NULL;
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
