/* SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once
#include <stdbool.h>
#include <CoreVideo/CoreVideo.h>
struct mp_image;
struct mp_sws_context;
struct iive_normalizer { void *engine; bool attempted; };
// Normalizes supported VT NV12 or P010 on the GPU into the caller's pooled NV12 destination.
// Returns false for unsupported input/GPU failure; caller retains its swscale fallback.
bool iive_surface_normalize(struct iive_normalizer *normalizer, CVPixelBufferRef destination, const struct mp_image *image);
void iive_surface_normalizer_destroy(struct iive_normalizer *normalizer);
// Wraps normalized model/input-pool NV12 (BT.709 matrix, limited range, centered chroma).
// Not for arbitrary decoder buffers. Consumes the +1 reference, including on failure.
struct mp_image *iive_surface_wrap(CVPixelBufferRef pixels, struct mp_image *attributes);
// Returns +1 for an unchanged NV12 BT.709/BT.1886 limited-range, centered IOSurface.
// Decoder attachments must already agree; incompatible inputs require real conversion.
CVPixelBufferRef iive_surface_acquire(const struct mp_image *image);
// Retains a left-sited 420v VT frame for FSRCNNX's fused chroma output kernel.
CVPixelBufferRef iive_surface_acquire_fsr_left(const struct mp_image *image);
// Retains a 10-bit limited-range BT.709/BT.1886 x420 VT frame (centered or left chroma) for FSRCNNX direct 10-bit Metal input.
CVPixelBufferRef iive_surface_acquire_fsr_p010(const struct mp_image *image, bool *out_left);
// Returns true if the input frame is supported by swscale or is a valid 2-plane IOSurface VT frame.
bool iive_surface_supported_input(const struct mp_image *image);
// Scales/converts a software or VideoToolbox hardware frame into dst via mp_sws_scale.
int iive_surface_scale_input(struct mp_sws_context *sws, struct mp_image *dst, struct mp_image *src);
