// SPDX-License-Identifier: GPL-3.0-or-later
#import "MPVSession.h"
#import <VideoToolbox/VideoToolbox.h>
#include <mpv/client.h>
#include <fcntl.h>
#include <sys/resource.h>
#include <libproc.h>
#include <unistd.h>
static id object(mpv_node *node) {
    switch(node->format) {
        case MPV_FORMAT_STRING:return @(node->u.string);
        case MPV_FORMAT_FLAG:return @(node->u.flag!=0);
        case MPV_FORMAT_INT64:return @(node->u.int64);
        case MPV_FORMAT_DOUBLE:return isfinite(node->u.double_)?@(node->u.double_):NSNull.null;
        case MPV_FORMAT_NODE_ARRAY:{NSMutableArray *a=[NSMutableArray array];for(int i=0;i<node->u.list->num;i++)[a addObject:object(&node->u.list->values[i])];return a;}
        case MPV_FORMAT_NODE_MAP:{NSMutableDictionary *d=[NSMutableDictionary dictionary];for(int i=0;i<node->u.list->num;i++)d[@(node->u.list->keys[i])]=object(&node->u.list->values[i]);return d;}
        default:return NSNull.null;
    }
}
static NSArray<NSString *> *observedKeys(void) {
    return @[@"path",@"media-title",@"duration",@"pause",@"seeking",@"speed",@"volume",@"mute",
             @"video-params",@"video-out-params",@"osd-dimensions",@"container-fps",@"track-list",
             @"vf",@"eof-reached",@"hwdec-current",@"video-codec",@"playlist",@"playlist-pos",
             @"chapter-list",@"chapter",@"audio-delay",@"sub-delay",@"sub-scale",@"video-rotate",
             @"brightness",@"contrast",@"saturation",@"gamma",@"hue",@"hwdec",@"icc-profile-auto"];
}
@implementation MPVSession {
    mpv_handle *_mpv;
    VideoView *_view;
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    NSMutableDictionary *_observed;
    NSDictionary *_pendingSnapshot;
    BOOL _snapshotScheduled;
    NSString *_error;
    NSFileHandle *_metrics;
    BOOL _closed, _resumeAfterWarm;
    double _warmDeadline;
    uint64_t _lastRenders;
    double _lastTime,_lastSpeed;
    NSArray *_filters;
    NSString *_shader;
    int _capWidth, _capHeight;
    NSArray *_srScales;
    BOOL _fiSupported;
    double _resourceTime, _cpuSeconds;
    NSDictionary *_resources;
}
- (instancetype)initWithView:(VideoView *)view {
    if(!(self=[super init]))return nil;
    _view=view;_queue=dispatch_queue_create("org.iive.player.client",DISPATCH_QUEUE_SERIAL);
    _observed=[NSMutableDictionary dictionary];
    _mpv=mpv_create();if(!_mpv)return nil;
    for(NSArray *pair in @[@[@"config",@"no"],@[@"vo",@"libmpv"],@[@"hwdec",@"no"],@[@"idle",@"yes"],@[@"keep-open",@"yes"],@[@"terminal",@"yes"],@[@"volume",@"50"]])mpv_set_option_string(_mpv,[pair[0] UTF8String],[pair[1] UTF8String]);
    NSArray *args=NSProcessInfo.processInfo.arguments;
    NSUInteger ipc=[args indexOfObject:@"--ipc"];
    if(ipc!=NSNotFound&&ipc+1<args.count)mpv_set_option_string(_mpv,"input-ipc-server",[args[ipc+1] UTF8String]);
    if([args containsObject:@"--mute"])mpv_set_option_string(_mpv,"mute","yes");
    NSUInteger log=[args indexOfObject:@"--metrics"];
    if(log!=NSNotFound&&log+1<args.count){int fd=open([args[log+1] fileSystemRepresentation],O_WRONLY|O_CREAT|O_EXCL,0600);if(fd>=0)_metrics=[[NSFileHandle alloc]initWithFileDescriptor:fd closeOnDealloc:YES];}
    if(mpv_initialize(_mpv)<0 || ![view startRenderer:_mpv]){mpv_terminate_destroy(_mpv);_mpv=NULL;return nil;}
    mpv_request_log_messages(_mpv,"warn");
    for(NSString *key in observedKeys()) {
        _observed[key]=[self property:key];
        mpv_observe_property(_mpv,0,key.UTF8String,MPV_FORMAT_NODE);
    }
    _timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,_queue);
    dispatch_source_set_timer(_timer,DISPATCH_TIME_NOW,NSEC_PER_SEC/4,NSEC_PER_MSEC*30);
    __weak MPVSession *weak=self;
    dispatch_source_set_event_handler(_timer,^{[weak poll];});dispatch_resume(_timer);
    return self;
}
- (id)property:(NSString *)name {
    mpv_node node={0};if(mpv_get_property(_mpv,name.UTF8String,MPV_FORMAT_NODE,&node)<0)return NSNull.null;
    id result=object(&node);mpv_free_node_contents(&node);return result;
}
- (int)send:(NSArray<NSString *> *)args {
    const char **c=calloc(args.count+1,sizeof(char *));for(NSUInteger i=0;i<args.count;i++)c[i]=args[i].UTF8String;
    int result=mpv_command(_mpv,c);free(c);
    if(result<0)_error=[NSString stringWithFormat:@"%@: %s",args.firstObject,mpv_error_string(result)];
    return result;
}
- (void)command:(NSArray<NSString *> *)arguments {
    if(_closed)return;dispatch_async(_queue,^{if(self->_mpv){
        BOOL replacesFile=[arguments.firstObject isEqual:@"loadfile"] &&
            (arguments.count<3 || ![@[@"append",@"append+play"] containsObject:arguments[2]]);
        if((arguments.count>1 && [arguments[1] isEqual:@"pause"]) || replacesFile ||
           [@[@"stop",@"playlist-next",@"playlist-prev",@"playlist-play-index"] containsObject:arguments.firstObject])self->_resumeAfterWarm=NO;
        if([arguments.firstObject isEqual:@"loadfile"])self->_error=nil;
        [self send:arguments];
    }});
}
- (void)mutatePlaylistID:(int64_t)entryID remove:(BOOL)remove {
    if(_closed)return;
    dispatch_async(_queue, ^{
        if(!self->_mpv)return;
        id playlist=[self property:@"playlist"];
        if(![playlist isKindOfClass:NSArray.class])return;
        for(NSUInteger i=0;i<[playlist count];i++) {
            NSDictionary *entry=playlist[i];
            if([entry[@"id"] longLongValue]!=entryID)continue;
            if(remove && [entry[@"current"] boolValue])return;
            if(!remove)self->_resumeAfterWarm=NO;
            [self send:@[remove?@"playlist-remove":@"playlist-play-index",@(i).stringValue]];
            self->_observed[@"playlist"]=[self property:@"playlist"];
            [self poll];break;
        }
    });
}
- (void)playPlaylistID:(int64_t)entryID { [self mutatePlaylistID:entryID remove:NO]; }
- (void)removePlaylistID:(int64_t)entryID { [self mutatePlaylistID:entryID remove:YES]; }
- (void)reorderPlaylist:(NSArray<NSNumber *> *)ids {
    if(_closed)return;
    dispatch_async(_queue, ^{
        if(!self->_mpv)return;
        id playlist=[self property:@"playlist"];
        if(![playlist isKindOfClass:NSArray.class])return;
        NSMutableArray *live=[NSMutableArray array];
        for(NSDictionary *entry in playlist)if(entry[@"id"])[live addObject:entry[@"id"]];
        // Never apply index operations to a queue that changed after the UI snapshot.
        if(live.count!=ids.count || ![[NSSet setWithArray:live] isEqual:[NSSet setWithArray:ids]])return;
        for(NSUInteger target=0;target<ids.count;target++) {
            NSUInteger source=[live indexOfObject:ids[target]];
            if(source==target)continue;
            // Only move backwards; mpv's forward destination refers to the old index.
            if([self send:@[@"playlist-move",@(source).stringValue,@(target).stringValue]]<0)break;
            id entry=live[source];[live removeObjectAtIndex:source];[live insertObject:entry atIndex:target];
        }
        self->_observed[@"playlist"]=[self property:@"playlist"];
        [self poll];
    });
}
- (void)appendUniqueFiles:(NSArray<NSString *> *)paths around:(NSString *)selected completion:(void (^)(NSInteger))completion {
    if(_closed){dispatch_async(dispatch_get_main_queue(), ^{completion(-1);});return;}
    dispatch_async(_queue, ^{
        NSInteger added=-1;
        if(self->_mpv) {
            id playlist=[self property:@"playlist"];
            if([playlist isKindOfClass:NSArray.class]) {
                NSMutableSet *existing=[NSMutableSet set];BOOL matches=NO;
                for(NSDictionary *entry in playlist) {
                    NSString *file=entry[@"filename"];
                    if(![file isKindOfClass:NSString.class])continue;
                    NSString *normalized=file.stringByStandardizingPath;
                    [existing addObject:normalized];
                    if([entry[@"current"] boolValue] && [normalized isEqual:selected.stringByStandardizingPath])matches=YES;
                }
                if(matches) {
                    added=0;
                    for(NSString *path in paths)if(![existing containsObject:path.stringByStandardizingPath]) {
                        if([self send:@[@"loadfile",path,@"append"]]>=0){[existing addObject:path.stringByStandardizingPath];added++;}
                    }
                }
            }
            self->_observed[@"playlist"]=[self property:@"playlist"];
            [self poll];
        }
        dispatch_async(dispatch_get_main_queue(), ^{completion(added);});
    });
}
- (void)applyFilters:(NSArray<NSString *> *)filters shader:(NSString *)shader {
    if(_closed)return;
    dispatch_async(_queue,^{
        if(!self->_mpv)return;
        self->_error=nil;
        BOOL changed=![self->_filters isEqual:filters];
        BOOL shaderChanged=![self->_shader isEqual:shader]&&(shader||self->_shader);
        id paused=[self property:@"pause"];
        if((changed||shaderChanged)&&[paused isKindOfClass:NSNumber.class]&&![paused boolValue]) {
            self->_resumeAfterWarm=YES;self->_warmDeadline=NSProcessInfo.processInfo.systemUptime+20;
            [self send:@[@"set",@"pause",@"yes"]];
            self->_observed[@"pause"]=@YES;
        }
        if(changed) {
            id current=[self property:@"vf"];
            if([current isKindOfClass:NSArray.class])for(NSDictionary *item in current) {
                NSString *label=item[@"label"];
                if([label isKindOfClass:NSString.class]&&[label hasPrefix:@"iive-"])[self send:@[@"vf",@"remove",[@"@" stringByAppendingString:label]]];
            }
            for(NSString *filter in filters)[self send:@[@"vf",@"add",filter]];
            self->_filters=[filters copy];self->_lastSpeed=0;
            self->_observed[@"vf"]=[self property:@"vf"];
            id pts=[self property:@"time-pos"];
            if([pts isKindOfClass:NSNumber.class])[self send:@[@"seek",[pts stringValue],@"absolute+exact"]];
        }
        if(![self->_shader isEqual:shader] && (shader || self->_shader)) {
            if(self->_shader)[self send:@[@"change-list",@"glsl-shaders",@"remove",self->_shader]];
            if(shader)[self send:@[@"change-list",@"glsl-shaders",@"append",shader]];
            self->_shader=[shader copy];
        }
    });
}
- (NSDictionary *)resourceSnapshot {
    double now=NSProcessInfo.processInfo.systemUptime;
    if(_resources && now-_resourceTime<1)return _resources;
    NSMutableDictionary *sample=[NSMutableDictionary dictionaryWithDictionary:@{@"process-cpu-percent":NSNull.null,@"process-memory-bytes":NSNull.null,@"process-resident-bytes":NSNull.null,@"process-gpu-percent":NSNull.null}];
    struct rusage usage={0};
    if(getrusage(RUSAGE_SELF,&usage)==0) {
        double total=usage.ru_utime.tv_sec+usage.ru_utime.tv_usec/1e6+usage.ru_stime.tv_sec+usage.ru_stime.tv_usec/1e6;
        if(_resourceTime>0 && now>_resourceTime)sample[@"process-cpu-percent"]=@(MAX(0,(total-_cpuSeconds)/(now-_resourceTime)*100));
        _cpuSeconds=total;
    }
    struct rusage_info_v2 memory={0};
    if(proc_pid_rusage(getpid(),RUSAGE_INFO_V2,(rusage_info_t *)&memory)==0) {
        sample[@"process-memory-bytes"]=@(memory.ri_phys_footprint);
        sample[@"process-resident-bytes"]=@(memory.ri_resident_size);
    }
    _resourceTime=now;_resources=sample;
    return sample;
}
- (void)drainEvents {
    while(_mpv) {
        mpv_event *e=mpv_wait_event(_mpv,0);
        if(e->event_id==MPV_EVENT_NONE)break;
        if(e->event_id==MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *log=e->data;
            if(log->log_level<=MPV_LOG_LEVEL_ERROR)_error=[NSString stringWithFormat:@"%s: %s",log->prefix,log->text];
        } else if(e->event_id==MPV_EVENT_PROPERTY_CHANGE) {
            mpv_event_property *prop=e->data;
            if(prop && prop->name) {
                _observed[@(prop->name)]=(prop->format==MPV_FORMAT_NODE && prop->data)?object((mpv_node *)prop->data):NSNull.null;
            }
        } else if(e->event_id==MPV_EVENT_SHUTDOWN) {
            dispatch_async(dispatch_get_main_queue(),^{[NSApp terminate:nil];});
            break;
        }
    }
}
- (void)poll {
    if(!_mpv)return;
    [self drainEvents];
    NSMutableDictionary *s=[NSMutableDictionary dictionaryWithDictionary:[self resourceSnapshot]];
    [s addEntriesFromDictionary:_observed];
    for(NSString *key in @[@"time-pos",@"estimated-vf-fps",@"frame-drop-count",@"avsync",@"video-bitrate",@"audio-bitrate"])
        s[key]=[self property:key];
    for(NSString *label in @[@"iive-rife",@"iive-fi",@"iive-sr"])
        s[label]=_filters.count?[self property:[@"vf-metadata/" stringByAppendingString:label]]:NSNull.null;
    id passes=_shader?[self property:@"vo-passes"]:nil;
    // Pass descriptions prove shader execution; omit large GPU sample histories.
    NSMutableArray *descriptions=[NSMutableArray array];
    if([passes isKindOfClass:NSDictionary.class])for(NSString *kind in @[@"fresh",@"redraw"])
        for(NSDictionary *pass in passes[kind])if(pass[@"desc"])[descriptions addObject:pass[@"desc"]];
    s[@"vo-passes"]=descriptions;
    NSSize viewport=[_view pixelSize];s[@"viewport-width"]=@(viewport.width);s[@"viewport-height"]=@(viewport.height);
    double speed=[s[@"speed"] isKindOfClass:NSNumber.class]?[s[@"speed"] doubleValue]:1;
    if(speed!=_lastSpeed) {id filters=s[@"vf"];if([filters isKindOfClass:NSArray.class])for(NSDictionary *f in filters){NSString *label=f[@"label"];if([label isKindOfClass:NSString.class]&&[label hasPrefix:@"iive-"])[self send:@[@"vf-command",label,@"speed",@(speed).stringValue]];}_lastSpeed=speed;}
    uint64_t renders=[_view renderCount];double now=NSProcessInfo.processInfo.systemUptime;
    s[@"render-callback-fps"]=_lastTime?@((renders-_lastRenders)/(now-_lastTime)):NSNull.null;
    s[@"monotonic_s"]=@(now);s[@"display-fps"]=NSNull.null;s[@"error"]=_error?:@"";
    _lastTime=now;_lastRenders=renders;
    NSDictionary *vp=[s[@"video-params"] isKindOfClass:NSDictionary.class]?s[@"video-params"]:@{};
    int w=[vp[@"w"] intValue],h=[vp[@"h"] intValue];
    // Hardware capability queries depend on source geometry, not playback time.
    if(!_srScales || w!=_capWidth || h!=_capHeight) {
        _capWidth=w;_capHeight=h;
        _srScales=(w>0&&h>0)?[VTLowLatencySuperResolutionScalerConfiguration supportedScaleFactorsForFrameWidth:w frameHeight:h]:@[];
        _fiSupported=w>0 && h>0 && [VTLowLatencyFrameInterpolationConfiguration isSupported] && MAX(w,h)<=[VTLowLatencyFrameInterpolationConfiguration maximumDimensionForSpatialScaleFactor:1] && (int64_t)w*h<=[VTLowLatencyFrameInterpolationConfiguration maximumPixelCountForSpatialScaleFactor:1];
    }
    s[@"apple-sr-scales"]=_srScales?:@[];s[@"apple-fi-supported"]=@(_fiSupported);
    if(_resumeAfterWarm) {
        BOOL ready=YES;
        for(NSString *f in _filters) {
            NSString *label=[[f componentsSeparatedByString:@":"] firstObject];
            if([label hasPrefix:@"@"])label=[label substringFromIndex:1];
            id meta=s[label];
            if(![meta isKindOfClass:NSDictionary.class] || !meta[@"state"] || [meta[@"state"] isEqual:@"warming"])ready=NO;
        }
        if(ready || now>_warmDeadline){[self send:@[@"set",@"pause",@"no"]];_observed[@"pause"]=@NO;_resumeAfterWarm=NO;}
    }
    if(_metrics){NSData *json=[NSJSONSerialization dataWithJSONObject:s options:NSJSONWritingSortedKeys error:nil];if(json){[_metrics writeData:json];[_metrics writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];}}
    // Deliver UI snapshots exclusively in kCFRunLoopDefaultMode so main-thread SwiftUI
    // state never mutates during NSEventTrackingRunLoopMode (when menus or submenus are open).
    BOOL schedule=NO;
    @synchronized(self) {
        _pendingSnapshot=s;
        if(!_snapshotScheduled){_snapshotScheduled=YES;schedule=YES;}
    }
    if(schedule) {
        CFRunLoopRef mainLoop=CFRunLoopGetMain();
        __weak MPVSession *weakSelf=self;
        CFRunLoopPerformBlock(mainLoop,kCFRunLoopDefaultMode,^{
            MPVSession *strongSelf=weakSelf;
            if(!strongSelf)return;
            NSDictionary *latest=nil;
            @synchronized(strongSelf) {
                latest=strongSelf->_pendingSnapshot;
                strongSelf->_pendingSnapshot=nil;
                strongSelf->_snapshotScheduled=NO;
            }
            if(!strongSelf->_closed && latest && strongSelf.onSnapshot) {
                strongSelf.onSnapshot(latest);
            }
        });
        CFRunLoopWakeUp(mainLoop);
    }
}
- (void)shutdown {
    if(_closed)return;_closed=YES;self.onSnapshot=nil;
    if(_timer)dispatch_source_cancel(_timer);
    // Drain client calls while render updates still service advanced controls.
    dispatch_sync(_queue,^{});
    [_view stopRenderer];
    dispatch_sync(_queue,^{if(self->_mpv){mpv_terminate_destroy(self->_mpv);self->_mpv=NULL;}[self->_metrics closeFile];});
}
@end
