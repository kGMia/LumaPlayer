// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise the pinned libmpv load-hook/property contract without GUI/GPU/audio.
#include <mpv/client.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#define CHECK(x) do {if(!(x)){fprintf(stderr,"check failed at line %d\n",__LINE__);exit(1);}}while(0)
static void string_is(mpv_handle *m,const char *key,const char *expected) {
    char *v=mpv_get_property_string(m,key);CHECK(v && !strcmp(v,expected));mpv_free(v);
}
int main(int argc,char **argv) {
    CHECK(argc==2);mpv_handle *m=mpv_create();CHECK(m);
    CHECK(mpv_set_option_string(m,"vo","null")>=0);
    CHECK(mpv_set_option_string(m,"ao","null")>=0);
    CHECK(mpv_set_option_string(m,"config","no")>=0);
    CHECK(mpv_set_option_string(m,"pause","yes")>=0);
    CHECK(mpv_set_option_string(m,"idle","yes")>=0);
    CHECK(mpv_initialize(m)>=0);CHECK(mpv_hook_add(m,0,"on_load",50)>=0);
    const char *load[]={"loadfile",argv[1],"replace",NULL};
    CHECK(mpv_command(m,load)>=0);
    int loaded=0,hooks=0;time_t deadline=time(NULL)+8;
    while(loaded<2 && time(NULL)<deadline) {
        mpv_event *event=mpv_wait_event(m,.1);
        if(event->event_id==MPV_EVENT_HOOK) {
            mpv_event_hook *hook=event->data;
            CHECK(mpv_set_property_string(m,"file-local-options/ab-loop-a","no")>=0);
            CHECK(mpv_set_property_string(m,"file-local-options/ab-loop-b","no")>=0);
            CHECK(mpv_set_property_string(m,"file-local-options/video-aspect-override","no")>=0);
            CHECK(mpv_set_property_string(m,"file-local-options/video-crop","")>=0);
            CHECK(mpv_hook_continue(m,hook->id)>=0);hooks++;
        } else if(event->event_id==MPV_EVENT_FILE_LOADED) {
            loaded++;
            string_is(m,"ab-loop-a","no");string_is(m,"ab-loop-b","no");string_is(m,"video-crop","");
            if(loaded==1) {
                CHECK(mpv_set_property_string(m,"ab-loop-a","0.25")>=0);
                CHECK(mpv_set_property_string(m,"ab-loop-b","0.75")>=0);
                CHECK(mpv_set_property_string(m,"video-aspect-override","235:100")>=0);
                CHECK(mpv_set_property_string(m,"video-crop","1440x1080+240+0")>=0);
                CHECK(mpv_set_property_string(m,"deinterlace","auto")>=0);
                double point=0;CHECK(mpv_get_property(m,"ab-loop-a",MPV_FORMAT_DOUBLE,&point)>=0 && point==.25);
                CHECK(mpv_command(m,load)>=0);
            }
        }
    }
    CHECK(loaded==2 && hooks==2);mpv_terminate_destroy(m);
    puts("PASS: libmpv loop/geometry/deinterlace properties and same-path on_load reset; no renderer or audio device opened.");
}
