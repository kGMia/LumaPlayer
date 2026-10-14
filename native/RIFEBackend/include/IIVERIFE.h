#ifndef IIVE_RIFE_H
#define IIVE_RIFE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// arm64 macOS 13+. Tier: 0 fast, 1 balanced, 2 hq; NULL indicates failure.
// Single caller per handle. BGRA8 SDR IOSurface-backed CVPixelBuffers only.
// Input buffers borrowed for duration of call. Output +1; release with API.
void *iive_rife_create(int32_t tier);
void iive_rife_destroy(void *handle);
void *iive_rife_interpolate(void *handle,const void *previous,const void *current,float timestep);
void iive_rife_release_frame(void *pixels);
// Streaming API: one adjacent pair, bounded output interval. Drain pop before push.
// Accepts BGRA8, or IOSurface 420v NV12 tagged BT.709 matrix + centered chroma.
// Keep format/dimensions fixed until reset. Stream retains input frames as needed;
// caller must not modify a submitted buffer while the stream/output still owns it.
// NV12 input produces native NV12 source and synthesized outputs. BGRA input
// retains its BGRA output contract. Inspect format; output owns a +1 reference.
// PTS are seconds on the player's media timeline, never wall-clock timestamps.
void *iive_stream_create(int32_t width,int32_t height,int32_t fps,int32_t tier,int32_t fallback);
void iive_stream_destroy(void *handle);
void iive_stream_reset(void *handle);
int32_t iive_stream_push(void *handle,const void *pixels,double pts);
int32_t iive_stream_finish(void *handle,double end_pts);
// NULL when empty. Returned CVPixelBuffer is +1, released via release_frame.
void *iive_stream_pop(void *handle,double *pts,int32_t *synthesized);
int32_t iive_stream_fallback(void *handle);
#ifdef __cplusplus
}
#endif
#endif
