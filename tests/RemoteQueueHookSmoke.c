// SPDX-License-Identifier: GPL-3.0-or-later
// Verify the libmpv contract used by MPVSession without a render view.
#include <mpv/client.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"check failed at line %d\n",__LINE__); exit(1); } } while(0)
int main(int argc, char **argv) {
    CHECK(argc==2);
    mpv_handle *m=mpv_create(); CHECK(m);
    CHECK(mpv_set_option_string(m,"vo","null")>=0);
    CHECK(mpv_set_option_string(m,"ao","null")>=0);
    CHECK(mpv_set_option_string(m,"idle","yes")>=0);
    CHECK(mpv_set_option_string(m,"config","no")>=0);
    CHECK(mpv_initialize(m)>=0); CHECK(mpv_hook_add(m,0,"on_load",50)>=0);
    const char *load[]={"loadfile","iive-media://second","replace",NULL};
    const char *first[]={"loadfile","iive-media://first","append",NULL};
    const char *third[]={"loadfile","iive-media://third","append",NULL};
    const char *move[]={"playlist-move","0","2",NULL};
    CHECK(mpv_command(m,load)>=0);CHECK(mpv_command(m,first)>=0);
    CHECK(mpv_command(m,third)>=0);CHECK(mpv_command(m,move)>=0);
    char *name=mpv_get_property_string(m,"playlist/1/filename");
    CHECK(name && !strcmp(name,"iive-media://second"));mpv_free(name);
    int hooks=0,loaded=0,ended=0;
    time_t deadline=time(NULL)+20;
    while(ended<2 && time(NULL)<deadline) {
        mpv_event *event=mpv_wait_event(m,.2);
        if(event->event_id==MPV_EVENT_HOOK) {
            mpv_event_hook *h=event->data;
            char *path=mpv_get_property_string(m,"path");
            CHECK(path && !strcmp(path,hooks==0?"iive-media://second":"iive-media://third"));mpv_free(path);
            CHECK(mpv_set_property_string(m,"file-local-options/http-header-fields","Authorization: Basic dGVzdDp0ZXN0LW9ubHk=")>=0);
            CHECK(mpv_set_property_string(m,"file-local-options/stream-lavf-o","max_redirects=0")>=0);
            CHECK(mpv_set_property_string(m,"file-local-options/demuxer","lavf")>=0);
            CHECK(mpv_set_property_string(m,"file-local-options/access-references","no")>=0);
            CHECK(mpv_set_property_string(m,"file-local-options/demuxer-lavf-format","mov")>=0);
            CHECK(mpv_set_property_string(m,"file-local-options/force-media-title","Original name.mp4")>=0);
            CHECK(mpv_set_property_string(m,"file-local-options/cache-secs","30")>=0);
            CHECK(mpv_set_property_string(m,"file-local-options/demuxer-readahead-secs","30")>=0);
            CHECK(mpv_set_property_string(m,"file-local-options/demuxer-max-bytes","64MiB")>=0);
            CHECK(mpv_set_property_string(m,"file-local-options/demuxer-max-back-bytes","16MiB")>=0);
            CHECK(mpv_set_property_string(m,"file-local-options/cache-pause-wait","1")>=0);
            CHECK(mpv_set_property_string(m,"stream-open-filename",argv[1])>=0);
            CHECK(mpv_hook_continue(m,h->id)>=0);hooks++;
        } else if(event->event_id==MPV_EVENT_FILE_LOADED) {
            char *title=mpv_get_property_string(m,"media-title");
            CHECK(title && !strcmp(title,"Original name.mp4"));mpv_free(title);loaded++;
        } else if(event->event_id==MPV_EVENT_END_FILE) {
            CHECK(((mpv_event_end_file *)event->data)->reason==MPV_END_FILE_REASON_EOF);ended++;
        }
    }
    CHECK(hooks==2 && loaded==2 && ended==2);
    mpv_terminate_destroy(m);
    puts("PASS: original queue identity, selected-item ordering, original title, lazy URL hooks and automatic next playback");
}
