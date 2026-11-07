// SPDX-License-Identifier: GPL-3.0-or-later
// Check the append contract with a held lazy-load hook: no media/GPU/network.
#include <mpv/client.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "check failed at line %d\n", __LINE__); exit(1); } } while (0)
static void property(mpv_handle *m, const char *key, const char *expected) {
    char *value = mpv_get_property_string(m, key);
    CHECK(value && !strcmp(value, expected)); mpv_free(value);
}
int main(void) {
    mpv_handle *m = mpv_create(); CHECK(m);
    CHECK(mpv_set_option_string(m, "vo", "null") >= 0);
    CHECK(mpv_set_option_string(m, "ao", "null") >= 0);
    CHECK(mpv_set_option_string(m, "idle", "yes") >= 0);
    CHECK(mpv_set_option_string(m, "pause", "yes") >= 0);
    CHECK(mpv_set_option_string(m, "config", "no") >= 0);
    CHECK(mpv_initialize(m) >= 0); CHECK(mpv_hook_add(m, 0, "on_load", 50) >= 0);
    const char *first[] = {"loadfile", "iive-media://current", "replace", NULL};
    CHECK(mpv_command(m, first) >= 0);
    uint64_t hook = 0; int received = 0;
    for (int i = 0; i < 30 && !received; i++) {
        mpv_event *e = mpv_wait_event(m, .1);
        if (e->event_id == MPV_EVENT_HOOK) { hook = ((mpv_event_hook *)e->data)->id; received = 1; }
    }
    CHECK(received);
    const char *a[] = {"loadfile", "iive-media://batch-b", "append+play", NULL};
    const char *b[] = {"loadfile", "iive-media://batch-a", "append", NULL};
    CHECK(mpv_command(m, a) >= 0); CHECK(mpv_command(m, b) >= 0);
    property(m, "playlist-count", "3");
    property(m, "playlist/0/filename", "iive-media://current");
    property(m, "playlist/1/filename", "iive-media://batch-b");
    property(m, "playlist/2/filename", "iive-media://batch-a");
    property(m, "path", "iive-media://current"); property(m, "pause", "yes");
    CHECK(mpv_hook_continue(m, hook) >= 0);
    mpv_terminate_destroy(m);
    puts("PASS: batch tail ordering, current item/pause preserved; no media opened or GUI used.");
}
