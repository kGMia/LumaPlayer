// SPDX-License-Identifier: GPL-3.0-or-later
#import "../native/Player/Modern/MPVQueueNext.h"
#include <assert.h>
static mpv_handle *create(void) {
    mpv_handle *m=mpv_create();assert(m);
    for(NSArray *pair in @[@[@"config",@"no"],@[@"vo",@"null"],@[@"ao",@"null"],@[@"idle",@"yes"],@[@"pause",@"yes"]])
        assert(mpv_set_option_string(m,[pair[0] UTF8String],[pair[1] UTF8String])>=0);
    assert(mpv_initialize(m)>=0);return m;
}
static void command(mpv_handle *m,NSString *name,NSString *a,NSString *b) {
    const char *args[]={name.UTF8String,a.UTF8String,b.UTF8String,NULL};assert(mpv_command(m,args)>=0);
}
int main(void) {@autoreleasepool {
    mpv_handle *m=create();assert(mpv_hook_add(m,0,"on_load",50)>=0);
    command(m,@"loadfile",@"iive-media://current",@"replace");
    uint64_t hook=0;BOOL received=NO;
    for(int i=0;i<30 && !received;i++) {
        mpv_event *e=mpv_wait_event(m,.1);
        if(e->event_id==MPV_EVENT_HOOK){hook=((mpv_event_hook *)e->data)->id;received=YES;}
    }
    assert(received);
    NSNumber *current=iive_next_playlist(m)[0][@"id"];
    command(m,@"loadfile",@"iive-media://old",@"append");
    command(m,@"playlist-move",@"1",@"0"); // Existing selected item before current.
    command(m,@"loadfile",@"iive-media://tail",@"append");
    NSArray *keys=@[@"iive-media://b",@"iive-media://old",@"iive-media://b",@"iive-media://current"];
    for(int repeat=0;repeat<2;repeat++) {
        assert(iive_queue_next(m,keys)>=0);
        NSArray *list=iive_next_playlist(m);
        assert([[list valueForKey:@"filename"] isEqual:(@[@"iive-media://current",@"iive-media://b",@"iive-media://old",@"iive-media://tail"])]);
        assert([list[0][@"id"] isEqual:current] && [list[0][@"current"] boolValue]);
        int paused=0;assert(mpv_get_property(m,"pause",MPV_FORMAT_FLAG,&paused)>=0 && paused);
    }
    assert(mpv_hook_continue(m,hook)>=0);mpv_terminate_destroy(m);
    m=create();assert(iive_queue_next(m,@[@"iive-media://b",@"iive-media://a"])>=0);
    NSArray *list=iive_next_playlist(m);
    assert([[list valueForKey:@"filename"] isEqual:(@[@"iive-media://b",@"iive-media://a"])]);
    // mpv may designate a current playlist position while remaining idle.
    int idle=0;assert(mpv_get_property(m,"idle-active",MPV_FORMAT_FLAG,&idle)>=0 && idle);
    assert(iive_queue_next(m,@[@"iive-media://a",@"iive-media://b"])>=0);
    assert([[iive_next_playlist(m) valueForKey:@"filename"] isEqual:(@[@"iive-media://a",@"iive-media://b"])]);
    mpv_terminate_destroy(m);
    puts("PASS: next insertion order, existing-before-current move, duplicate/current exclusion, repeat clicks, idle queue; no network or GUI");
    return 0;
}}
