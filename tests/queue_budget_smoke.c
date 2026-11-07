/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include "../native/mpv-filter/iive_queue_budget.h"

int main(void) {
    uint64_t hd=iive_queue_frame_estimate(1280,720);
    uint64_t fullhd=iive_queue_frame_estimate(1920,1080);
    uint64_t qhd=iive_queue_frame_estimate(2560,1440);
    uint64_t uhd=iive_queue_frame_estimate(3840,2160);
    uint64_t eightk=iive_queue_frame_estimate(7680,4320);
    assert(hd==1280ULL*720*4 && uhd==3840ULL*2160*4);
    // Reserve worst-case RIFE batch (8) + one downstream frame.
    assert(iive_queue_prefetch_limit(hd,9,4)==4);
    assert(iive_queue_prefetch_limit(fullhd,9,4)==4);
    assert(iive_queue_prefetch_limit(uhd,9,4)==0);
    // SR uses actual 2x output dimensions, not input dimensions.
    assert(iive_queue_prefetch_limit(qhd,2,4)==4);
    assert(iive_queue_prefetch_limit(uhd,2,4)==2);
    assert(iive_queue_prefetch_limit(eightk,2,4)==0);
    assert(iive_queue_prefetch_limit(uhd,2,1)==1); // latency/manual limit wins
    assert(iive_queue_prefetch_limit(iive_queue_frame_estimate(2160,3840),2,4)==2);
    assert(iive_queue_prefetch_limit(0,2,4)==0); // unknown dimensions: drain first
    assert(iive_queue_frame_estimate(-1,1080)==0);
    assert(iive_queue_prefetch_limit(iive_queue_frame_estimate(INT_MAX,INT_MAX),9,4)==0);
    assert(iive_queue_prefetch_limit(UINT64_MAX,9,4)==0);
    // At the exact budget boundary, no off-by-one extra prefetch frame.
    uint64_t unit=IIVE_QUEUE_SURFACE_TARGET/4;
    assert(iive_queue_prefetch_limit(unit,2,4)==2);
    assert(iive_queue_prefetch_limit(unit+1,2,4)==1);
    // A zero admission depth still permits the next job after draining the
    // ready queue. Worker batch capacity stays unchanged (including EOF tails).
    for(int queued=8;queued>=0;queued--)
        assert((queued<=iive_queue_prefetch_limit(eightk,2,4))==(queued==0));
    struct iive_queue_timeline timeline={0};
    double ahead, budget;
    // Unknown cadence/EOF never blocks an empty queue. Nonempty fallback is bounded.
    assert(iive_queue_time_admit(&timeline,NAN,0,1,-1,&ahead,&budget));
    assert(ahead==-1 && budget==-1);
    assert(iive_queue_time_admit(&timeline,NAN,1,1,-1,&ahead,&budget));
    assert(!iive_queue_time_admit(&timeline,NAN,2,1,-1,&ahead,&budget));
    iive_queue_note_output(&timeline,10,60);
    assert(iive_queue_time_admit(&timeline,10+2.0/60,2,1,-1,&ahead,&budget));
    assert(fabs(budget-1000.0/30)<1e-6);
    assert(!iive_queue_time_admit(&timeline,10+3.0/60,3,1,-1,&ahead,&budget));
    // A fast worker needs one interval of coverage plus its service time.
    assert(iive_queue_time_admit(&timeline,10+1.0/60,1,1,5,&ahead,&budget));
    assert(!iive_queue_time_admit(&timeline,10+2.0/60,2,1,5,&ahead,&budget));
    assert(fabs(budget-(1000.0/60+5))<1e-6);
    // Speed changes are applied in wall-time units; there is no stale speed cache.
    assert(iive_queue_time_admit(&timeline,10+2.0/60,2,2,10,&ahead,&budget));
    assert(fabs(ahead-1000.0/60)<1e-6);
    assert(!iive_queue_time_admit(&timeline,10+1.0/60,1,0,5,&ahead,&budget));
    // VFR cadence follows actual delivered timestamps, not nominal FPS alone.
    iive_queue_note_output(&timeline,10.04,60);
    assert(fabs(timeline.step-0.04)<1e-6);
    assert(iive_queue_time_admit(&timeline,10.08,1,1,-1,&ahead,&budget));
    assert(budget==50);
    assert(!iive_queue_time_admit(&timeline,10.12,2,1,-1,&ahead,&budget));
    // Discontinuity, unknown PTS and seek reset discard cadence from the old segment.
    iive_queue_note_output(&timeline,3,60);
    assert(timeline.step==0);
    iive_queue_note_output(&timeline,NAN,0);
    assert(!timeline.valid && timeline.step==0);
    timeline=(struct iive_queue_timeline){0};
    assert(iive_queue_time_admit(&timeline,NAN,0,1,-1,&ahead,&budget));
    // No deadlock even when a mandatory RIFE batch exceeds the media-time window.
    iive_queue_note_output(&timeline,0,48);
    for(int queued=7;queued>=0;queued--) {
        bool allow=iive_queue_time_admit(&timeline,queued/48.0,queued,1,5,&ahead,&budget);
        assert(allow==(queued<=1));
    }
    puts("PASS: 720p/1080p/4K/8K, output scaling, portrait, budget boundaries, invalid sizes, latency cap, drain-to-zero progress");
    puts("PASS: media-time lookahead, cold cadence, speed/VFR, discontinuities, seek reset, mandatory batch drain");
}
