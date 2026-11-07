// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef IIVE_MPV_EVENT_POLICY_H
#define IIVE_MPV_EVENT_POLICY_H
#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <string.h>

// Called on the client queue, after comparing property values. Continuous
// telemetry never requests a UI snapshot; startup metadata matters only until
// playback starts, avoiding per-frame HDR metadata updates becoming UI polls.
static inline bool iive_property_needs_snapshot(const char *name, id previous, id value,
                                                bool loaded, bool started) {
    if (!name || !loaded || [previous isEqual:value]) return false;
    if (!strcmp(name,"pause") || !strcmp(name,"seeking") ||
        !strcmp(name,"paused-for-cache") || !strcmp(name,"eof-reached")) return true;
    return !started && (!strcmp(name,"video-params") || !strcmp(name,"container-fps") ||
                        !strcmp(name,"track-list"));
}
#endif
