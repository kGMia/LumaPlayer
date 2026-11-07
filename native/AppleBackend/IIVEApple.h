// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <CoreVideo/CoreVideo.h>
#include <stdbool.h>
// Single worker ownership. Returned buffers are retained; caller releases.
void *iive_apple_create(int width, int height, int interpolation, float scale);
CVPixelBufferRef iive_apple_input(void *handle);
CVPixelBufferRef iive_apple_process(void *handle, CVPixelBufferRef current,
                                  CVPixelBufferRef previous, double pts, double previous_pts);
void iive_apple_trim(void *handle);
void iive_apple_destroy(void *handle);
// Per-worker Metal converter; input must already have BT.709/BT.1886 color.
void *iive_nv12_create(void);
bool iive_nv12_normalize(void *handle, CVPixelBufferRef source, CVPixelBufferRef destination, bool full_range, bool left_chroma);
void iive_nv12_destroy(void *handle);
