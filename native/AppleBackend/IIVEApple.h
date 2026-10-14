// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <CoreVideo/CoreVideo.h>
// Single worker ownership. Returned buffers are retained; caller releases.
void *iive_apple_create(int width, int height, int interpolation, float scale);
CVPixelBufferRef iive_apple_input(void *handle);
CVPixelBufferRef iive_apple_process(void *handle, CVPixelBufferRef current,
                                  CVPixelBufferRef previous, double pts, double previous_pts);
void iive_apple_destroy(void *handle);
