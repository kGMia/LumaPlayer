/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include "../native/mpv-filter/iive_latency.h"

int main(void)
{
    struct iive_latency_window window = {0};
    double p50 = -1, p95 = -1;
    assert(!iive_latency_read(&window, &p50, &p95));
    iive_latency_add(&window, NAN);
    iive_latency_add(&window, INFINITY);
    iive_latency_add(&window, -1);
    assert(window.count == 0);
    iive_latency_add(&window, 0);
    assert(iive_latency_read(&window, &p50, &p95) && p50 == 0 && p95 == 0);
    iive_latency_reset(&window);
    for (int i = 120; i > 0; i--) iive_latency_add(&window, i);
    assert(iive_latency_read(&window, &p50, &p95) && p50 == 60 && p95 == 114);
    iive_latency_add(&window, 240);
    assert(window.count == 120 && window.next == 1);
    assert(iive_latency_read(&window, &p50, &p95) && p50 == 60 && p95 == 114);
    for (int i = 0; i < 120; i++) iive_latency_add(&window, 7.5);
    assert(iive_latency_read(&window, &p50, &p95) && p50 == 7.5 && p95 == 7.5);
    iive_latency_reset(&window);
    assert(window.count == 0 && window.next == 0);
    assert(!iive_latency_read(&window, &p50, &p95));

    // Stateless budget check
    assert(iive_prefetch_limit(1920, 1080, 24, 1, 24) == 4);
    assert(iive_prefetch_limit(1920, 1080, 30, 1, 24) == 2);
    assert(iive_prefetch_limit(1920, 1080, 60, 1, 24) == 1);
    assert(iive_prefetch_limit(1920, 1080, 24, 2, 24) == 1);
    assert(iive_prefetch_limit(3840, 2160, 24, 1, 1) == 1);
    assert(iive_prefetch_limit(1920, 1080, NAN, 1, 24) == 4);

    // VFR timestamp budget + hysteresis check (e.g. nominal 60fps container with 24fps VFR cadence = 41.67ms span)
    assert(fabs(iive_pair_budget_ms(1.0 / 24.0, 60.0, 1.0) - (1000.0 / 24.0)) < 0.05);
    int limit = 4;
    // At 24fps VFR span (41.67ms budget), 28ms (>60%) steps down 4 -> 2
    limit = iive_prefetch_limit_hysteresis(1920, 1080, limit, 1.0 / 24.0, 60.0, 1.0, 28.0);
    assert(limit == 2);
    // At 22ms (~52.8% of budget), hysteresis holds limit at 2 instead of oscillating back to 4
    limit = iive_prefetch_limit_hysteresis(1920, 1080, limit, 1.0 / 24.0, 60.0, 1.0, 22.0);
    assert(limit == 2);
    // At 16ms (<45% of budget), hysteresis relaxes 2 -> 4
    limit = iive_prefetch_limit_hysteresis(1920, 1080, limit, 1.0 / 24.0, 60.0, 1.0, 16.0);
    assert(limit == 4);
    // At 38ms (>85% of budget), steps down to 1, and holds at 1 when P95 drops to 30ms (~72%)
    limit = iive_prefetch_limit_hysteresis(1920, 1080, limit, 1.0 / 24.0, 60.0, 1.0, 38.0);
    assert(limit == 1);
    limit = iive_prefetch_limit_hysteresis(1920, 1080, limit, 1.0 / 24.0, 60.0, 1.0, 30.0);
    assert(limit == 1);
    limit = iive_prefetch_limit_hysteresis(1920, 1080, limit, 1.0 / 24.0, 60.0, 1.0, 22.0);
    assert(limit == 2);

    puts("PASS: VFR timestamp span + source-FPS/speed/resolution prefetch budgets with hysteresis");
    puts("PASS: empty/invalid/zero samples, nearest rank, ring eviction, reset");
    return 0;
}
