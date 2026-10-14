/* SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once
#include <CoreVideo/CoreVideo.h>
struct mp_image;
// Consumes the +1 pixel-buffer reference, including on failure.
struct mp_image *iive_surface_wrap(CVPixelBufferRef pixels, struct mp_image *attributes);
// Returns +1 only for an unchanged, owned NV12 BT.709 video-range surface.
CVPixelBufferRef iive_surface_acquire(const struct mp_image *image);
