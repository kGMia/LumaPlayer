// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <math.h>
#include <stdbool.h>
typedef struct { double position, wall; bool running; } HDRClock;
static inline double hdr_clock_time(HDRClock clock,double now) {
    return clock.position+(clock.running?fmax(0,now-clock.wall):0);
}
static inline void hdr_clock_set(HDRClock *clock,double position,double now,bool running) {
    *clock=(HDRClock){position,now,running};
}
static inline void hdr_clock_run(HDRClock *clock,double now,bool running) {
    hdr_clock_set(clock,hdr_clock_time(*clock,now),now,running);
}
