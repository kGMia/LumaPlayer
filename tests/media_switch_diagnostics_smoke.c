// SPDX-License-Identifier: GPL-3.0-or-later
#include <assert.h>
#include <stdio.h>
#include "../native/Player/Modern/MediaSwitchDiagnostics.h"
int main(void) {
    struct iive_media_switch_timing t={.epoch=1,.start=10};
    assert(isnan(iive_switch_elapsed(0,11)));
    assert(isnan(iive_switch_elapsed(11,10)));
    assert(isnan(iive_switch_elapsed(10,NAN)));
    iive_switch_first(&t.loaded,9,t.start);
    assert(t.loaded==0);
    iive_switch_first(&t.loaded,10.25,t.start);
    iive_switch_first(&t.loaded,12,t.start);
    assert(iive_switch_elapsed(t.start,t.loaded)==250);
    iive_switch_first(&t.restart,10.5,t.start);
    iive_switch_first(&t.restart,30,t.start); // later seek must not rewrite startup
    assert(iive_switch_elapsed(t.loaded,t.restart)==250);
    assert(isnan(iive_switch_elapsed(t.warm_start,t.warm_end))); // no enhancement pause
    t=(struct iive_media_switch_timing){.epoch=2,.start=40};
    assert(t.loaded==0 && t.restart==0 && !t.plan_seen);
    puts("PASS: unavailable/reversed timestamps, first-only boundaries, seek isolation, new-epoch reset");
}
