/* SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once
#include <stdbool.h>
#include <CoreVideo/CoreVideo.h>
struct mp_image;
struct mp_sws_context;
// Consumes the +1 pixel-buffer reference, including on failure.
struct mp_image *iive_surface_wrap(CVPixelBufferRef pixels, struct mp_image *attributes);
// Returns +1 for an unchanged, owned NV12 BT.709 video-range surface or zero-copy VT hardware frame.
CVPixelBufferRef iive_surface_acquire(const struct mp_image *image);
// Returns true if the input frame is supported by swscale or is a valid 2-plane IOSurface VT frame.
bool iive_surface_supported_input(const struct mp_image *image);
// Scales/converts a software or VideoToolbox hardware frame into dst via mp_sws_scale.
int iive_surface_scale_input(struct mp_sws_context *sws, struct mp_image *dst, struct mp_image *src);
