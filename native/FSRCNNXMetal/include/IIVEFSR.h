// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef IIVE_FSR_H
#define IIVE_FSR_H
#include <stdint.h>
#include <CoreVideo/CoreVideo.h>
// Serial caller, fixed dimensions, tier 8 or 16. Inputs/outputs returned +1.
void *iive_fsr_create(int32_t width, int32_t height, int32_t tier);
CVPixelBufferRef iive_fsr_input(void *handle);
CVPixelBufferRef iive_fsr_process(void *handle, CVPixelBufferRef input);
void iive_fsr_destroy(void *handle);
#endif
