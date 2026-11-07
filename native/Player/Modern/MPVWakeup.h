// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef IIVE_MPV_WAKEUP_H
#define IIVE_MPV_WAKEUP_H
#include <dispatch/dispatch.h>
// Foreign-thread notification only. No client API, Foundation work, or waiting.
// Owner retains source until callback unregister completes, then cancels it.
static inline void iive_mpv_wakeup(void *context) {
    dispatch_source_merge_data((__bridge dispatch_source_t)context, 1);
}
#endif
