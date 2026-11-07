#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../native/RIFEBackend/include/IIVERIFE.h"
static int32_t cancel_now(void *context) {(*(int *)context)++;return 1;}
int main(void) {
    int32_t error=-99;
    assert(!iive_stream_create_with_error(64,64,60,99,0,&error));
    assert(error==100);
    // Invalid dimensions fail before model / GPU initialization.
    assert(!iive_stream_create_with_error(0,64,60,0,0,&error));
    assert(error==200);
    assert(!iive_stream_create(0,64,60,0,0)); // original ABI retained
    int calls=0;
    assert(!iive_stream_create_cancellable(64,64,60,0,0,cancel_now,&calls,&error));
    assert(error==102 && calls==1); // before any GPU/model allocation
    assert(!iive_stream_create_cancellable(0,64,60,0,0,NULL,NULL,&error));
    assert(error==200); // nullable callback retains legacy validation
    assert(iive_stream_last_error(NULL)==100);
    assert(iive_stream_push(NULL,NULL,0)==-1);
    assert(iive_stream_finish(NULL,0)==-1);
    iive_stream_reset(NULL);iive_stream_destroy(NULL);
    assert(!strcmp(iive_stream_error_name(206),"inference"));
    assert(!strcmp(iive_stream_error_name(403),"output-surface-wrap"));
    assert(!strcmp(iive_stream_error_name(999),"unknown"));
    puts("PASS: extended and legacy ABI, fixed errors, null handles; no GPU/window");
}
