// SPDX-License-Identifier: GPL-3.0-or-later
// Real libmpv transport semantics without a window or audio device.
// Optional --rife exercises the small GPU interpolation path.
#include <mpv/client.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "check failed: line %d\n", __LINE__); exit(1); } } while (0)
static void wait_position(mpv_handle *m, double target) {
    for (int i = 0; i < 500; i++) {
        double position = -1;
        int paused = 0, seeking = 1;
        mpv_get_property(m, "time-pos", MPV_FORMAT_DOUBLE, &position);
        mpv_get_property(m, "pause", MPV_FORMAT_FLAG, &paused);
        mpv_get_property(m, "seeking", MPV_FORMAT_FLAG, &seeking);
        if (paused && !seeking && fabs(position - target) < .004) return;
        nanosleep(&(struct timespec){.tv_nsec = 10000000}, NULL);
    }
    fprintf(stderr, "did not reach paused frame at %.6f\n", target);
    exit(1);
}
static int skipped_frames(mpv_handle *m) {
    mpv_node meta;
    CHECK(mpv_get_property(m, "vf-metadata/iive-rife", MPV_FORMAT_NODE, &meta) >= 0);
    CHECK(meta.format == MPV_FORMAT_NODE_MAP);
    int skipped = 0;
    for (int i = 0; i < meta.u.list->num; i++) {
        if (!strcmp(meta.u.list->keys[i], "preroll_bypassed") && meta.u.list->values[i].format == MPV_FORMAT_STRING)
            skipped = atoi(meta.u.list->values[i].u.string);
    }
    mpv_free_node_contents(&meta);
    return skipped;
}
int main(int argc, char **argv) {
    CHECK(argc == 2 || argc == 3);
    const int rife = argc == 3;
    const double fps = rife ? 48 : 24;
    mpv_handle *m = mpv_create(); CHECK(m);
    CHECK(mpv_set_option_string(m, "vo", "null") >= 0);
    CHECK(mpv_set_option_string(m, "ao", "null") >= 0);
    CHECK(mpv_set_option_string(m, "hwdec", "no") >= 0);
    CHECK(mpv_set_option_string(m, "config", "no") >= 0);
    CHECK(mpv_set_option_string(m, "pause", "yes") >= 0);
    if (rife) CHECK(mpv_set_option_string(m, "vf", "@iive-rife:iive-rife=fps=48:tier=fast:fallback=no") >= 0);
    CHECK(mpv_initialize(m) >= 0);
    CHECK(mpv_command(m, (const char *[]){"loadfile", argv[1], NULL}) >= 0);
    int ready = 0;
    for (int i = 0; i < 100 && !ready; i++)
        ready = mpv_wait_event(m, .05)->event_id == MPV_EVENT_PLAYBACK_RESTART;
    CHECK(ready); wait_position(m, 0);
    // No intervening "set pause yes": it cancels unfinished forward steps.
    for (int i = 0; i < 4; i++)
        CHECK(mpv_command(m, (const char *[]){"frame-step", NULL}) >= 0);
    wait_position(m, 4.0 / fps);
    CHECK(mpv_command(m, (const char *[]){"frame-back-step", NULL}) >= 0);
    wait_position(m, 3.0 / fps);
    CHECK(mpv_command(m, (const char *[]){"frame-step", NULL}) >= 0);
    wait_position(m, 4.0 / fps);
    if (rife) {
        CHECK(mpv_command(m, (const char *[]){"seek", "1", "absolute+exact", NULL}) >= 0);
        wait_position(m, 1);
        int skipped_before = skipped_frames(m);
        CHECK(mpv_command(m, (const char *[]){"frame-back-step", NULL}) >= 0);
        wait_position(m, 1 - 1.0 / fps);
        CHECK(skipped_frames(m) > skipped_before);
    }
    mpv_terminate_destroy(m);
    puts("PASS: queued forward steps, exact backward step, direction change, final paused state. No GUI/AI timing claim.");
}
