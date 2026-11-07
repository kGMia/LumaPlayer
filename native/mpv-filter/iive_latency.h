/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef IIVE_LATENCY_H
#define IIVE_LATENCY_H

#include <math.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

// Worker wall time, not frame presentation latency. Caller owns synchronization.
#define IIVE_LATENCY_CAPACITY 120
struct iive_latency_window {
    double samples[IIVE_LATENCY_CAPACITY];
    unsigned count, next;
};

static inline void iive_latency_reset(struct iive_latency_window *window)
{
    memset(window, 0, sizeof(*window));
}

static inline void iive_latency_add(struct iive_latency_window *window, double ms)
{
    if (!isfinite(ms) || ms < 0) return;
    window->samples[window->next] = ms;
    window->next = (window->next + 1) % IIVE_LATENCY_CAPACITY;
    if (window->count < IIVE_LATENCY_CAPACITY) window->count++;
}

static inline int iive_latency_compare(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

// Nearest-rank percentiles. Caller controls snapshot frequency.
static inline bool iive_latency_read(const struct iive_latency_window *window,
                                     double *p50, double *p95)
{
    if (!window->count) return false;
    double sorted[IIVE_LATENCY_CAPACITY];
    memcpy(sorted, window->samples, window->count * sizeof(double));
    qsort(sorted, window->count, sizeof(double), iive_latency_compare);
    *p50 = sorted[(window->count * 50 + 99) / 100 - 1];
    *p95 = sorted[(window->count * 95 + 99) / 100 - 1];
    return true;
}

// Effective per-pair budget in ms from VFR frame timestamp delta (or nominal FPS fallback) and playback speed.
static inline double iive_pair_budget_ms(double pair_span_sec, double source_fps, double speed)
{
    if (!isfinite(speed) || speed <= 0) return 0.0;
    double span_ms = 0.0;
    if (isfinite(pair_span_sec) && pair_span_sec >= 0.001 && pair_span_sec <= 0.5)
        span_ms = pair_span_sec * 1000.0;
    else if (isfinite(source_fps) && source_fps > 0)
        span_ms = 1000.0 / source_fps;
    else
        return 0.0;
    return span_ms / speed;
}

// Stateless helper (used for initial sizing / cold-start).
static inline int iive_prefetch_limit(int width, int height, double source_fps,
                                      double speed, double p95_ms)
{
    int limit = (double)width * height > 1920.0 * 1080.0 ? 1 : 4;
    if (!isfinite(source_fps) || source_fps <= 0 ||
        !isfinite(speed) || speed <= 0 || !isfinite(p95_ms) || p95_ms < 0)
        return limit;
    double budget_ms = 1000.0 / source_fps / speed;
    if (p95_ms > budget_ms * 0.85) return 1;
    if (p95_ms > budget_ms * 0.60 && limit > 2) return 2;
    return limit;
}

// Hysteresis-aware prefetch limit using VFR timestamp span + nominal FPS fallback.
// Tightens at >60% / >85% of pair budget; relaxes only below <45% / <65% to prevent oscillation.
static inline int iive_prefetch_limit_hysteresis(int width, int height, int current_limit,
                                                 double pair_span_sec, double source_fps,
                                                 double speed, double p95_ms)
{
    if ((double)width * height > 1920.0 * 1080.0) return 1;
    int limit = (current_limit == 1 || current_limit == 2 || current_limit == 4) ? current_limit : 4;
    double budget_ms = iive_pair_budget_ms(pair_span_sec, source_fps, speed);
    if (budget_ms <= 0.0 || !isfinite(p95_ms) || p95_ms < 0)
        return limit;
    // Step down immediately when P95 exceeds upper thresholds
    if (p95_ms > budget_ms * 0.85) return 1;
    if (p95_ms > budget_ms * 0.60 && limit > 2) return 2;
    // Step up only after P95 drops below lower hysteresis thresholds
    if (limit == 1) {
        if (p95_ms < budget_ms * 0.40) return 4;
        if (p95_ms < budget_ms * 0.65) return 2;
        return 1;
    }
    if (limit == 2) {
        if (p95_ms < budget_ms * 0.45) return 4;
        return 2;
    }
    return limit;
}
#endif
