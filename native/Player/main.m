// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import "VideoView.h"
#include <mpv/client.h>
#include <fcntl.h>
#include <math.h>
@interface Player : NSObject <NSApplicationDelegate,NSWindowDelegate> {
    mpv_handle *_mpv;
    NSWindow *_window;
    VideoView *_video;
    NSTextField *_status;
    NSSlider *_seek;
    NSPopUpButton *_fps,*_tier,*_speed;
    NSButton *_rife,*_pause;
    NSTimer *_timer;
    NSFileHandle *_log;
    BOOL _closing;
    double _lastStamp;
    uint64_t _lastRenders;
}
@property NSArray<NSString *> *args;
@end
@implementation Player
- (NSString *)option:(NSString *)name fallback:(NSString *)fallback {
    NSUInteger i=[self.args indexOfObject:name];return i!=NSNotFound&&i+1<self.args.count?self.args[i+1]:fallback;
}
- (void)command:(NSArray<NSString *> *)args {
    const char **c=calloc(args.count+1,sizeof(char *));for(NSUInteger i=0;i<args.count;i++)c[i]=args[i].UTF8String;
    int error=mpv_command_async(_mpv,0,c);free(c);if(error<0)_status.stringValue=@(mpv_error_string(error));
}
- (NSButton *)button:(NSString *)name action:(SEL)action {
    return [NSButton buttonWithTitle:name target:self action:action];
}
- (NSPopUpButton *)popup:(NSArray *)items action:(SEL)action {
    NSPopUpButton *p=[[NSPopUpButton alloc]initWithFrame:NSZeroRect pullsDown:NO];[p addItemsWithTitles:items];p.target=self;p.action=action;return p;
}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    _mpv=mpv_create();if(!_mpv){[NSApp terminate:nil];return;}
    mpv_set_option_string(_mpv,"config","no");mpv_set_option_string(_mpv,"vo","libmpv");
    mpv_set_option_string(_mpv,"hwdec","no");mpv_set_option_string(_mpv,"idle","yes");
    mpv_set_option_string(_mpv,"keep-open","yes");mpv_set_option_string(_mpv,"terminal","yes");
    mpv_set_option_string(_mpv,"volume","50");mpv_set_option_string(_mpv,"msg-level","iive-rife=v");
    NSString *ipc=[self option:@"--ipc" fallback:nil];if(ipc)mpv_set_option_string(_mpv,"input-ipc-server",ipc.UTF8String);
    if([self.args containsObject:@"--mute"])mpv_set_option_string(_mpv,"mute","yes");
    NSString *fps=[self option:@"--fps" fallback:@"48"],*tier=[self option:@"--tier" fallback:@"fast"];
    if(![@[@"48",@"60"] containsObject:fps]||![@[@"fast",@"balanced",@"hq"] containsObject:tier]){fprintf(stderr,"Invalid fps/tier\n");[NSApp terminate:nil];return;}
    NSString *filter=[NSString stringWithFormat:@"@iive-rife:iive-rife=fps=%@:tier=%@:fallback=yes",fps,tier];
    mpv_set_option_string(_mpv,"vf",filter.UTF8String);
    if(mpv_initialize(_mpv)<0){[NSApp terminate:nil];return;}
    NSString *log=[self option:@"--metrics" fallback:nil];
    if(log){
        // Never overwrite a prior result or media file.
        int fd=open(log.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL,0600);
        if(fd<0){perror("metrics output");[NSApp terminate:nil];return;}_log=[[NSFileHandle alloc]initWithFileDescriptor:fd closeOnDealloc:YES];
    }
    _window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,1100,760) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    _window.title=@"IIVE Experimental Player · native RIFE · SDR";_window.delegate=self;_window.releasedWhenClosed=NO;
    NSView *root=_window.contentView;
    _video=[[VideoView alloc]initWithFrame:NSMakeRect(0,125,1100,635)];_video.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;[root addSubview:_video];
    _pause=[self button:@"Play / Pause" action:@selector(togglePause:)];
    _rife=[NSButton checkboxWithTitle:@"RIFE" target:self action:@selector(changeFilter:)];_rife.state=NSControlStateValueOn;
    _fps=[self popup:@[@"48 fps",@"60 fps"] action:@selector(changeFilter:)];[_fps selectItemAtIndex:[fps isEqual:@"60"]?1:0];
    _tier=[self popup:@[@"fast",@"balanced",@"hq"] action:@selector(changeFilter:)];[_tier selectItemWithTitle:tier];
    _speed=[self popup:@[@"0.5×",@"1×",@"1.5×",@"2×"] action:@selector(changeSpeed:)];[_speed selectItemAtIndex:1];
    NSStackView *controls=[NSStackView stackViewWithViews:@[[self button:@"Open…" action:@selector(open:)],_pause,[self button:@"−5s" action:@selector(back:)],[self button:@"+5s" action:@selector(forward:)],_rife,_fps,_tier,_speed,[self button:@"Retry RIFE" action:@selector(changeFilter:)]]];
    controls.orientation=NSUserInterfaceLayoutOrientationHorizontal;controls.spacing=8;controls.frame=NSMakeRect(12,85,1076,28);controls.autoresizingMask=NSViewWidthSizable;[root addSubview:controls];
    _seek=[NSSlider sliderWithValue:0 minValue:0 maxValue:1 target:self action:@selector(seek:)];_seek.continuous=NO;_seek.frame=NSMakeRect(12,56,1076,24);_seek.autoresizingMask=NSViewWidthSizable;[root addSubview:_seek];
    _status=[NSTextField wrappingLabelWithString:@"Warming up · source playback may wait during initial graph compilation"];
    _status.frame=NSMakeRect(12,5,1076,46);_status.autoresizingMask=NSViewWidthSizable;_status.font=[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];[root addSubview:_status];
    [_window center];[_window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
    if(![_video startRenderer:_mpv]){_status.stringValue=@"OpenGL renderer initialization failed";return;}
    _timer=[NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    NSString *input=[self option:@"--input" fallback:nil];if(input)[self command:@[@"loadfile",input]];
}
- (void)togglePause:(id)sender{[self command:@[@"cycle",@"pause"]];}
- (void)back:(id)sender{[self command:@[@"seek",@"-5",@"relative+exact"]];}
- (void)forward:(id)sender{[self command:@[@"seek",@"5",@"relative+exact"]];}
- (void)seek:(id)sender{[self command:@[@"seek",[NSString stringWithFormat:@"%.6f",_seek.doubleValue],@"absolute+exact"]];}
- (void)changeSpeed:(id)sender {
    NSString *speed=@[@"0.5",@"1",@"1.5",@"2"][_speed.indexOfSelectedItem];[self command:@[@"set",@"speed",speed]];
}
- (void)changeFilter:(id)sender {
    if(_rife.state==NSControlStateValueOff){[self command:@[@"vf",@"remove",@"@iive-rife"]];return;}
    NSString *f=[NSString stringWithFormat:@"@iive-rife:iive-rife=fps=%@:tier=%@:fallback=yes",_fps.indexOfSelectedItem?@"60":@"48",_tier.titleOfSelectedItem];
    [self command:@[@"vf",@"add",f]];
}
- (void)open:(id)sender {
    NSOpenPanel *panel=[NSOpenPanel openPanel];panel.canChooseDirectories=NO;panel.allowsMultipleSelection=NO;
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse response){if(response==NSModalResponseOK)[self command:@[@"loadfile",panel.URL.path]];}];
}
- (id)number:(const char *)name {
    double value;return mpv_get_property(_mpv,name,MPV_FORMAT_DOUBLE,&value)>=0&&isfinite(value)?@(value):NSNull.null;
}
- (NSDictionary *)metadata {
    mpv_node node={0};NSMutableDictionary *d=[NSMutableDictionary dictionary];
    if(mpv_get_property(_mpv,"vf-metadata/iive-rife",MPV_FORMAT_NODE,&node)>=0){
        if(node.format==MPV_FORMAT_NODE_MAP)for(int n=0;n<node.u.list->num;n++){
            mpv_node *v=&node.u.list->values[n];if(v->format==MPV_FORMAT_STRING)d[@(node.u.list->keys[n])]=@(v->u.string);
        }
        mpv_free_node_contents(&node);
    }
    return d;
}
- (void)tick:(id)sender {
    if(_closing)return;
    for(;;){mpv_event *event=mpv_wait_event(_mpv,0);if(event->event_id==MPV_EVENT_NONE)break;
        if(event->event_id==MPV_EVENT_SHUTDOWN){[NSApp terminate:nil];return;}
        if(event->event_id==MPV_EVENT_COMMAND_REPLY && event->error<0)fprintf(stderr,"command: %s\n",mpv_error_string(event->error));
    }
    // Honor speed changes made through IPC as well as the UI; media PTS remain unchanged.
    id speed=[self number:"speed"];
    if(speed!=NSNull.null && _rife.state==NSControlStateValueOn)[self command:@[@"vf-command",@"iive-rife",@"speed",[speed stringValue]]];
    NSDictionary *meta=[self metadata];id pos=[self number:"time-pos"],duration=[self number:"duration"];
    if(duration!=NSNull.null)_seek.maxValue=[duration doubleValue];if(pos!=NSNull.null)_seek.doubleValue=[pos doubleValue];
    int paused=0,seeking=0;mpv_get_property(_mpv,"pause",MPV_FORMAT_FLAG,&paused);mpv_get_property(_mpv,"seeking",MPV_FORMAT_FLAG,&seeking);
    double now=NSProcessInfo.processInfo.systemUptime;uint64_t renders=_video.renderCount;
    id rate=_lastStamp>0?@((renders-_lastRenders)/(now-_lastStamp)):NSNull.null;
    NSString *state=seeking?@"Seeking":paused?@"Paused":meta[@"state"]?:@"Off / no video";
    id drops=[self number:"frame-drop-count"],drift=[self number:"avsync"];
    _status.stringValue=[NSString stringWithFormat:@"%@ · AI frames %@ · output %@ · queue %@ · processing %@ ms\nRender callbacks %@/s (not display FPS) · drops %@ · A/V %@ s · SDR only",state,meta[@"generated"]?:@"N/A",meta[@"emitted"]?:@"N/A",meta[@"queued"]?:@"N/A",meta[@"processing_ms"]?:@"N/A",rate==NSNull.null?@"N/A":[NSString stringWithFormat:@"%.1f",[rate doubleValue]],drops==NSNull.null?@"N/A":drops,drift==NSNull.null?@"N/A":drift];
    NSDictionary *record=@{@"monotonic_s":@(now),@"media_pts":pos,@"paused":@(paused),@"seeking":@(seeking),@"speed":speed,@"filter":meta,@"render_calls":@(renders),@"render_callbacks_per_s":rate,@"display_fps":NSNull.null,@"dropped":drops,@"avsync_s":drift};
    if(_log){NSData *json=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];[_log writeData:json];[_log writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];}
    _lastStamp=now;_lastRenders=renders;
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender{return YES;}
- (void)applicationWillTerminate:(NSNotification *)note {
    _closing=YES;[_timer invalidate];[_video stopRenderer];if(_mpv){mpv_terminate_destroy(_mpv);_mpv=NULL;}[_log closeFile];
}
@end
int main(int argc,const char **argv){@autoreleasepool{
    NSApplication *app=NSApplication.sharedApplication;[app setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSMenu *bar=[NSMenu new];NSMenuItem *item=[NSMenuItem new];[bar addItem:item];NSMenu *menu=[NSMenu new];
    [menu addItemWithTitle:@"Quit IIVE Player" action:@selector(terminate:) keyEquivalent:@"q"];item.submenu=menu;app.mainMenu=bar;
    Player *delegate=[Player new];delegate.args=NSProcessInfo.processInfo.arguments;app.delegate=delegate;[app run];
}return 0;}
