#include <assert.h>
#include <math.h>
#include <stdio.h>
#include "../native/mpv-filter/iive_preroll.h"

int main(void)
{
    assert(iive_preroll_before_context(0, 1.3));
    assert(iive_preroll_before_context(1.19, 1.3));
    assert(!iive_preroll_before_context(1.2, 1.3));
    assert(!iive_preroll_before_context(1.3, 1.3));
    assert(!iive_preroll_before_context(2, 1.3));
    assert(!iive_preroll_before_context(NAN, 1.3));
    assert(!iive_preroll_before_context(0, INFINITY));
    assert(!iive_preroll_before_context(0, NAN));
    assert(iive_preroll_before_context(-1, 0));
    // All frames that may bracket mpv's target-minus-5ms boundary must survive.
    for (int fps = 10; fps <= 120; fps++) {
        double boundary = 37.0 - .005;
        assert(!iive_preroll_before_context(boundary - 1.0 / fps + 1e-10, 37));
        assert(!iive_preroll_before_context(boundary, 37));
    }
    puts("PASS: preroll context, boundary, finite timestamps and 10–120 fps");
}
