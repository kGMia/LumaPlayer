#include <assert.h>
#include "../native/Player/RenderDiagnostics.h"

int main(void) {
    struct iive_submit_probe probe={.epoch=2,.armed=20};
    iive_submit_probe_finish(&probe,1,19,21,true); // old in-flight file completes late
    assert(probe.first==0);
    iive_submit_probe_finish(&probe,2,19,21,true); // raced arming
    assert(probe.first==0);
    iive_submit_probe_finish(&probe,2,21,22,false); // redraw/repeat is not fresh
    assert(probe.first==0);
    iive_submit_probe_finish(&probe,2,21,22,true);
    iive_submit_probe_finish(&probe,2,23,24,true);
    assert(probe.first==22); // once per observation, later seeks cannot overwrite
    struct iive_render_diagnostics d={0};
    struct iive_render_event e={.time_s=1,.serial=1};
    e.ms[IIVE_DRAW]=4;e.ms[IIVE_UPDATE]=NAN;
    iive_render_record(&d,e);
    assert(d.count==0 && d.phases[IIVE_DRAW].count==1);
    assert(d.phases[IIVE_UPDATE].count==0);
    // Retain the newest 16 slow frames without resetting cumulative maxima.
    for(int i=0;i<20;i++) {
        e.serial=i+2;e.time_s=i+2;e.ms[IIVE_DRAW]=100-i;
        iive_render_record(&d,e);
    }
    assert(d.count==16 && d.slow_count==20 && d.maxima[IIVE_DRAW]==100);
    for(unsigned i=0;i<d.count;i++)
        assert(d.slow[(d.next+IIVE_SLOW_FRAMES-d.count+i)%IIVE_SLOW_FRAMES].serial==i+6);
    // A long submission gap is evidence even when all individual calls are fast.
    e.serial=22;e.ms[IIVE_DRAW]=2;e.gap_ms=60;
    iive_render_record(&d,e);
    assert(d.slow_count==21 && d.slow[(d.next+15)%16].gap_ms==60);
    return 0;
}
