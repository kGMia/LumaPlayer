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
// Extended creation reports a stable code even when no handle could be created.
// Per-handle last_error is cleared by reset or the next mutating call; read it
// immediately after failure, before destroy. Serial caller, no shared TLS state.
void *iive_stream_create_with_error(int32_t width,int32_t height,int32_t fps,int32_t tier,int32_t fallback,int32_t *error);
// Called synchronously on the creating worker between compile stages. Neither
// callback nor context is retained; both must live until this function returns.
// Nonzero means cancel (code 102). Never forcibly interrupts a compile/GPU call.
typedef int32_t (*iive_stream_cancel_probe)(void *context);
void *iive_stream_create_cancellable(int32_t width,int32_t height,int32_t fps,int32_t tier,int32_t fallback,iive_stream_cancel_probe canceled,void *context,int32_t *error);
int32_t iive_stream_last_error(void *handle);
// Immutable initial preparation snapshot, serial caller; never waits for GPU.
// Writes five milliseconds values: weights/context/pool/graph build+compile/
// rounding probe. -1 means unavailable/not requested. Returns 1 with a valid
// handle. Capacity < 5 or NULL output writes nothing; NULL handle writes -1s.
int32_t iive_stream_preparation_timing(void *handle,double *values,int32_t capacity);
// Initial compilation reuse: 1 hit, 0 miss, -1 unavailable. Serial snapshot.
int32_t iive_stream_compilation_cache_hit(void *handle);
static inline const char *iive_stream_error_name(int32_t code) {
    switch(code) {
    case 0:return "none";
    case 100:return "invalid-argument";
    case 101:return "pending-output-not-drained";
    case 102:return "canceled";
    case 200:return "stream-validation";
    case 201:return "model-load";
    case 202:return "pixel-format";
    case 203:return "dimensions";
    case 204:return "metal-unavailable";
    case 205:return "shader-compilation";
    case 206:return "inference";
    case 207:return "timesteps";
    case 301:return "input-pool-allocation";
    case 302:return "input-lock";
    case 303:return "input-conversion";
    case 401:return "output-capacity";
    case 402:return "output-empty";
    case 403:return "output-surface-wrap";
    case 404:return "output-allocation";
    case 405:return "output-lock";
    case 406:return "output-conversion";
    case 407:return "output-pixel-format";
    default:return "unknown";
    }
}
void iive_stream_destroy(void *handle);
void iive_stream_reset(void *handle);
// Serial caller, after draining pop(). Retains timeline/previous source frame.
// Returns 0 on success, -1 on failure (old stream remains intact).
int32_t iive_stream_set_tier(void *handle,int32_t tier);
// Nonblocking preparation request/poll. Same serial/drained contract; 1 means
// preparing (push emits source holds, synthesized=0), 0 applied, -1 failed.
// Poll with the desired tier before each push. Reset/finish/destroy cancels it.
int32_t iive_stream_request_tier(void *handle,int32_t tier);
int32_t iive_stream_push(void *handle,const void *pixels,double pts);
// Exact-seek pre-roll only: source holds on the unchanged output clock, no AI.
// Caller guarantees these intervals cannot be displayed; restore normal push
// with sufficient adjacent-pair context before the target. Same drain contract.
int32_t iive_stream_push_preroll(void *handle,const void *pixels,double pts,int32_t preroll);
int32_t iive_stream_finish(void *handle,double end_pts);
// NULL when empty. Returned CVPixelBuffer is +1, released via release_frame.
void *iive_stream_pop(void *handle,double *pts,int32_t *synthesized);
int32_t iive_stream_fallback(void *handle);
// Last successful inference: GPU start-to-end span across all submissions and
// wall time blocked in the final CPU wait. They overlap; do not add them.
// Serial caller, immediately after successful process/push. Returns 1 if valid,
// otherwise 0 and writes -1. No additional synchronization. Units: milliseconds.
int32_t iive_stream_timing(void *handle,double *gpu_span_ms,double *cpu_wait_ms);
#ifdef __cplusplus
}
#endif
#endif
