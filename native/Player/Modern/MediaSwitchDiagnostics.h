// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef IIVE_MEDIA_SWITCH_DIAGNOSTICS_H
#define IIVE_MEDIA_SWITCH_DIAGNOSTICS_H
#include <stdint.h>
#include <stdbool.h>
#include <math.h>

// Uptime timestamps observed on the mpv client queue. Zero means unavailable.
// These are phase boundaries, not pure network/decode/model execution costs.
struct iive_media_switch_timing {
    uint64_t epoch;
    double command, start, loaded, restart, plan, warm_start, warm_end, end;
    int navigation_count;
    bool plan_seen, plan_changed, failed;
};
static inline double iive_switch_elapsed(double from, double to) {
    return isfinite(from) && isfinite(to) && from > 0 && to >= from ? (to-from)*1000 : NAN;
}
static inline void iive_switch_first(double *slot, double time, double start) {
    if (*slot == 0 && isfinite(time) && time >= start && start > 0) *slot=time;
}
#endif
