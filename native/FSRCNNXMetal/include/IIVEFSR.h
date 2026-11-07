// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef IIVE_FSR_H
#define IIVE_FSR_H
#include <stdint.h>
#include <CoreVideo/CoreVideo.h>
// Serial caller, fixed dimensions, tier 8 or 16. Inputs/outputs returned +1.
void *iive_fsr_create(int32_t width, int32_t height, int32_t tier);
CVPixelBufferRef iive_fsr_input(void *handle);
CVPixelBufferRef iive_fsr_process(void *handle, CVPixelBufferRef input);
// Input: limited-range BT.709 NV12 or P010 (x420), either centered or explicitly left-sited.
CVPixelBufferRef iive_fsr_process_chroma(void *handle, CVPixelBufferRef input, int32_t left);
// Same as iive_fsr_process_chroma, with optional splitRatio in [0, 1] rendering original luma on the left.
CVPixelBufferRef iive_fsr_process_split(void *handle, CVPixelBufferRef input, int32_t left, float split_ratio);
void iive_fsr_destroy(void *handle);
// Serial worker, after inference: reclaim idle surfaces without recompiling.
void iive_fsr_trim(void *handle);
// Last successful inference: GPU start-to-end span across all submissions and
// wall time blocked in the final CPU wait. They overlap; do not add them.
// Serial caller, immediately after successful process/push. Returns 1 if valid,
// otherwise 0 and writes -1. No additional synchronization. Units: milliseconds.
int32_t iive_fsr_timing(void *handle,double *gpu_span_ms,double *cpu_wait_ms);
#endif
