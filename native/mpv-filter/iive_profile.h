/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef IIVE_PROFILE_H
#define IIVE_PROFILE_H
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "iive_latency.h"

// Explicit opt-in: raw per-job logs are disabled in ordinary playback.
static inline bool iive_profile_enabled(void) {
    static atomic_int enabled;
    int value=atomic_load(&enabled);
    if(!value) {
        const char *env=getenv("IIVE_PROFILE");
        value=env && !strcmp(env,"1") ? 2 : 1;
        atomic_store(&enabled,value);
    }
    return value==2;
}
static inline double iive_profile_seconds(void) {
    struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);
    return t.tv_sec+t.tv_nsec/1e9;
}
static inline int iive_profile_prefetch(int configured) {
    const char *env=iive_profile_enabled()?getenv("IIVE_PROFILE_PREFETCH"):NULL;
    if(env && (!strcmp(env,"1") || !strcmp(env,"2") || !strcmp(env,"4")))return atoi(env);
    return configured;
}
struct iive_profile_stages {
    struct iive_latency_window dispatch, ready, backpressure;
    unsigned ready_peak;
};
// Decoder API wall time includes blocking in FFmpeg, not asynchronous hardware execution.
#define IIVE_PROFILE_DECODE(f, op, call) ({ \
    bool enabled=iive_profile_enabled(); \
    double start=enabled?iive_profile_seconds():0; \
    int result=(call); \
    if(enabled)MP_INFO(f,"IIVE_PROFILE {\"stage\":\"decode\",\"event\":\"" op "\",\"time_s\":%.9f,\"duration_ms\":%.6f,\"result\":%d}\n", \
        iive_profile_seconds(),(iive_profile_seconds()-start)*1000,result); \
    result; \
})
#endif
