// SPDX-License-Identifier: GPL-3.0-or-later
// Real libmpv hook contract: retry the same entry before auto-advance, restore
// file-local positioning/options, and leave the following queue item intact.
#include <mpv/client.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#define CHECK(x) do { if(!(x)){fprintf(stderr,"line %d failed\n",__LINE__);exit(1);} }while(0)
int main(int argc,char **argv) {
    CHECK(argc==2 || argc==3);
    int terminal=argc==3 && !strcmp(argv[2],"--terminal");
    mpv_handle *m=mpv_create(); CHECK(m);
    CHECK(mpv_set_option_string(m,"vo","null")>=0);
    CHECK(mpv_set_option_string(m,"ao","null")>=0);
    CHECK(mpv_set_option_string(m,"idle","yes")>=0);
    CHECK(mpv_set_option_string(m,"config","no")>=0);
    CHECK(mpv_initialize(m)>=0);
    CHECK(mpv_hook_add(m,0,"on_load",50)>=0);
    CHECK(mpv_hook_add(m,0,"on_after_end_file",50)>=0);
    const char *load[]={"loadfile","iive-media://retry","replace",NULL};
    const char *append[]={"loadfile","iive-media://next","append",NULL};
    CHECK(mpv_command(m,load)>=0); CHECK(mpv_command(m,append)>=0);
    int loads=0, failures=0, restored=0;
    int stopped=0, idleTicks=0, manual=0;
    time_t deadline=time(NULL)+10;
    while(restored<(terminal?1:2) && time(NULL)<deadline) {
        mpv_event *e=mpv_wait_event(m,.1);
        if(e->event_id==MPV_EVENT_HOOK){
            mpv_event_hook *h=e->data;
            if(!strcmp(h->name,"on_load")) {
                char *key=mpv_get_property_string(m,"path");
                CHECK(key && !strcmp(key,"iive-media://retry"));mpv_free(key);
                loads++;
                CHECK(mpv_set_property_string(m,"stream-open-filename",loads<=(terminal?2:1)?"/nonexistent/iive-recovery-fixture.wav":argv[1])>=0);
                if(loads>=2){
                    CHECK(mpv_set_property_string(m,"file-local-options/start","0.5")>=0);
                    CHECK(mpv_set_property_string(m,"file-local-options/pause","yes")>=0);
                    CHECK(mpv_set_property_string(m,"file-local-options/speed","1.25")>=0);
                    CHECK(mpv_set_property_string(m,"file-local-options/aid","auto")>=0);
                    CHECK(mpv_set_property_string(m,"file-local-options/sid","no")>=0);
                    CHECK(mpv_set_property_string(m,"file-local-options/secondary-sid","no")>=0);
                }
            }else{
                if(terminal && failures==2) {
                    const char *stop[]={"stop","keep-playlist",NULL};
                    CHECK(mpv_command(m,stop)>=0);stopped=1;
                } else {
                    CHECK(failures==1);
                    const char *retry[]={"playlist-play-index","0",NULL};
                    CHECK(mpv_command(m,retry)>=0);
                }
            }
            CHECK(mpv_hook_continue(m,h->id)>=0);
        }else if(e->event_id==MPV_EVENT_END_FILE){
            mpv_event_end_file *end=e->data;
            if(!restored) { CHECK(end->reason==MPV_END_FILE_REASON_ERROR); failures++; }
            else CHECK(end->reason==MPV_END_FILE_REASON_STOP);
        }else if(e->event_id==MPV_EVENT_PLAYBACK_RESTART){
            double pos=0,speed=0;int pause=0;
            CHECK(mpv_get_property(m,"time-pos",MPV_FORMAT_DOUBLE,&pos)>=0 && fabs(pos-.5)<.1);
            CHECK(mpv_get_property(m,"speed",MPV_FORMAT_DOUBLE,&speed)>=0 && speed==1.25);
            CHECK(mpv_get_property(m,"pause",MPV_FORMAT_FLAG,&pause)>=0 && pause);
            char *next=mpv_get_property_string(m,"playlist/1/filename");
            CHECK(next && !strcmp(next,"iive-media://next"));mpv_free(next);restored++;
            if(restored==1 && !terminal) {
                const char *stop[]={"stop","keep-playlist",NULL};
                CHECK(mpv_command(m,stop)>=0);
            }
        }
        // Give auto-advance a chance to run before the simulated manual action.
        if(terminal && stopped && !manual && e->event_id==MPV_EVENT_NONE && ++idleTicks>=3) {
            int idle=0;
            CHECK(mpv_get_property(m,"idle-active",MPV_FORMAT_FLAG,&idle)>=0 && idle);
            CHECK(loads==2);
            const char *retry[]={"playlist-play-index","0",NULL};
            CHECK(mpv_command(m,retry)>=0);manual=1;
        }
    }
    CHECK(loads==3 && failures==(terminal?2:1) && restored==(terminal?1:2));
    mpv_terminate_destroy(m);
    puts(terminal?"PASS: terminal failure stays idle; manual retry restores identity, queue, start, pause and speed":
         "PASS: end hook retry precedes auto-next; identity, queue, start, pause and speed restored");
}
