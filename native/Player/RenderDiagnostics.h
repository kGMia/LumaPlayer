// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef IIVE_RENDER_DIAGNOSTICS_H
#define IIVE_RENDER_DIAGNOSTICS_H
#include <stdbool.h>
#include <stdint.h>
#include <math.h>
#include "../mpv-filter/iive_latency.h"

struct iive_submit_probe { uint64_t epoch; double armed, first; };
static inline void iive_submit_probe_finish(struct iive_submit_probe *probe, uint64_t epoch,
                                           double began, double submitted, bool fresh) {
    if (fresh && epoch && epoch==probe->epoch && !probe->first &&
        isfinite(began) && isfinite(submitted) && began>=probe->armed && submitted>=began)
        probe->first=submitted;
}

enum iive_render_phase {
    IIVE_CURRENT, IIVE_CONTEXT_WAIT, IIVE_UPDATE, IIVE_DRAW,
    IIVE_LUMA_COLLECT, IIVE_LUMA_ENQUEUE, IIVE_SWAP, IIVE_REPORT_SWAP,
    IIVE_RENDER_PHASES
};
#define IIVE_SLOW_FRAMES 16
struct iive_render_event {
    double time_s, gap_ms, ms[IIVE_RENDER_PHASES];
    uint64_t serial;
    bool redraw, mpv_frame;
};
struct iive_render_diagnostics {
    struct iive_latency_window phases[IIVE_RENDER_PHASES];
    double maxima[IIVE_RENDER_PHASES];
    struct iive_render_event slow[IIVE_SLOW_FRAMES];
    unsigned next, count;
    uint64_t slow_count;
};
static inline void iive_render_record(struct iive_render_diagnostics *d,
                                      struct iive_render_event event) {
    bool slow = isfinite(event.gap_ms) && event.gap_ms >= 50;
    for (int i=0;i<IIVE_RENDER_PHASES;i++) {
        double ms=event.ms[i];
        if (!isfinite(ms) || ms<0) continue;
        iive_latency_add(&d->phases[i],ms);
        d->maxima[i]=fmax(d->maxima[i],ms);
        if (ms>=20) slow=true;
    }
    if (!slow) return;
    d->slow[d->next]=event;
    d->next=(d->next+1)%IIVE_SLOW_FRAMES;
    if(d->count<IIVE_SLOW_FRAMES)d->count++;
    d->slow_count++;
}
#endif
