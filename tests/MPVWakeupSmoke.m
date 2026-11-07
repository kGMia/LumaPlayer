// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#include <mpv/client.h>
#include "../native/Player/Modern/MPVWakeup.h"
#include "../native/Player/Modern/MPVEventPolicy.h"
#include <assert.h>

int main(int argc,const char **argv) {
    @autoreleasepool {
        if(argc!=2)return 2;
        assert(iive_property_needs_snapshot("video-params",NSNull.null,@{@"w":@1920},true,false));
        assert(!iive_property_needs_snapshot("video-params",@{@"w":@1280},@{@"w":@1920},true,true));
        assert(!iive_property_needs_snapshot("track-list",@[],@[@1],false,false));
        assert(iive_property_needs_snapshot("seeking",@YES,@NO,true,true));
        assert(iive_property_needs_snapshot("paused-for-cache",@YES,@NO,true,true));
        assert(!iive_property_needs_snapshot("seeking",@NO,@NO,true,true));
        assert(!iive_property_needs_snapshot("time-pos",@1,@2,true,true));
        assert(!iive_property_needs_snapshot("demuxer-cache-duration",@1,@2,true,true));
        mpv_handle *mpv=mpv_create();if(!mpv)return 3;
        mpv_set_option_string(mpv,"config","no");mpv_set_option_string(mpv,"vo","null");
        mpv_set_option_string(mpv,"ao","null");mpv_set_option_string(mpv,"hwdec","no");
        mpv_set_option_string(mpv,"idle","yes");mpv_set_option_string(mpv,"pause","yes");
        if(mpv_initialize(mpv)<0){mpv_terminate_destroy(mpv);return 4;}
        mpv_hook_add(mpv,1,"on_load",50);
        mpv_observe_property(mpv,2,"pause",MPV_FORMAT_FLAG);
        dispatch_queue_t queue=dispatch_queue_create("iive.wakeup.smoke",DISPATCH_QUEUE_SERIAL);
        dispatch_source_t source=dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD,0,0,queue);
        dispatch_semaphore_t loaded=dispatch_semaphore_create(0);
        dispatch_semaphore_t transport=dispatch_semaphore_create(0);
        __block int hooks=0,files=0;
        __block int expectedPause=-1,transitions=0;
        __block NSNumber *lastPause=@YES;
        __block BOOL closed=NO;
        dispatch_source_set_event_handler(source,^{
            if(closed)return;
            for(;;) {
                mpv_event *event=mpv_wait_event(mpv,0);
                if(event->event_id==MPV_EVENT_NONE)break;
                if(event->event_id==MPV_EVENT_HOOK) {
                    mpv_event_hook *hook=event->data;hooks++;mpv_hook_continue(mpv,hook->id);
                } else if(event->event_id==MPV_EVENT_FILE_LOADED) {files++;dispatch_semaphore_signal(loaded);}
                else if(event->event_id==MPV_EVENT_PROPERTY_CHANGE) {
                    mpv_event_property *p=event->data;
                    if(p && p->format==MPV_FORMAT_FLAG && p->data && !strcmp(p->name,"pause")) {
                        NSNumber *value=@(*(int *)p->data!=0);
                        BOOL notify=iive_property_needs_snapshot(p->name,lastPause,value,files>0,true);
                        lastPause=value;
                        if(notify && expectedPause==value.intValue) {
                            transitions++;expectedPause=-1;dispatch_semaphore_signal(transport);
                        }
                    }
                }
            }
        });
        dispatch_resume(source);
        mpv_set_wakeup_callback(mpv,iive_mpv_wakeup,(__bridge void *)source);
        __block int status=0;
        for(int i=0;i<2;i++) {
            const char *command[]={"loadfile",argv[1],"replace",NULL};
            if(mpv_command(mpv,command)<0 || dispatch_semaphore_wait(loaded,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))) {status=5;break;}
        }
        for(int paused=0;paused<=1 && !status;paused++) {
            dispatch_sync(queue,^{expectedPause=paused;});
            const char *command[]={"set","pause",paused?"yes":"no",NULL};
            if(mpv_command(mpv,command)<0 || dispatch_semaphore_wait(transport,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)))status=7;
        }
        // Same ownership rule as the player: unregister before releasing userdata,
        // then drain serialized work before destroying the client.
        mpv_set_wakeup_callback(mpv,NULL,NULL);
        dispatch_source_cancel(source);
        dispatch_sync(queue,^{closed=YES;if(hooks!=2 || files!=2 || transitions!=2)status=6;});
        mpv_terminate_destroy(mpv);
        if(!status)puts("PASS: two headless loads and pause/resume transitions without polling timer; startup/transport selection excludes continuous/unchanged telemetry; safe unregister/drain");
        return status;
    }
}
