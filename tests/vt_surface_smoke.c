/* SPDX-License-Identifier: GPL-3.0-or-later
 * No window/model inference: exercise the real mpv frame and surface adapter.
 */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <CoreVideo/CoreVideo.h>
#include "video/mp_image.h"
#include "video/img_format.h"
#include "video/sws_utils.h"
#include "video/filter/iive_surface.h"

static void check_vt(OSType format, int sw_format)
{
    const void *keys[] = {kCVPixelBufferIOSurfacePropertiesKey};
    CFDictionaryRef empty = CFDictionaryCreate(NULL, NULL, NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *values[] = {empty};
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CVPixelBufferRef pixels = NULL;
    assert(CVPixelBufferCreate(NULL, 16, 16, format, attrs, &pixels) == kCVReturnSuccess);
    CFRelease(attrs); CFRelease(empty);
    assert(CVPixelBufferGetIOSurface(pixels));

    struct mp_image img = {0};
    mp_image_sethwfmt(&img, IMGFMT_VIDEOTOOLBOX, sw_format);
    mp_image_set_size(&img, 16, 16);
    img.planes[3] = (uint8_t *)pixels;
    img.params.color.primaries = PL_COLOR_PRIM_BT_709;
    img.params.color.transfer = PL_COLOR_TRC_BT_1886;
    img.params.repr.sys = PL_COLOR_SYSTEM_BT_709;
    img.params.repr.levels = PL_COLOR_LEVELS_LIMITED;
    img.params.chroma_location = PL_CHROMA_CENTER;
    // Reproduce the upstream contract that caused auto hardware to bypass.
    assert(!(img.fmt.flags & MP_IMGFLAG_HWACCEL));
    assert(mp_imgfmt_get_desc(img.imgfmt).flags & MP_IMGFLAG_HWACCEL);
    assert(iive_surface_supported_input(&img));

    assert(CVPixelBufferLockBaseAddress(pixels, 0) == kCVReturnSuccess);
    for (int plane = 0; plane < 2; plane++) {
        uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(pixels, plane);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, plane);
        size_t rows = CVPixelBufferGetHeightOfPlane(pixels, plane);
        if (sw_format == IMGFMT_NV12) memset(base, plane ? 128 : 81, stride * rows);
        else for (size_t y = 0; y < rows; y++) {
            uint16_t *row = (uint16_t *)(base + y * stride);
            for (size_t x = 0; x < stride / 2; x++) row[x] = (plane ? 512 : 324) << 6;
        }
    }
    CVPixelBufferUnlockBaseAddress(pixels, 0);
    struct mp_image *dst = mp_image_alloc(IMGFMT_NV12, 16, 16);
    assert(dst);
    mp_image_copy_attributes(dst, &img);
    struct mp_sws_context *sws = mp_sws_alloc(NULL);
    assert(iive_surface_scale_input(sws, dst, &img) >= 0);
    assert(abs((int)dst->planes[0][0] - 81) <= 1);
    assert(abs((int)dst->planes[1][0] - 128) <= 1);
    assert(img.imgfmt == IMGFMT_VIDEOTOOLBOX && img.planes[3] == (uint8_t *)pixels);
    assert(!img.planes[0] && !img.planes[1]); // decoder ownership/layout untouched
    img.planes[3] = NULL;
    assert(!iive_surface_supported_input(&img));
    assert(iive_surface_scale_input(sws, dst, &img) < 0);
    talloc_free(sws); talloc_free(dst); CVPixelBufferRelease(pixels);
}

int main(void)
{
    check_vt(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, IMGFMT_NV12);
    check_vt(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, IMGFMT_P010);
    struct mp_image *sw = mp_image_alloc(IMGFMT_420P, 16, 16);
    assert(sw && iive_surface_supported_input(sw));
    talloc_free(sw);
    struct mp_image other = {0};
    mp_image_sethwfmt(&other, IMGFMT_VAAPI, IMGFMT_NV12);
    assert(!iive_surface_supported_input(&other));
    assert(!iive_surface_supported_input(NULL));
    puts("PASS: VT NV12/P010 input acceptance and pixel conversion; missing/other hardware rejected; software accepted");
}
