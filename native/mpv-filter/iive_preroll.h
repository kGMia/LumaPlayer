/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef IIVE_PREROLL_H
#define IIVE_PREROLL_H
#include <math.h>
#include <stdbool.h>

// Both temporal adapters reset across larger gaps. Preserve this much source
// context plus mpv's 5 ms hr-seek tolerance before enabling AI at the boundary.
#define IIVE_MAX_PAIR_SPAN 0.1
static inline bool iive_preroll_before_context(double pts, double target)
{
    return isfinite(pts) && isfinite(target) &&
           pts < target - (IIVE_MAX_PAIR_SPAN + 0.005);
}
#endif
