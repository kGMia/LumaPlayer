#include "../native/HDRPrototype/HDRClock.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    HDRClock clock;
    hdr_clock_set(&clock,5,100,true);
    assert(hdr_clock_time(clock,102)==7);
    hdr_clock_run(&clock,102,false);
    assert(hdr_clock_time(clock,200)==7);
    hdr_clock_run(&clock,200,true);
    assert(hdr_clock_time(clock,201)==8);
    hdr_clock_set(&clock,30,201,false);
    assert(hdr_clock_time(clock,900)==30);
    hdr_clock_run(&clock,900,true);
    assert(hdr_clock_time(clock,901)==31);
    assert(hdr_clock_time(clock,899)==30);
    puts("PASS: PTS anchor, pause/resume, paused seek and nonnegative elapsed clock");
}
