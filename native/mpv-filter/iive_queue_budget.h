/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef IIVE_QUEUE_BUDGET_H
#define IIVE_QUEUE_BUDGET_H
#include <stdint.h>
#include <stdbool.h>
#include <math.h>

// Per-stage scheduling target, NOT total process/GPU memory or a hard allocator
// limit. Model workspaces, decoder buffers and pixel-pool caches are excluded.
// A mandatory batch may exceed the target; empty queues must always make progress.
#define IIVE_QUEUE_SURFACE_TARGET (UINT64_C(128) * 1024 * 1024)

// Supported enhancement outputs are NV12/BGRA8. Budget conservatively at four
// bytes/pixel with 256-byte row alignment; this is not measured resident memory.
static inline uint64_t iive_queue_frame_estimate(int width, int height) {
    if (width <= 0 || height <= 0) return 0;
    uint64_t row = ((uint64_t)width * 4 + 255) & ~UINT64_C(255);
    return row * (uint64_t)height;
}

// Reserve the largest worker batch plus one frame handed downstream. Keep this
// memory cap separate from the latency hysteresis, whose legal states are 1/2/4.
static inline int iive_queue_prefetch_limit(uint64_t frame_bytes, int reserved, int requested) {
    if (!frame_bytes || reserved < 0 || requested <= 0) return 0;
    uint64_t slots = IIVE_QUEUE_SURFACE_TARGET / frame_bytes;
    if (slots <= (uint64_t)reserved) return 0;
    uint64_t available = slots - (uint64_t)reserved;
    return available < (uint64_t)requested ? (int)available : requested;
}

// Media-time lookahead relative to the last frame handed downstream, NOT the
// renderer's presentation clock or an end-to-end latency measurement.
struct iive_queue_timeline {
    double last_pts, step, nominal_fps;
    bool valid;
};

static inline void iive_queue_note_output(struct iive_queue_timeline *t,
                                          double pts, double nominal_fps) {
    double dt = pts - t->last_pts;
    if (t->valid && isfinite(pts) && dt >= 0.001 && dt <= 0.5)
        t->step = t->step > 0 ? t->step * 0.75 + dt * 0.25 : dt;
    else
        t->step = 0; // seek/discontinuity/unknown PTS must not inherit cadence
    t->last_pts = pts;
    t->valid = isfinite(pts);
    t->nominal_fps = isfinite(nominal_fps) && nominal_fps > 0 ? nominal_fps : 0;
}

// Admit near the expected worker lead time plus one output interval, bounded
// by two intervals / 50 ms. Existing count and memory limits also apply. The
// mandatory worker batch may exceed this window; empty queues always progress.
static inline bool iive_queue_time_admit(const struct iive_queue_timeline *t,
                                         double tail_pts, int queued, double speed,
                                         double p95_ms, double *ahead_ms, double *budget_ms) {
    *ahead_ms = *budget_ms = -1;
    if (queued <= 0) return true;
    if (!isfinite(speed) || speed <= 0) return false;
    double step = t->step > 0 ? t->step : t->nominal_fps > 0 ? 1.0 / t->nominal_fps : 0;
    if (step > 0) {
        double interval = step * 1000 / speed;
        double lead = isfinite(p95_ms) && p95_ms >= 0 ? p95_ms + interval : 2 * interval;
        *budget_ms = fmin(50.0, fmin(2 * interval, fmax(interval, lead)));
    }
    if (!t->valid || !isfinite(tail_pts) || tail_pts <= t->last_pts || *budget_ms < 0)
        return queued <= 1; // bounded fallback for missing/discontinuous timestamps
    *ahead_ms = (tail_pts - t->last_pts) * 1000 / speed;
    return *ahead_ms <= *budget_ms + 0.001; // floating-point PTS tolerance, ms
}
#endif
