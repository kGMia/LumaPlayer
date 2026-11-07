#include <errno.h>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "MPVSession.h"
#import "VideoCrop.h"
#import "RIFETierChange.h"
#import "MediaSwitchDiagnostics.h"
#import "MPVWakeup.h"
#import "MPVEventPolicy.h"
#import "MPVQueueNext.h"
#import <VideoToolbox/VideoToolbox.h>
#include <mpv/client.h>
#include <fcntl.h>
#include <sys/resource.h>
#include <libproc.h>
#include <unistd.h>
#include <stdatomic.h>
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
             @"seekable",@"paused-for-cache",@"cache-buffering-state",@"demuxer-cache-duration",@"metadata",@"audio-params",@"audio-out-params",@"video-params",@"video-out-params",@"osd-dimensions",@"container-fps",@"track-list",
             @"vf",@"eof-reached",@"hwdec-current",@"video-codec",@"playlist",@"playlist-pos",
             @"chapter-list",@"chapter",@"audio-delay",@"sub-delay",@"sub-scale",@"video-rotate",
             @"brightness",@"contrast",@"saturation",@"gamma",@"hue",@"hwdec",@"icc-profile-auto",@"sid",@"secondary-sid",@"secondary-sub-delay",@"sub-text",@"secondary-sub-text",@"audio-device-list",@"audio-device",@"current-ao",
             @"ab-loop-a",@"ab-loop-b",@"video-aspect-override",@"video-crop",@"deinterlace",@"deinterlace-active"];
}
typedef NS_ENUM(NSInteger, IIVEWarmState) {
    IIVEWarmIdle, IIVEWarmResume, IIVEWarmStayPaused
};
@implementation MPVSession {
    mpv_handle *_mpv;
    VideoView *_view;
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    dispatch_source_t _eventWakeup;
    BOOL _eventSnapshotNeeded;
    NSMutableDictionary *_observed;
    NSDictionary *_pendingSnapshot;
    BOOL _snapshotScheduled;
    NSString *_error;
    NSString *_pendingNetworkError;
    uint64_t _mediaEpoch;
    struct iive_media_switch_timing _switchTiming;
    NSMutableArray<NSDictionary *> *_switchHistory;
    double _pendingNavigationTime;
    int _pendingNavigationCount;
    uint64_t _switchHistoryOverwritten;
    uint64_t _remoteNextRevision;
    NSNumber *_pendingNetworkHook;
    NSNumber *_pendingRecoveryHook;
    NSString *_recoveryKey;
    NSDictionary<NSString *, NSString *> *_recoveryOptions;
    NSInteger _recoveryAttempts;
    BOOL _recoverAfterEnd, _restoreRemote;
    BOOL _remoteRetryable;
    BOOL _remoteReadFailure, _forcedRemoteRecovery;
    BOOL _remoteFailed, _manualRemoteRetry;
    double _remotePosition;
    double _requestedResumePosition, _confirmedResumePosition;
    BOOL _mediaStarted, _mediaOpening;
    NSFileHandle *_metrics;
    NSString *_metricsPath;
    NSInteger _metricsSamples;
    BOOL _closed, _fileLoaded, _networkPrivacy;
    IIVEWarmState _warmState;
    double _warmDeadline;
    uint64_t _lastRenders;
    double _lastTime,_lastSpeed;
    NSArray *_filters;
    NSString *_shader;
    NSDictionary *_rifePerformanceState;
    uint64_t _rifeTierCommands;
    uint64_t _filterRebuildSeeks;
    int _capWidth, _capHeight;
    NSArray *_srScales;
    BOOL _fiSupported;
    double _resourceTime, _cpuSeconds;
    uint64_t _peakFootprint;
    NSDictionary *_resources;
    BOOL _detailedTelemetry;
    double _bitrateTime;
    uint64_t _bitrateEpoch;
    NSDictionary *_bitrates;
    void (^_captionHandler)(NSDictionary *);
    uint64_t _captionEpoch;
    NSString *_seekRequestID;
    int _seekCommandResult;
    _Atomic(uint64_t) _seekGeneration;
    uint64_t _coalescedSeeks;
    double _seekQueueMS, _seekCommandMS;
    dispatch_source_t _interactionTimer;
    NSString *_scrubPath, *_splitPath;
    BOOL _scrubResume, _scrubDirty, _splitDirty, _interactionWaiting;
    double _scrubTarget, _splitTarget, _interactionIssuedAt, _interactionLastDispatch;
    double _splitUpdatedAt, _splitPendingSince;
    uint64_t _splitRefreshSeeks;
    _Atomic(uint64_t) _splitGeneration;
    uint64_t _interactiveSeeks;
    NSString *_preferredAudioDevice, *_audioOutputStatus;
    NSDictionary<NSString *, NSString *> *_trackPreferences;
    BOOL _audioDeviceFailed;
    NSString *_cropRatio;
}
- (instancetype)initWithView:(VideoView *)view {
    if(!(self=[super init]))return nil;
    _view=view;_queue=dispatch_queue_create("org.iive.player.client",DISPATCH_QUEUE_SERIAL);
    _observed=[NSMutableDictionary dictionary];
    _preferredAudioDevice=@"auto";
    _mpv=mpv_create();if(!_mpv)return nil;
    // Keep the audio chain alive if a device disappears while it is opening,
    // so a subsequent route change can recover without reloading the movie.
    mpv_set_option_string(_mpv,"audio-fallback-to-null","yes");
    // Homebrew OpenSSL's compiled CA path is unavailable in a relocated app.
    // Use the OS-supplied certificate bundle; certificate verification stays on.
    if([NSBundle.mainBundle URLForResource:@"RuntimeDependencies" withExtension:@"json"])
        mpv_set_option_string(_mpv,"tls-ca-file","/etc/ssl/cert.pem");
    for(NSArray *pair in @[@[@"config",@"no"],@[@"audio-display",@"no"],@[@"tone-mapping",@"bt.2390"],@[@"vo",@"libmpv"],@[@"hwdec",@"no"],@[@"idle",@"yes"],@[@"keep-open",@"yes"],@[@"terminal",@"no"],@[@"volume",@"50"]])mpv_set_option_string(_mpv,[pair[0] UTF8String],[pair[1] UTF8String]);
    NSArray *args=NSProcessInfo.processInfo.arguments;
    NSUInteger ipc=[args indexOfObject:@"--ipc"];
    if(ipc!=NSNotFound&&ipc+1<args.count)mpv_set_option_string(_mpv,"input-ipc-server",[args[ipc+1] UTF8String]);
    if([args containsObject:@"--mute"])mpv_set_option_string(_mpv,"mute","yes");
    NSUInteger log=[args indexOfObject:@"--metrics"];
    if(log!=NSNotFound&&log+1<args.count){int fd=open([args[log+1] fileSystemRepresentation],O_WRONLY|O_CREAT|O_EXCL,0600);if(fd>=0){_metrics=[[NSFileHandle alloc]initWithFileDescriptor:fd closeOnDealloc:YES];_metricsPath=[args[log+1] copy];_metricsSamples=0;}}
    if(mpv_initialize(_mpv)<0 || ![view startRenderer:_mpv]){mpv_terminate_destroy(_mpv);_mpv=NULL;return nil;}
    mpv_request_log_messages(_mpv,"warn");
    mpv_hook_add(_mpv,0,"on_load",50);
    mpv_hook_add(_mpv,0,"on_after_end_file",50);
    for(NSString *key in observedKeys()) {
        _observed[key]=[self property:key];
        mpv_observe_property(_mpv,0,key.UTF8String,MPV_FORMAT_NODE);
    }
    _timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,_queue);
    dispatch_source_set_timer(_timer,DISPATCH_TIME_NOW,NSEC_PER_SEC/4,NSEC_PER_MSEC*30);
    __weak MPVSession *weak=self;
    dispatch_source_set_event_handler(_timer,^{[weak pollWithPerformanceSample:YES];});dispatch_resume(_timer);
    _eventWakeup=dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD,0,0,_queue);
    dispatch_source_set_event_handler(_eventWakeup,^{
        MPVSession *strong=weak;
        if(!strong || strong->_closed || !strong->_mpv)return;
        uint64_t epoch=strong->_mediaEpoch;
        BOOL loaded=strong->_fileLoaded,started=strong->_mediaStarted,opening=strong->_mediaOpening;
        [strong drainEvents];
        // Event draining serves hooks immediately; avoid full-rate property/UI
        // sampling for ordinary cache/property wakeups. Lifecycle/readiness and
        // discrete transport transitions need an immediate snapshot; other
        // properties retain the 4 Hz telemetry timer.
        if(epoch!=strong->_mediaEpoch || loaded!=strong->_fileLoaded ||
           started!=strong->_mediaStarted || opening!=strong->_mediaOpening || strong->_eventSnapshotNeeded)[strong poll];
    });
    dispatch_resume(_eventWakeup);
    mpv_set_wakeup_callback(_mpv,iive_mpv_wakeup,(__bridge void *)_eventWakeup);
    return self;
}
- (id)property:(NSString *)name {
    mpv_node node={0};if(mpv_get_property(_mpv,name.UTF8String,MPV_FORMAT_NODE,&node)<0)return NSNull.null;
    id result=object(&node);mpv_free_node_contents(&node);return result;
}
// Keep device routing on the mpv client queue. Never alter macOS's system-wide
// output preference. The audio-device property is a configured route, not proof
// that the hardware is producing audio.
- (void)applyPreferredAudioDevice {
    id list=[self property:@"audio-device-list"];
    if(![list isKindOfClass:NSArray.class])return;
    BOOL available=[_preferredAudioDevice isEqual:@"auto"];
    for(NSDictionary *entry in list)if([entry[@"name"] isEqual:_preferredAudioDevice])available=YES;
    NSString *effective=available && !_audioDeviceFailed?_preferredAudioDevice:@"auto";
    _audioOutputStatus=_audioDeviceFailed?@"Saved device could not open · configured for System Default.":
        (available?@"":@"Saved device unavailable · configured for System Default.");
    if(![[self property:@"audio-device"] isEqual:effective]) {
        int result=mpv_set_property_string(_mpv,"audio-device",effective.UTF8String);
        if(result<0)_audioOutputStatus=@"Unable to change audio output. Select System Default or reopen the media.";
    }
    _observed[@"audio-device-list"]=list;
}
- (void)selectPreferredAudioDevice:(NSString *)device {
    if(_closed)return;
    dispatch_async(_queue,^{
        if(!self->_mpv)return;
        self->_preferredAudioDevice=device.length?[device copy]:@"auto";
        self->_audioDeviceFailed=NO;
        [self applyPreferredAudioDevice];
    });
}
- (void)configureTrackPreferences:(NSDictionary<NSString *,NSString *> *)options {
    if(_closed)return;
    dispatch_async(_queue,^{
        if(!self->_mpv)return;
        NSMutableDictionary *safe=[NSMutableDictionary dictionary];
        for(NSString *key in @[@"alang",@"slang",@"aid",@"sid",@"secondary-sid"])
            if(options[key])safe[key]=options[key];
        self->_trackPreferences=[safe copy];
    });
}
- (void)setLoopPoint:(NSString *)point expectedEpoch:(uint64_t)epoch {
    if(_closed || ![@[@"a",@"b",@"clear"] containsObject:point])return;
    dispatch_async(_queue,^{
        if(self->_mpv)[self drainEvents];
        if(!self->_mpv || self->_mediaEpoch!=epoch || !self->_fileLoaded)return;
        if([self->_error isEqual:@"Set B at least 0.1 seconds after A."])self->_error=nil;
        if([point isEqual:@"clear"]) {
            [self send:@[@"set",@"ab-loop-b",@"no"]];
            [self send:@[@"set",@"ab-loop-a",@"no"]];
        } else {
            id seekable=[self property:@"seekable"], seeking=[self property:@"seeking"];
            id position=[self property:@"time-pos"], duration=[self property:@"duration"];
            if(![seekable isEqual:@YES] || [seeking isEqual:@YES] || self->_scrubPath ||
               ![position isKindOfClass:NSNumber.class] || ![duration isKindOfClass:NSNumber.class])return;
            double now=[position doubleValue], end=[duration doubleValue];
            if(!isfinite(now) || !isfinite(end) || now<0 || now>=end)return;
            if([point isEqual:@"a"]) {
                [self send:@[@"set",@"ab-loop-b",@"no"]];
                [self send:@[@"set",@"ab-loop-a",@(now).stringValue]];
            } else {
                id start=[self property:@"ab-loop-a"];
                if(![start isKindOfClass:NSNumber.class] || !isfinite([start doubleValue]) || now-[start doubleValue]<0.1) {
                    self->_error=@"Set B at least 0.1 seconds after A.";return;
                }
                [self send:@[@"set",@"ab-loop-count",@"inf"]];
                [self send:@[@"set",@"ab-loop-b",@(now).stringValue]];
            }
        }
        for(NSString *key in @[@"ab-loop-a",@"ab-loop-b"])self->_observed[key]=[self property:key];
    });
}
- (void)setVideoGeometry:(NSString *)option value:(NSString *)value expectedEpoch:(uint64_t)epoch {
    if(_closed || ![@[@"video-aspect-override",@"video-crop"] containsObject:option])return;
    NSArray *ratios=@[@"16:9",@"4:3",@"1:1",@"235:100",@"239:100",@"9:16"];
    BOOL reset=([option isEqual:@"video-crop"] && !value.length) || ([option isEqual:@"video-aspect-override"] && [value isEqual:@"no"]);
    if(!reset && ![ratios containsObject:value])return;
    dispatch_async(_queue,^{
        if(self->_mpv)[self drainEvents];
        if(!self->_mpv || !self->_fileLoaded || self->_mediaEpoch!=epoch)return;
        if([option isEqual:@"video-crop"]) {
            NSString *previous=self->_cropRatio;self->_cropRatio=[value copy];
            if(![self applyCenterCrop])self->_cropRatio=previous;
        } else {
            [self send:@[@"set",option,value]];
        }
        self->_observed[option]=[self property:option];
    });
}
- (BOOL)applyCenterCrop {
    NSString *rectangle=@"";
    if(_cropRatio.length) {
        id params=[self property:@"video-out-params"];
        if(![params isKindOfClass:NSDictionary.class])return NO;
        NSArray *ratio=[_cropRatio componentsSeparatedByString:@":"];
        if(ratio.count!=2)return NO;
        struct IIVECrop crop;
        if(!iive_center_crop([params[@"w"] intValue],[params[@"h"] intValue],
            params[@"par"]?[params[@"par"] doubleValue]:1.0,[params[@"rotate"] intValue],
            [ratio[0] doubleValue]/[ratio[1] doubleValue],&crop))return NO;
        rectangle=[NSString stringWithFormat:@"%dx%d+%d+%d",crop.w,crop.h,crop.x,crop.y];
    }
    if([[self property:@"video-crop"] isEqual:rectangle])return YES;
    return [self send:@[@"set",@"video-crop",rectangle]]>=0;
}
- (int)send:(NSArray<NSString *> *)args {
    double commandAt=NSProcessInfo.processInfo.systemUptime;
    const char **c=calloc(args.count+1,sizeof(char *));for(NSUInteger i=0;i<args.count;i++)c[i]=args[i].UTF8String;
    int result=mpv_command(_mpv,c);free(c);
    BOOL navigation=[@[@"playlist-next",@"playlist-prev",@"playlist-play-index"] containsObject:args.firstObject] ||
        ([args.firstObject isEqual:@"loadfile"] && (args.count<3 || [args[2] isEqual:@"replace"] ||
            ([args[2] isEqual:@"append+play"] && !_fileLoaded && !_mediaOpening)));
    if(result>=0 && navigation) { _pendingNavigationTime=commandAt;_pendingNavigationCount++; }
    if([args.firstObject isEqual:@"stop"]) { _pendingNavigationTime=0;_pendingNavigationCount=0; }
    if(result<0)_error=[NSString stringWithFormat:@"%@: %s",args.firstObject,mpv_error_string(result)];
    return result;
}
// All mutable interaction state below is confined to the client queue.
- (void)stopInteractionTimerIfIdle {
    if (!_scrubPath && !_splitDirty && _interactionTimer) {
        dispatch_source_cancel(_interactionTimer); _interactionTimer=nil;
    }
}
- (void)endScrubRestoringPlayback:(BOOL)restore {
    NSString *path=_scrubPath; BOOL resume=_scrubResume;
    _scrubPath=nil; _scrubDirty=NO;
    if (restore && path && _mpv && [[self property:@"path"] isEqual:path]) {
        if (_warmState!=IIVEWarmIdle) _warmState=resume?IIVEWarmResume:IIVEWarmStayPaused;
        else [self send:@[@"set",@"pause",resume?@"no":@"yes"]];
    }
    [self stopInteractionTimerIfIdle];
}
- (BOOL)applyPendingSplit {
    if (!_splitDirty) return NO;
    _splitDirty=NO;
    if (![[self property:@"path"] isEqual:_splitPath]) return NO;
    id filters=[self property:@"vf"];
    if ([filters isKindOfClass:NSArray.class]) for (NSDictionary *filter in filters) {
        if ([filter[@"label"] isEqual:@"iive-sr"] && [filter[@"name"] isEqual:@"iive-fsrcnnx"]) {
            id metadata=[self property:@"vf-metadata/iive-sr"];
            id current=[metadata isKindOfClass:NSDictionary.class]?metadata[@"split_ratio"]:nil;
            if ([current respondsToSelector:@selector(doubleValue)] && fabs([current doubleValue]-_splitTarget)<0.0005) return NO;
            return [self send:@[@"vf-command",@"iive-sr",@"split",@(_splitTarget).stringValue]]>=0;
        }
    }
    return NO;
}
- (void)pumpInteraction {
    if (!_mpv) return;
    [self drainEvents];
    if (_scrubPath && ![[self property:@"path"] isEqual:_scrubPath]) [self endScrubRestoringPlayback:NO];
    double now=NSProcessInfo.processInfo.systemUptime;
    if (now-_interactionLastDispatch<0.12) return;
    // Wait for playback-restart before issuing another preview. A bounded escape
    // allows the newest pointer target to supersede a very slow old seek.
    if (_interactionWaiting && now-_interactionIssuedAt<0.8) return;
    if (!_scrubPath && [[self property:@"seeking"] respondsToSelector:@selector(boolValue)] &&
        [[self property:@"seeking"] boolValue]) return;
    // Paused filters cannot redraw by themselves: every refresh re-decodes a
    // frame. Wait for a brief pointer rest, but retain bounded visual feedback
    // during a long drag. Scrubbing/final seeks already refresh the filter.
    if (_splitDirty && !_scrubPath && [[self property:@"pause"] boolValue] &&
        now-_splitUpdatedAt<0.18 && now-_splitPendingSince<0.6) return;
    BOOL splitChanged=[self applyPendingSplit];
    if (splitChanged) _interactionLastDispatch=now;
    if (_scrubPath && _scrubDirty) {
        _scrubDirty=NO;
        _interactionWaiting=[self send:@[@"seek",@(_scrubTarget).stringValue,@"absolute+keyframes"]]>=0;
        _interactionIssuedAt=now; _interactionLastDispatch=now; _interactiveSeeks++;
    } else if (splitChanged && [[self property:@"pause"] boolValue] && !_scrubPath) {
        id position=[self property:@"time-pos"];
        if ([position isKindOfClass:NSNumber.class]) {
            _interactionWaiting=[self send:@[@"seek",[position stringValue],@"absolute+exact"]]>=0;
            _interactionIssuedAt=now;
            if (_interactionWaiting) _splitRefreshSeeks++;
        }
    }
    [self stopInteractionTimerIfIdle];
}
- (void)startInteractionTimer {
    if (_interactionTimer) return;
    _interactionTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,_queue);
    dispatch_source_set_timer(_interactionTimer,dispatch_time(DISPATCH_TIME_NOW,0),120*NSEC_PER_MSEC,15*NSEC_PER_MSEC);
    __weak MPVSession *weak=self;
    dispatch_source_set_event_handler(_interactionTimer,^{[weak pumpInteraction];});
    dispatch_resume(_interactionTimer);
}
- (void)previewScrubTo:(double)seconds expectedPath:(NSString *)path {
    if (_closed || !isfinite(seconds) || seconds<0) return;
    uint64_t generation=atomic_fetch_add_explicit(&_seekGeneration,1,memory_order_relaxed)+1;
    dispatch_async(_queue,^{
        if (!self->_mpv || generation!=atomic_load_explicit(&self->_seekGeneration,memory_order_relaxed) ||
            ![[self property:@"path"] isEqual:path]) return;
        self->_remoteReadFailure=NO;
        self->_requestedResumePosition=0;self->_confirmedResumePosition=0;
        if (self->_scrubPath && fabs(seconds-self->_scrubTarget)<0.04) return;
        if (!self->_scrubPath) {
            self->_scrubPath=[path copy];
            self->_scrubResume=self->_warmState==IIVEWarmResume ||
                (self->_warmState==IIVEWarmIdle && ![[self property:@"pause"] boolValue]);
            if (self->_warmState!=IIVEWarmIdle) self->_warmState=IIVEWarmStayPaused;
            [self send:@[@"set",@"pause",@"yes"]];
        }
        self->_scrubTarget=seconds; self->_scrubDirty=YES;
        [self startInteractionTimer];
    });
}
- (void)cancelScrubForPath:(NSString *)path {
    if (_closed) return;
    atomic_fetch_add_explicit(&_seekGeneration,1,memory_order_relaxed);
    dispatch_async(_queue,^{
        if ([self->_scrubPath isEqual:path]) [self endScrubRestoringPlayback:YES];
    });
}
- (void)updateSplit:(double)ratio expectedPath:(NSString *)path {
    if (_closed || !isfinite(ratio) || ratio<0 || ratio>1) return;
    uint64_t generation=atomic_fetch_add_explicit(&_splitGeneration,1,memory_order_relaxed)+1;
    dispatch_async(_queue,^{
        if (!self->_mpv || generation!=atomic_load_explicit(&self->_splitGeneration,memory_order_relaxed) ||
            ![[self property:@"path"] isEqual:path]) return;
        // Snapshot reconciliation can repeat the same target; it must not
        // postpone the trailing refresh indefinitely.
        if (self->_splitDirty && [self->_splitPath isEqual:path] &&
            fabs(self->_splitTarget-ratio)<0.0005) return;
        double now=NSProcessInfo.processInfo.systemUptime;
        if (!self->_splitDirty || ![self->_splitPath isEqual:path]) self->_splitPendingSince=now;
        self->_splitUpdatedAt=now;
        self->_splitPath=[path copy];self->_splitTarget=ratio;self->_splitDirty=YES;
        [self startInteractionTimer];
    });
}
- (void)seekToSeconds:(double)seconds expectedPath:(NSString *)path requestID:(NSString *)requestID {
    if (_closed || !isfinite(seconds)) return;
    const uint64_t generation = atomic_fetch_add_explicit(&_seekGeneration, 1, memory_order_relaxed) + 1;
    const double issued = NSProcessInfo.processInfo.systemUptime;
    dispatch_async(_queue, ^{
        if (!self->_mpv) return;
        // Only discard work still waiting on our client queue. An already-issued
        // mpv seek is not canceled or reported as completed by this check.
        if (generation != atomic_load_explicit(&self->_seekGeneration, memory_order_relaxed)) {
            self->_coalescedSeeks++; return;
        }
        self->_seekQueueMS = (NSProcessInfo.processInfo.systemUptime - issued) * 1000;
        self->_seekCommandMS = 0;
        self->_seekRequestID = [requestID copy];
        if (![[self property:@"path"] isEqual:path]) {
            self->_seekCommandResult = MPV_ERROR_COMMAND;
            return;
        }
        if (self->_warmState != IIVEWarmIdle)
            self->_warmDeadline = NSProcessInfo.processInfo.systemUptime + 20;
        const double start = NSProcessInfo.processInfo.systemUptime;
        [self applyPendingSplit];
        self->_scrubDirty=NO;
        self->_remoteReadFailure=NO;
        self->_requestedResumePosition=0;self->_confirmedResumePosition=0;
        self->_seekCommandResult = [self send:@[@"seek", @(seconds).stringValue, @"absolute+exact"]];
        self->_seekCommandMS = (NSProcessInfo.processInfo.systemUptime - start) * 1000;
        self->_interactionWaiting=self->_seekCommandResult>=0;
        self->_interactionIssuedAt=NSProcessInfo.processInfo.systemUptime;
        [self endScrubRestoringPlayback:YES];
        // Command acceptance is not completion. The regular snapshot provides
        // this request ID together with the fresh playback clock and seek state.
    });
}
- (void)saveSourceFrameTo:(NSString *)destination expectedPath:(NSString *)path completion:(void (^)(NSString * _Nullable))completion {
    [self saveFrameTo:destination expectedPath:path includeOverlays:NO completion:completion];
}
- (void)saveFrameTo:(NSString *)destination expectedPath:(NSString *)path completion:(void (^)(NSString * _Nullable))completion {
    [self saveFrameTo:destination expectedPath:path includeOverlays:YES completion:completion];
}
- (void)saveFrameTo:(NSString *)destination expectedPath:(NSString *)path includeOverlays:(BOOL)overlays completion:(void (^)(NSString * _Nullable))completion {
    dispatch_async(_queue, ^{
        NSString *error = nil;
        if (!self->_mpv || ![[self property:@"path"] isEqual:path]) {
            error = @"The video changed before the frame could be captured.";
        } else {
            int result = [self send:@[@"screenshot-to-file", destination, overlays ? @"window" : @"video"]];
            if (result < 0) error = [NSString stringWithUTF8String:mpv_error_string(result)];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}
- (void)cancelWarmupForFileChange {
    // An internal warm-up pause must not leak into the next file.
    if(_warmState==IIVEWarmResume)[self send:@[@"set",@"pause",@"no"]];
    _warmState=IIVEWarmIdle;
}
// Completes only after each setting has been acknowledged on the mpv client queue.
// SDR profile updates do not suspend presentation while the client queue responds.
- (void)configureColorOutput:(NSArray<NSArray<NSString *> *> *)commands completion:(void (^)(BOOL))completion {
    dispatch_async(_queue,^{
        BOOL accepted=self->_mpv!=NULL;
        if(accepted)for(NSArray<NSString *> *args in commands) {
            if([self send:args]<0)accepted=NO;
        }
        dispatch_async(dispatch_get_main_queue(),^{completion(accepted);});
    });
}
- (void)loadNetworkURL:(NSString *)url options:(NSDictionary<NSString *,NSString *> *)options append:(BOOL)append {
    if(_closed)return;
    if(!append)atomic_fetch_add_explicit(&_seekGeneration,1,memory_order_relaxed);
    dispatch_async(_queue,^{
        if(!self->_mpv)return;
        self->_networkPrivacy=YES;self->_error=nil;
        if(!append) {
            [self cancelRemoteRecovery];
            if(self->_pendingNetworkHook){mpv_hook_continue(self->_mpv,self->_pendingNetworkHook.unsignedLongLongValue);self->_pendingNetworkHook=nil;}
            [self endScrubRestoringPlayback:YES];self->_splitDirty=NO;
            [self stopInteractionTimerIfIdle];[self cancelWarmupForFileChange];
        }
        NSArray<NSString *> *keys=options.allKeys;
        mpv_node *values=calloc(keys.count,sizeof(mpv_node));
        char **names=calloc(keys.count,sizeof(char *));
        for(NSUInteger i=0;i<keys.count;i++) {
            names[i]=(char *)keys[i].UTF8String;
            values[i].format=MPV_FORMAT_STRING;values[i].u.string=(char *)options[keys[i]].UTF8String;
        }
        mpv_node_list map={.num=(int)keys.count,.keys=names,.values=values};
        mpv_node args[5]={0};
        args[0].format=MPV_FORMAT_STRING;args[0].u.string="loadfile";
        args[1].format=MPV_FORMAT_STRING;args[1].u.string=(char *)url.UTF8String;
        args[2].format=MPV_FORMAT_STRING;args[2].u.string=append?"append+play":"replace";
        args[3].format=MPV_FORMAT_INT64;args[3].u.int64=-1;
        args[4].format=MPV_FORMAT_NODE_MAP;args[4].u.list=&map;
        mpv_node_list list={.num=5,.values=args};
        mpv_node command={.format=MPV_FORMAT_NODE_ARRAY,.u.list=&list};
        double commandAt=NSProcessInfo.processInfo.systemUptime;
        int result=mpv_command_node(self->_mpv,&command,NULL);
        if(result>=0 && (!append || (!self->_fileLoaded && !self->_mediaOpening))) {
            self->_pendingNavigationTime=commandAt;self->_pendingNavigationCount++;
        }
        free(values);free(names);
        if(result<0)self->_error=[NSString stringWithFormat:@"Open network media: %s",mpv_error_string(result)];
    });
}
- (void)loadRemoteQueue:(NSArray<NSString *> *)keys selected:(NSInteger)selected append:(BOOL)append {
    if(_closed || !keys.count || selected<0 || selected>=keys.count)return;
    if(!append)atomic_fetch_add_explicit(&_seekGeneration,1,memory_order_relaxed);
    dispatch_async(_queue,^{
        if(!self->_mpv)return;
        self->_networkPrivacy=YES;self->_error=nil;
        if(!append){
            [self cancelRemoteRecovery];
            [self endScrubRestoringPlayback:YES];[self cancelWarmupForFileChange];
            if(self->_pendingNetworkHook){mpv_hook_continue(self->_mpv,self->_pendingNetworkHook.unsignedLongLongValue);self->_pendingNetworkHook=nil;}
        }
        id playlist=[self property:@"playlist"];NSInteger base=append && [playlist isKindOfClass:NSArray.class]?[playlist count]:0;
        [self send:@[@"loadfile",keys[selected],append?@"append+play":@"replace"]];
        for(NSInteger i=0;i<keys.count;i++)if(i!=selected)[self send:@[@"loadfile",keys[i],@"append"]];
        if(selected>0)[self send:@[@"playlist-move",@(base).stringValue,@(base+selected+1).stringValue]];
        self->_observed[@"playlist"]=[self property:@"playlist"];
    });
}
- (void)enqueueRemoteNext:(NSArray<NSString *> *)keys {
    if(_closed || !keys.count)return;
    dispatch_async(_queue,^{
        if(!self->_mpv)return;
        self->_networkPrivacy=YES;
        int status=iive_queue_next(self->_mpv,keys);
        self->_remoteNextRevision++;
        if(status<0)self->_error=[NSString stringWithFormat:@"Queue next: %s",mpv_error_string(status)];
        self->_observed[@"playlist"]=[self property:@"playlist"];
        [self poll];
    });
}
- (void)finishLocalHook:(uint64_t)hookID options:(NSDictionary<NSString *,NSString *> *)options {
    if(_closed)return;
    dispatch_async(_queue,^{
        if(!self->_mpv || ![self->_pendingNetworkHook isEqual:@(hookID)])return;
        for(NSString *key in @[@"start",@"speed",@"aid",@"sid",@"secondary-sid"]) {
            if(options[key]) {
                int result=mpv_set_property_string(self->_mpv,[@"file-local-options/" stringByAppendingString:key].UTF8String,options[key].UTF8String);
                double position=[options[key] doubleValue];
                if(result>=0 && [key isEqual:@"start"] && isfinite(position) && position>5)self->_requestedResumePosition=position;
            }
        }
        self->_pendingNetworkHook=nil;mpv_hook_continue(self->_mpv,hookID);
    });
}
- (void)finishNetworkHook:(uint64_t)hookID url:(NSString *)url options:(NSDictionary<NSString *,NSString *> *)options error:(NSString *)error {
    if(_closed)return;
    dispatch_async(_queue,^{
        if(!self->_mpv || !self->_pendingNetworkHook || self->_pendingNetworkHook.unsignedLongLongValue!=hookID)return;
        BOOL ok=url!=nil;
        if(!ok)self->_remoteRetryable=NO;
        NSMutableDictionary<NSString *, NSString *> *effective=[options mutableCopy];
        BOOL recovering=self->_restoreRemote && self->_recoveryOptions && [[self property:@"path"] isEqual:self->_recoveryKey];
        if(recovering) {
            [effective addEntriesFromDictionary:self->_recoveryOptions?:@{}];
            effective[@"start"]=@(self->_remotePosition).stringValue;
        }
        self->_restoreRemote=NO;
        if(ok) for(NSString *key in effective) {
            NSString *prop=[@"file-local-options/" stringByAppendingString:key];
            if(mpv_set_property_string(self->_mpv,prop.UTF8String,effective[key].UTF8String)<0)ok=NO;
        }
        if(ok)ok=mpv_set_property_string(self->_mpv,"stream-open-filename",url.UTF8String)>=0;
        double position=[effective[@"start"] doubleValue];
        if(ok && !recovering && isfinite(position) && position>5)self->_requestedResumePosition=position;
        if(!ok)self->_pendingNetworkError=error?:@"Unable to prepare remote media. Reopen it from the server.";
        self->_pendingNetworkHook=nil;mpv_hook_continue(self->_mpv,hookID);
    });
}
- (void)command:(NSArray<NSString *> *)arguments {
    if(_closed)return;
    BOOL replacesFile=[arguments.firstObject isEqual:@"loadfile"] &&
        (arguments.count<3 || ![@[@"append",@"append+play"] containsObject:arguments[2]]);
    BOOL frameStep=[@[@"frame-step",@"frame-back-step"] containsObject:arguments.firstObject];
    if(frameStep || replacesFile || [@[@"stop",@"playlist-next",@"playlist-prev",@"playlist-play-index"] containsObject:arguments.firstObject])
        atomic_fetch_add_explicit(&_seekGeneration,1,memory_order_relaxed);
    dispatch_async(_queue,^{if(self->_mpv){
        if(replacesFile || [@[@"stop",@"playlist-next",@"playlist-prev",@"playlist-play-index"] containsObject:arguments.firstObject])
            [self cancelRemoteRecovery];
        if(self->_pendingNetworkHook && (replacesFile || [@[@"stop",@"playlist-next",@"playlist-prev",@"playlist-play-index"] containsObject:arguments.firstObject])) {
            uint64_t ticket=self->_pendingNetworkHook.unsignedLongLongValue;self->_pendingNetworkHook=nil;
            mpv_hook_continue(self->_mpv,ticket);
        }
        BOOL replacesFile=[arguments.firstObject isEqual:@"loadfile"] &&
            (arguments.count<3 || ![@[@"append",@"append+play"] containsObject:arguments[2]]);
        BOOL pauseCommand=arguments.count>1 && [arguments[1] isEqual:@"pause"] &&
            [@[@"set",@"cycle"] containsObject:arguments.firstObject];
        if(self->_recoveryOptions && (self->_remoteFailed || self->_manualRemoteRetry || self->_pendingRecoveryHook || self->_restoreRemote || (self->_mediaOpening && self->_recoveryAttempts>0))) {
            NSMutableDictionary *resume=[self->_recoveryOptions mutableCopy];
            if(pauseCommand)resume[@"pause"]=[arguments.firstObject isEqual:@"cycle"]?
                ([resume[@"pause"] isEqual:@"yes"]?@"no":@"yes"):(arguments.count>2?arguments[2]:@"yes");
            else if(arguments.count>2 && [arguments[0] isEqual:@"set"] &&
                    [@[@"speed",@"aid",@"sid",@"secondary-sid"] containsObject:arguments[1]])resume[arguments[1]]=arguments[2];
            self->_recoveryOptions=resume;
        }
        if (replacesFile || pauseCommand || [@[@"seek",@"stop",@"frame-step",@"frame-back-step",@"playlist-next",@"playlist-prev",@"playlist-play-index"] containsObject:arguments.firstObject]) {
            if([@[@"seek",@"frame-step",@"frame-back-step"] containsObject:arguments.firstObject]) {
                self->_remoteReadFailure=NO;self->_requestedResumePosition=0;self->_confirmedResumePosition=0;
            }
            [self endScrubRestoringPlayback:!frameStep];
            if (replacesFile || [@[@"stop",@"playlist-next",@"playlist-prev",@"playlist-play-index"] containsObject:arguments.firstObject]) {
                self->_splitDirty=NO; [self stopInteractionTimerIfIdle];
            }
        }
        if(frameStep) {
            // Stepping owns pause intent even while a model is warming. Avoid a
            // redundant pause (which clears mpv's queued forward steps) and an
            // expensive poll before the actual frame command reaches the core.
            if(self->_warmState!=IIVEWarmIdle)self->_warmState=IIVEWarmStayPaused;
            // Let this new frame apply the split, instead of a trailing timer
            // issuing another exact seek immediately after the requested step.
            [self applyPendingSplit];
            [self stopInteractionTimerIfIdle];
        }
        if(pauseCommand && self->_warmState!=IIVEWarmIdle) {
            // The engine is temporarily paused by us, but Play/Pause operates on
            // user intent, not that internal pause.
            BOOL pause=[arguments.firstObject isEqual:@"cycle"] ? self->_warmState==IIVEWarmResume :
                (arguments.count>2 && [@[@"yes",@"true",@"1"] containsObject:arguments[2]]);
            self->_warmState=pause?IIVEWarmStayPaused:IIVEWarmResume;
            [self send:@[@"set",@"pause",@"yes"]];
            [self poll];return;
        }
        if(replacesFile || [@[@"stop",@"playlist-next",@"playlist-prev",@"playlist-play-index"] containsObject:arguments.firstObject])
            [self cancelWarmupForFileChange];
        if([arguments.firstObject isEqual:@"seek"] && self->_warmState!=IIVEWarmIdle)
            self->_warmDeadline=NSProcessInfo.processInfo.systemUptime+20;
        if([arguments.firstObject isEqual:@"loadfile"])self->_error=nil;
        [self send:arguments];
    }});
}
- (void)mutatePlaylistID:(int64_t)entryID remove:(BOOL)remove {
    if(_closed)return;
    if(!remove)atomic_fetch_add_explicit(&_seekGeneration,1,memory_order_relaxed);
    dispatch_async(_queue, ^{
        if(!self->_mpv)return;
        if(!remove && self->_pendingNetworkHook){mpv_hook_continue(self->_mpv,self->_pendingNetworkHook.unsignedLongLongValue);self->_pendingNetworkHook=nil;}
        id playlist=[self property:@"playlist"];
        if(![playlist isKindOfClass:NSArray.class])return;
        for(NSUInteger i=0;i<[playlist count];i++) {
            NSDictionary *entry=playlist[i];
            if([entry[@"id"] longLongValue]!=entryID)continue;
            // Removing an unrelated item must not strand a warming video paused.
            if(!remove || [entry[@"current"] boolValue] || [entry[@"filename"] isEqual:self->_recoveryKey]) {
                [self cancelRemoteRecovery];
                [self endScrubRestoringPlayback:YES];
                self->_splitDirty=NO; [self stopInteractionTimerIfIdle];
                [self cancelWarmupForFileChange];
            }
            [self send:@[remove?@"playlist-remove":@"playlist-play-index",@(i).stringValue]];
            self->_observed[@"playlist"]=[self property:@"playlist"];
            [self poll];break;
        }
    });
}
- (void)playPlaylistID:(int64_t)entryID { [self mutatePlaylistID:entryID remove:NO]; }
- (void)removePlaylistID:(int64_t)entryID { [self mutatePlaylistID:entryID remove:YES]; }
- (void)reorderPlaylist:(NSArray<NSNumber *> *)ids expectedNextRevision:(uint64_t)revision {
    if(_closed)return;
    dispatch_async(_queue, ^{
        if(!self->_mpv || revision!=self->_remoteNextRevision)return;
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
- (void)setRIFEPerformanceState:(NSDictionary<NSString *, NSString *> *)state {
    if(_closed)return;
    NSDictionary *copy=[state copy];
    dispatch_async(_queue,^{ self->_rifePerformanceState=copy; });
}
- (void)applyFilters:(NSArray<NSString *> *)filters shader:(NSString *)shader {
    if(_closed)return;
    dispatch_async(_queue,^{
        if(!self->_mpv)return;
        // Do not erase a network/open failure when idle filters are refreshed.
        if(self->_fileLoaded)self->_error=nil;
        BOOL changed=![self->_filters isEqual:filters];
        BOOL shaderChanged=![self->_shader isEqual:shader]&&(shader||self->_shader);
        BOOL firstPlan=self->_fileLoaded && self->_switchTiming.epoch && !self->_switchTiming.plan_seen;
        if(firstPlan) {
            self->_switchTiming.plan_seen=true;self->_switchTiming.plan_changed=changed||shaderChanged;
            self->_switchTiming.plan=NSProcessInfo.processInfo.systemUptime;
        }
        NSString *tier=changed&&!shaderChanged&&self->_warmState==IIVEWarmIdle ? IIVERIFETierOnlyChange(self->_filters,filters) : nil;
        if(tier && [self send:@[@"vf-command",@"iive-rife",@"tier",tier]]>=0) {
            // Worker applies the command at a pair boundary. Keep decoder,
            // playback clock, ready frames and audio running; no seek/pause.
            self->_filters=[filters copy];self->_rifeTierCommands++;
            return;
        }
        id paused=[self property:@"pause"];
        if(changed||shaderChanged) {
            BOOL resume=self->_warmState==IIVEWarmResume || (self->_warmState==IIVEWarmIdle &&
                [paused isKindOfClass:NSNumber.class] && ![paused boolValue]);
            self->_warmState=resume?IIVEWarmResume:IIVEWarmStayPaused;
            self->_warmDeadline=NSProcessInfo.processInfo.systemUptime+20;
            if(firstPlan)self->_switchTiming.warm_start=NSProcessInfo.processInfo.systemUptime;
            if([self send:@[@"set",@"pause",@"yes"]]>=0)self->_observed[@"pause"]=@YES;
            else self->_warmState=IIVEWarmIdle;
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
            if([pts isKindOfClass:NSNumber.class] && [self send:@[@"seek",[pts stringValue],@"absolute+exact"]]>=0)self->_filterRebuildSeeks++;
        }
        if(![self->_shader isEqual:shader] && (shader || self->_shader)) {
            if(self->_shader)[self send:@[@"change-list",@"glsl-shaders",@"remove",self->_shader]];
            if(shader)[self send:@[@"change-list",@"glsl-shaders",@"append",shader]];
            self->_shader=[shader copy];
        }
    });
}
static NSString *anonymizedMediaID(id rawPath) {
    if (![rawPath isKindOfClass:NSString.class] || ![rawPath length]) return @"";
    const uint8_t *bytes = (const uint8_t *)[rawPath UTF8String];
    uint64_t hash = 1469598103934665603ULL;
    for (size_t i = 0; bytes && bytes[i]; i++) { hash ^= (uint64_t)bytes[i]; hash *= 1099511628211ULL; }
    return [NSString stringWithFormat:@"media-%016llx", (unsigned long long)hash];
}
static NSDictionary *filteredParamsDictionary(id raw, NSArray<NSString *> *keys) {
    if (![raw isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *k in keys) if (raw[k] != nil) out[k] = raw[k];
    return out;
}
static NSArray *sanitizedFilterList(id rawVF) {
    if (![rawVF isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *list = [NSMutableArray array];
    for (id item in (NSArray *)rawVF) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        for (NSString *k in @[@"label", @"name", @"enabled"]) if (item[k] != nil) entry[k] = item[k];
        if ([item[@"params"] isKindOfClass:NSDictionary.class]) {
            NSMutableDictionary *params = [NSMutableDictionary dictionary];
            [(NSDictionary *)item[@"params"] enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *s) {
                params[k] = ([v isKindOfClass:NSString.class] && [(NSString *)v containsString:@"/"]) ? @"<redacted-path>" : v;
            }];
            entry[@"params"] = params;
        }
        [list addObject:entry];
    }
    return list;
}
- (NSDictionary *)sanitizedMetricsRecordFromSnapshot:(NSDictionary *)s {
    NSMutableDictionary *rec = [NSMutableDictionary dictionary];
    rec[@"metrics-schema"] = s[@"metrics-schema"] ?: @2;
    rec[@"performance-sample"] = s[@"performance-sample"] ?: @NO;
    rec[@"media-id"] = anonymizedMediaID(s[@"path"]);
    for (NSString *k in @[@"seekable",@"paused-for-cache",@"network-reconnecting",@"network-retry-attempt",@"cache-buffering-state",@"demuxer-cache-duration",@"monotonic_s",@"playback-phase",@"media-loaded",@"media-switch-timing",@"media-switch-history-overwritten",@"pause",@"engine-paused",@"enhancement-warming",@"seeking",@"eof-reached",@"speed",@"time-pos",@"duration",@"hwdec",@"hwdec-current",@"video-codec",@"container-fps",@"estimated-vf-fps",@"frame-drop-count",@"decoder-frame-drop-count",@"avsync",@"video-bitrate",@"audio-bitrate",@"osd-dimensions",@"viewport-width",@"viewport-height",@"vo-passes",@"iive-rife",@"iive-fi",@"iive-sr",@"render-timing",@"render-callback-fps",@"display-fps",@"iive-scrub-seeks",@"iive-split-refresh-seeks",@"iive-seek-coalesced",@"iive-seek-queue-ms",@"iive-seek-command-ms",@"process-cpu-percent",@"process-memory-bytes",@"process-peak-sampled-footprint-bytes",@"process-resident-bytes",@"process-gpu-percent",@"apple-fi-supported",@"apple-sr-scales"])
        rec[k] = s[k] ?: NSNull.null;
    rec[@"video-params"] = filteredParamsDictionary(s[@"video-params"], @[@"w",@"h",@"dw",@"dh",@"pixelformat",@"hw-subformat",@"primaries",@"gamma",@"colormatrix",@"colorlevels",@"rotate"]);
    rec[@"video-out-params"] = filteredParamsDictionary(s[@"video-out-params"], @[@"w",@"h",@"dw",@"dh",@"pixelformat",@"hw-subformat",@"primaries",@"gamma",@"colormatrix",@"colorlevels"]);
    rec[@"vf"] = sanitizedFilterList(s[@"vf"]);
    rec[@"rife-performance-policy"] = s[@"rife-performance-policy"] ?: NSNull.null;
    rec[@"iive-rife-tier-commands"] = s[@"iive-rife-tier-commands"] ?: @0;
    rec[@"iive-filter-rebuild-seeks"] = s[@"iive-filter-rebuild-seeks"] ?: @0;
    return rec;
}
- (void)setDetailedTelemetryEnabled:(BOOL)enabled {
    dispatch_async(_queue,^{
        if(self->_detailedTelemetry==enabled)return;
        self->_detailedTelemetry=enabled;
        // Never carry a CPU sampling interval across a hidden/visible gap.
        // A recording already has a continuous interval and keeps it intact.
        if(!self->_metrics){self->_resources=nil;self->_resourceTime=0;}
        self->_bitrates=nil;
    });
}
- (NSDictionary *)resourceSnapshot {
    if(!_detailedTelemetry && !_metrics)return @{};
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
        _peakFootprint=MAX(_peakFootprint,memory.ri_phys_footprint);
        sample[@"process-peak-sampled-footprint-bytes"]=@(_peakFootprint);
        sample[@"process-resident-bytes"]=@(memory.ri_resident_size);
    }
    _resourceTime=now;_resources=sample;
    return sample;
}
// All recovery state belongs to the mpv client queue. Holding the end hook
// prevents automatic playlist advancement from racing a delayed retry.
- (void)cancelRemoteRecovery {
    _recoverAfterEnd=NO;_restoreRemote=NO;_forcedRemoteRecovery=NO;_remoteReadFailure=NO;
    _remoteFailed=NO;_manualRemoteRetry=NO;
    _recoveryKey=nil;_recoveryOptions=nil;_recoveryAttempts=0;_remotePosition=0;
    if(_pendingRecoveryHook && _mpv)mpv_hook_continue(_mpv,_pendingRecoveryHook.unsignedLongLongValue);
    _pendingRecoveryHook=nil;
}
- (void)retryNetworkPlaybackForPath:(NSString *)path {
    if(_closed)return;
    dispatch_async(_queue,^{
        // Resolve the opaque entry again; never reuse an expired download URL.
        // A stale UI action must not restart an item after navigation/removal.
        if(!self->_mpv || !self->_remoteFailed || ![path isEqual:self->_recoveryKey])return;
        NSArray *entries=[self property:@"playlist"];
        if(![entries isKindOfClass:NSArray.class])return;
        for(NSUInteger i=0;i<entries.count;i++)if([entries[i][@"filename"] isEqual:path]) {
            self->_remoteFailed=NO;self->_manualRemoteRetry=YES;
            self->_restoreRemote=YES;self->_recoveryAttempts=0;
            self->_remoteReadFailure=NO;self->_error=nil;self->_pendingNetworkError=nil;
            [self endScrubRestoringPlayback:YES];[self cancelWarmupForFileChange];
            [self send:@[@"playlist-play-index",@(i).stringValue]];
            return;
        }
        [self cancelRemoteRecovery];
    });
}
- (void)handleRemoteEndHook:(uint64_t)ticket {
    if(!_recoverAfterEnd || !_recoveryKey || _recoveryAttempts>=2) {
        // Release the hook into idle, not auto-next, after a terminal failure.
        // Keep the queue and in-memory checkpoint available for manual retry.
        if(_remoteFailed && _recoveryKey)[self send:@[@"stop",@"keep-playlist"]];
        _recoverAfterEnd=NO;mpv_hook_continue(_mpv,ticket);return;
    }
    _recoverAfterEnd=NO;_pendingRecoveryHook=@(ticket);_recoveryAttempts++;_error=nil;
    NSString *key=_recoveryKey;
    uint64_t generation=atomic_load_explicit(&_seekGeneration,memory_order_relaxed);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(_recoveryAttempts==1?1:3)*NSEC_PER_SEC),_queue,^{
        if(!self->_mpv || ![self->_pendingRecoveryHook isEqual:@(ticket)])return;
        self->_pendingRecoveryHook=nil;
        if(generation==atomic_load_explicit(&self->_seekGeneration,memory_order_relaxed) && [self->_recoveryKey isEqual:key]) {
            NSArray *entries=[self property:@"playlist"];
            if([entries isKindOfClass:NSArray.class])for(NSUInteger i=0;i<entries.count;i++) {
                if([entries[i][@"filename"] isEqual:key]) {
                    self->_restoreRemote=YES;
                    [self send:@[@"playlist-play-index",@(i).stringValue]];break;
                }
            }
        }
        mpv_hook_continue(self->_mpv,ticket);
    });
}
- (void)drainEvents {
    while(_mpv) {
        mpv_event *e=mpv_wait_event(_mpv,0);
        if(e->event_id==MPV_EVENT_NONE)break;
        if(e->event_id==MPV_EVENT_HOOK) {
            mpv_event_hook *hook=e->data;
            if(strcmp(hook->name,"on_after_end_file")==0){[self handleRemoteEndHook:hook->id];continue;}
            // Per-media controls must never leak to the next queue item (even
            // if two entries have the same path). on_load precedes decoding.
            NSDictionary *presentationDefaults=@{@"ab-loop-a":@"no",@"ab-loop-b":@"no",
                                                  @"video-aspect-override":@"no",@"video-crop":@""};
            _cropRatio=nil;
            for(NSString *name in presentationDefaults) {
                NSString *property=[@"file-local-options/" stringByAppendingString:name];
                mpv_set_property_string(_mpv,property.UTF8String,[presentationDefaults[name] UTF8String]);
                _observed[name]=[self property:name];
            }
            // Defaults first; local saved selections and remote reconnect state
            // are applied later by the corresponding load hook completion.
            for(NSString *name in _trackPreferences) {
                NSString *property=[@"file-local-options/" stringByAppendingString:name];
                mpv_set_property_string(_mpv,property.UTF8String,_trackPreferences[name].UTF8String);
            }
            NSString *key=[self property:@"path"];
            if([key isKindOfClass:NSString.class] && [key hasPrefix:@"iive-media://"] && self.onResolveNetwork) {
                if(![_recoveryKey isEqual:key]) {
                    _recoveryKey=[key copy];_recoveryAttempts=0;_remotePosition=0;_recoveryOptions=nil;
                }
                _remoteRetryable=YES;
                _remoteReadFailure=NO;
                _networkPrivacy=YES;_pendingNetworkHook=@(hook->id);
                uint64_t ticket=hook->id;
                dispatch_async(dispatch_get_main_queue(),^{if(!self->_closed && self.onResolveNetwork)self.onResolveNetwork(key,ticket);});
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,45*NSEC_PER_SEC),_queue,^{
                    if(self->_mpv && self->_pendingNetworkHook && self->_pendingNetworkHook.unsignedLongLongValue==ticket){
                        self->_remoteRetryable=NO;
                        self->_pendingNetworkError=@"Remote media preparation timed out. Check the connection, then reopen the file.";
                        self->_pendingNetworkHook=nil;mpv_hook_continue(self->_mpv,ticket);
                    }
                });
            } else if([key isKindOfClass:NSString.class] && [key hasPrefix:@"/"] && self.onPrepareLocal) {
                uint64_t ticket=hook->id;
                _pendingNetworkHook=@(ticket);
                dispatch_async(dispatch_get_main_queue(),^{if(!self->_closed && self.onPrepareLocal)self.onPrepareLocal(key,ticket);});
                // An unavailable mounted file must not strand mpv's load hook.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),_queue,^{
                    if(self->_mpv && [self->_pendingNetworkHook isEqual:@(ticket)]) {
                        self->_pendingNetworkHook=nil;mpv_hook_continue(self->_mpv,ticket);
                    }
                });
            } else { mpv_hook_continue(_mpv,hook->id); }
        } else if(e->event_id==MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *log=e->data;
            if(_recoveryKey && log->log_level<=MPV_LOG_LEVEL_WARN) {
                NSString *line=[@(log->text) lowercaseString];
                if([line containsString:@"error reading packet"] || [line containsString:@"http error 403"] ||
                   [line containsString:@"connection reset"] || [line containsString:@"connection timed out"])
                    _remoteReadFailure=YES;
            }
            if(log->log_level<=MPV_LOG_LEVEL_ERROR) {
                if(_networkPrivacy) {
                    // Demuxer probing and decoder fallback can emit error-level logs
                    // yet recover. Publish only an actual END_FILE failure; keep a
                    // sanitized reason for it without exposing signed URLs/headers.
                    NSString *text=[@(log->text) lowercaseString];
                    if([text containsString:@"http error 401"] || [text containsString:@"401 unauthorized"]) {
                        _remoteRetryable=NO;
                        _pendingNetworkError=@"Authentication rejected (HTTP 401). Reopen the server and check the saved account.";
                    }
                    else if([text containsString:@"http error 403"] || [text containsString:@"403 forbidden"])
                        _pendingNetworkError=@"Access denied (HTTP 403). Reopen the file to refresh its download link.";
                    else if([text containsString:@"http error 404"] || [text containsString:@"404 not found"] || [text containsString:@"http error 410"])
                        _pendingNetworkError=@"Media link is missing or expired. Browse the server and reopen the file.";
                    else if([text containsString:@"http error 429"] || [text containsString:@"429 too many requests"]) {
                        // The native log has no reliable Retry-After value. Do not
                        // amplify throttling with the automatic reconnect loop.
                        _remoteRetryable=NO;
                        _pendingNetworkError=@"Too many requests (HTTP 429). Wait before trying again.";
                    }
                    else if([text containsString:@"certificate verify"] || [text containsString:@"certificate verification"]) {
                        _remoteRetryable=NO;
                        _pendingNetworkError=@"TLS certificate verification failed. Check the server's certificate.";
                    }
                    else if([text containsString:@"timed out"] || [text containsString:@"timeout"])
                        _pendingNetworkError=@"The media server did not respond in time. Check the connection and try again.";
                    else if([text containsString:@"failed to resolve hostname"] || [text containsString:@"nodename nor servname"])
                        _pendingNetworkError=@"Cannot find the server. Check its address and your DNS or VPN connection.";
                    else if([text containsString:@"connection refused"])
                        _pendingNetworkError=@"Cannot connect to the server. Check its availability, port and VPN connection.";
                    else if([text containsString:@"connection reset"] || [text containsString:@"error reading packet"])
                        _pendingNetworkError=@"The connection was interrupted while reading. Restore the connection, then retry.";
                } else {
                    _error=[NSString stringWithFormat:@"%s: %s",log->prefix,log->text];
                }
            }
        } else if(e->event_id==MPV_EVENT_PROPERTY_CHANGE) {
            mpv_event_property *prop=e->data;
            if(prop && prop->name) {
                id value=(prop->format==MPV_FORMAT_NODE && prop->data)?object((mpv_node *)prop->data):NSNull.null;
                if(iive_property_needs_snapshot(prop->name,_observed[@(prop->name)],value,_fileLoaded,_mediaStarted))
                    _eventSnapshotNeeded=YES;
                if(strcmp(prop->name,"audio-device-list")==0 && ![_observed[@(prop->name)] isEqual:value])_audioDeviceFailed=NO;
                _observed[@(prop->name)]=value;
                if(strcmp(prop->name,"audio-device-list")==0)[self applyPreferredAudioDevice];
                if(strcmp(prop->name,"video-out-params")==0 && self->_cropRatio.length)[self applyCenterCrop];
                if(strcmp(prop->name,"current-ao")==0 && [value isEqual:@"null"] &&
                   !_audioDeviceFailed && ![_preferredAudioDevice isEqual:@"auto"] &&
                   [[self property:@"audio-device"] isEqual:_preferredAudioDevice] &&
                   [[self property:@"current-ao"] isEqual:@"null"]) {
                    _audioDeviceFailed=YES;[self applyPreferredAudioDevice];
                }
            }
        } else if(e->event_id==MPV_EVENT_FILE_LOADED) {
            _fileLoaded=YES;_mediaOpening=NO;_pendingNetworkError=nil;_manualRemoteRetry=NO;_remoteFailed=NO;
            iive_switch_first(&_switchTiming.loaded,NSProcessInfo.processInfo.systemUptime,_switchTiming.start);
            [_view beginMediaRenderObservation:_mediaEpoch];
        } else if(e->event_id==MPV_EVENT_PLAYBACK_RESTART) {
            _interactionWaiting=NO;_pendingNetworkError=nil;
            // A seek can restart an already-started file. Refresh its position
            // and readiness now rather than leaving stale UI for up to 250 ms.
            if(_fileLoaded || _warmState!=IIVEWarmIdle)_eventSnapshotNeeded=YES;
            if(_fileLoaded) {
                _mediaStarted=YES;
                iive_switch_first(&_switchTiming.restart,NSProcessInfo.processInfo.systemUptime,_switchTiming.start);
            }
        } else if(e->event_id==MPV_EVENT_START_FILE || e->event_id==MPV_EVENT_END_FILE) {
            if(e->event_id==MPV_EVENT_END_FILE && e->data) {
                mpv_event_end_file *end=e->data;
                _switchTiming.end=NSProcessInfo.processInfo.systemUptime;
                _switchTiming.failed=end->reason==MPV_END_FILE_REASON_ERROR;
                if(end->reason==MPV_END_FILE_REASON_ERROR)self->_error=_pendingNetworkError?:[NSString stringWithFormat:@"Unable to play media: %s",mpv_error_string(end->error)];
                _recoverAfterEnd=(_forcedRemoteRecovery || (end->reason==MPV_END_FILE_REASON_ERROR &&
                    (end->error==MPV_ERROR_LOADING_FAILED || end->error==MPV_ERROR_GENERIC))) && _remoteRetryable &&
                    _recoveryOptions!=nil && _recoveryAttempts<2;
                _remoteFailed=_recoveryKey && !_recoverAfterEnd &&
                    (_forcedRemoteRecovery || end->reason==MPV_END_FILE_REASON_ERROR);
                if(end->reason==MPV_END_FILE_REASON_ERROR)_manualRemoteRetry=NO;
                _forcedRemoteRecovery=NO;
            }
            _fileLoaded=NO;_mediaStarted=NO;_mediaOpening=(e->event_id==MPV_EVENT_START_FILE);
            _requestedResumePosition=0;_confirmedResumePosition=0;
            if(_mediaOpening){
                if(![[self property:@"path"] isEqual:_recoveryKey])[self cancelRemoteRecovery];
                if(_switchTiming.epoch) {
                    if(!_switchHistory)_switchHistory=[NSMutableArray array];
                    [_switchHistory addObject:[self mediaSwitchTimingSnapshot]];
                    if(_switchHistory.count>7){[_switchHistory removeObjectAtIndex:0];_switchHistoryOverwritten++;}
                }
                _mediaEpoch++;_error=nil;_pendingNetworkError=nil;
                _switchTiming=(struct iive_media_switch_timing){.epoch=_mediaEpoch,
                    .start=NSProcessInfo.processInfo.systemUptime,
                    .command=_pendingNavigationCount==1?_pendingNavigationTime:0,
                    .navigation_count=_pendingNavigationCount};
                _pendingNavigationCount=0;_pendingNavigationTime=0;
            }
            _splitDirty=NO; _interactionWaiting=NO;
            [self endScrubRestoringPlayback:YES];
            // Never let a previous file's warm completion resume another file.
            [self cancelWarmupForFileChange];
            if(e->event_id==MPV_EVENT_START_FILE){_captionEpoch++;[_view resetRenderTiming];}
        } else if(e->event_id==MPV_EVENT_SHUTDOWN) {
            dispatch_async(dispatch_get_main_queue(),^{[NSApp terminate:nil];});
            break;
        }
    }
}
- (NSDictionary *)mediaSwitchTimingSnapshot {
    struct iive_media_switch_timing t=_switchTiming;
    NSDictionary *render=[_view mediaRenderObservation];
    double submit=([render[@"epoch"] unsignedLongLongValue]==t.epoch &&
                   [render[@"fresh_submit_s"] isKindOfClass:NSNumber.class])?[render[@"fresh_submit_s"] doubleValue]:0;
    // Freeze once END_FILE is observed: subsequent redraws cannot complete it.
    if(t.end>0 && submit>t.end)submit=0;
    NSMutableDictionary *d=[@{@"epoch":@(t.epoch),@"start_observed_s":@(t.start),
        @"state":t.failed?@"failed":t.end>0?@"ended":t.restart>0?@"started":t.loaded>0?@"loaded":@"opening",
        @"navigation_commands_before_start":@(t.navigation_count),
        @"initial_plan_seen":@(t.plan_seen),@"initial_plan_changed":@(t.plan_changed),
        @"clock":@"system-uptime",@"scope":@"client-event observations; fresh GL submission after FILE_LOADED, not display presentation"} mutableCopy];
    NSDictionary *durations=@{
        @"candidate_command_to_start_ms":@(iive_switch_elapsed(t.command,t.start)),
        @"start_to_loaded_ms":@(iive_switch_elapsed(t.start,t.loaded)),
        @"loaded_to_restart_ms":@(iive_switch_elapsed(t.loaded,t.restart)),
        @"start_to_restart_ms":@(iive_switch_elapsed(t.start,t.restart)),
        @"loaded_to_initial_plan_ms":@(iive_switch_elapsed(t.loaded,t.plan)),
        @"initial_warmup_pause_ms":@(iive_switch_elapsed(t.warm_start,t.warm_end)),
        @"loaded_to_observed_fresh_submit_ms":@(iive_switch_elapsed(t.loaded,submit)),
        @"start_to_end_ms":@(iive_switch_elapsed(t.start,t.end))};
    for(NSString *key in durations)d[key]=isfinite([durations[key] doubleValue])?durations[key]:NSNull.null;
    return d;
}
- (void)poll {
    [self pollWithPerformanceSample:NO];
}
- (void)pollWithPerformanceSample:(BOOL)performanceSample {
    if(!_mpv)return;
    [self drainEvents];
    _eventSnapshotNeeded=NO;
    if(_captionHandler) {
        id meta=[self property:@"af-metadata/iive-captions"];
        if([meta isKindOfClass:NSDictionary.class]) {
            NSMutableDictionary *packet=[meta mutableCopy];
            packet[@"epoch"]=@(_captionEpoch);
            NSString *encoded=packet[@"pcm"];
            [packet removeObjectForKey:@"pcm"];
            if(encoded) {
                packet[@"data"]=[[NSData alloc] initWithBase64EncodedString:encoded options:0]?:NSData.data;
                NSString *ack=[NSString stringWithFormat:@"%@:%@",packet[@"serial"],packet[@"samples"]];
                [self send:@[@"af-command",@"iive-captions",@"ack",ack]];
            }
            _captionHandler(packet);
        }
    }
    NSMutableDictionary *s=[NSMutableDictionary dictionaryWithDictionary:[self resourceSnapshot]];
    [s addEntriesFromDictionary:_observed];
    // Extra lifecycle snapshots must not shorten sample-count based grace
    // periods or split drop deltas used by performance protection.
    s[@"performance-sample"]=@(performanceSample);
    s[@"remote-next-revision"]=@(_remoteNextRevision);
    s[@"iive-crop-ratio"]=_cropRatio?:@"";
    s[@"iive-audio-output-status"]=[_observed[@"current-ao"] isEqual:@"null"]?
        @"Audio output is unavailable. Select another device or reopen the media.":(_audioOutputStatus?:@"");
    for(NSString *key in @[@"time-pos",@"seeking",@"estimated-vf-fps",@"frame-drop-count",@"decoder-frame-drop-count",@"avsync"])
        s[key]=[self property:key];
    // Bitrate is descriptive, not a playback-control input. Preserve the full
    // recording cadence; otherwise sample at 1 Hz visible / 0.2 Hz hidden.
    double sampleTime=NSProcessInfo.processInfo.systemUptime;
    if(!_bitrates || _bitrateEpoch!=_mediaEpoch || _metrics ||
       sampleTime-_bitrateTime>=(_detailedTelemetry?1.0:5.0)) {
        _bitrates=@{@"video-bitrate":[self property:@"video-bitrate"],@"audio-bitrate":[self property:@"audio-bitrate"]};
        _bitrateTime=sampleTime;_bitrateEpoch=_mediaEpoch;
    }
    [s addEntriesFromDictionary:_bitrates];
    s[@"iive-seek-request-id"] = _seekRequestID ?: @"";
    s[@"iive-seek-command-result"] = @(_seekCommandResult);
    s[@"iive-seek-queue-ms"] = _seekRequestID ? @(_seekQueueMS) : NSNull.null;
    s[@"iive-seek-command-ms"] = _seekRequestID ? @(_seekCommandMS) : NSNull.null;
    s[@"iive-seek-coalesced"] = @(_coalescedSeeks);
    s[@"media-loaded"] = @(_fileLoaded);
    s[@"media-epoch"] = @(_mediaEpoch);
    s[@"media-started"] = @(_mediaStarted);
    if(_requestedResumePosition>5 && _fileLoaded && _mediaStarted && ![s[@"seeking"] isEqual:@YES] &&
       [s[@"time-pos"] isKindOfClass:NSNumber.class]) {
        if(fabs([s[@"time-pos"] doubleValue]-_requestedResumePosition)<=2.0)_confirmedResumePosition=_requestedResumePosition;
        _requestedResumePosition=0;
    }
    s[@"resume-position"] = _confirmedResumePosition>5 ? @(_confirmedResumePosition) : NSNull.null;
    s[@"media-opening"] = @(_mediaOpening);
    s[@"network-reconnecting"] = @(_manualRemoteRetry || _recoverAfterEnd || _forcedRemoteRecovery || _pendingRecoveryHook!=nil || _restoreRemote || (_mediaOpening && _recoveryAttempts>0));
    s[@"network-retry-attempt"] = @(_recoveryAttempts);
    s[@"network-retry-available"] = @(_remoteFailed && _recoveryKey!=nil);
    // Preserve logical media identity across the unloaded interval, so the UI
    // does not reset the per-file quality fallback to the user's higher tier.
    if(([s[@"network-reconnecting"] boolValue] || _remoteFailed) && _recoveryKey)s[@"path"]=_recoveryKey;
    // Keep a checkpoint only for seekable managed remote items. No URLs or
    // credentials enter diagnostics or persistence. Failed reloads retain it.
    if(_fileLoaded && [_recoveryKey isEqual:s[@"path"]] && [s[@"seekable"] isEqual:@YES] &&
       [s[@"time-pos"] isKindOfClass:NSNumber.class] && ![s[@"seeking"] isEqual:@YES] && ![s[@"eof-reached"] isEqual:@YES]) {
        _remotePosition=MAX(0,[s[@"time-pos"] doubleValue]);
        NSMutableDictionary *options=[NSMutableDictionary dictionary];
        options[@"pause"]=_warmState==IIVEWarmResume?@"no":(_warmState==IIVEWarmStayPaused?@"yes":([s[@"pause"] boolValue]?@"yes":@"no"));
        for(NSString *name in @[@"speed",@"aid",@"sid",@"secondary-sid"]) {
            id value=[self property:name];
            if([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class])options[name]=[value description];
        }
        _recoveryOptions=options;
    }
    // FFmpeg can surface an interrupted read as EOF rather than END_FILE/ERROR.
    // With keep-open, require both a read error and a clearly truncated, known
    // duration. Ordinary EOF, live streams, user seeks and pause never trigger it.
    double remoteDuration=[s[@"duration"] isKindOfClass:NSNumber.class]?[s[@"duration"] doubleValue]:0;
    if(_fileLoaded && !_scrubPath && !_forcedRemoteRecovery && _remoteReadFailure && _remoteRetryable && _recoveryOptions &&
       [_recoveryKey isEqual:s[@"path"]] && [s[@"eof-reached"] isEqual:@YES] && ![s[@"seeking"] isEqual:@YES] &&
       remoteDuration>0 && _remotePosition+MAX(2,remoteDuration*.005)<remoteDuration) {
        if(_recoveryAttempts<2) {
            _forcedRemoteRecovery=YES;
            [self send:@[@"stop",@"keep-playlist"]];
        } else {
            _error=@"Network playback stopped after two recovery attempts. Check the connection, then retry playback.";
            _remoteFailed=YES;
            _remoteReadFailure=NO;
        }
    }
    s[@"iive-scrub-seeks"] = @(_interactiveSeeks);
    s[@"iive-split-refresh-seeks"] = @(_splitRefreshSeeks);
    for(NSString *label in @[@"iive-rife",@"iive-fi",@"iive-sr"])
        s[label]=_filters.count?[self property:[@"vf-metadata/" stringByAppendingString:label]]:NSNull.null;
    BOOL dovi=NO;
    for(NSDictionary *track in ([s[@"track-list"] isKindOfClass:NSArray.class]?s[@"track-list"]:@[]))
        if([track[@"type"] isEqual:@"video"] && [track[@"selected"] boolValue] && track[@"dolby-vision-profile"])dovi=YES;
    NSDictionary *color=[s[@"video-params"] isKindOfClass:NSDictionary.class]?s[@"video-params"]:@{};
    dovi |= [color[@"colormatrix"] isEqual:@"dolbyvision"];
    id passes=(_shader || dovi)?[self property:@"vo-passes"]:nil;
    // Pass descriptions prove shader execution; omit large GPU sample histories.
    NSMutableArray *descriptions=[NSMutableArray array];
    if([passes isKindOfClass:NSDictionary.class])for(NSString *kind in @[@"fresh",@"redraw"])
        for(NSDictionary *pass in passes[kind])if(pass[@"desc"])[descriptions addObject:pass[@"desc"]];
    s[@"vo-passes"]=descriptions;
    NSSize viewport=[_view pixelSize];s[@"viewport-width"]=@(viewport.width);s[@"viewport-height"]=@(viewport.height);
    double luminance=[_view presentationLuminance];s[@"presentation-luminance"]=isfinite(luminance)?@(luminance):NSNull.null;
    double speed=[s[@"speed"] isKindOfClass:NSNumber.class]?[s[@"speed"] doubleValue]:1;
    if(speed!=_lastSpeed) {id filters=s[@"vf"];if([filters isKindOfClass:NSArray.class])for(NSDictionary *f in filters){NSString *label=f[@"label"];if([label isKindOfClass:NSString.class]&&[label hasPrefix:@"iive-"])[self send:@[@"vf-command",label,@"speed",@(speed).stringValue]];}_lastSpeed=speed;}
    uint64_t renders=[_view renderCount];double now=NSProcessInfo.processInfo.systemUptime;
    s[@"render-timing"]=[_view renderTiming];
    s[@"rife-performance-policy"]=_rifePerformanceState?:NSNull.null;
    s[@"iive-rife-tier-commands"]=@(_rifeTierCommands);
    s[@"iive-filter-rebuild-seeks"]=@(_filterRebuildSeeks);
    s[@"metrics-schema"]=@2;
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
    if(_warmState!=IIVEWarmIdle) {
        BOOL ready=YES;
        for(NSString *f in _filters) {
            NSString *label=[[f componentsSeparatedByString:@":"] firstObject];
            if([label hasPrefix:@"@"])label=[label substringFromIndex:1];
            id meta=s[label];
            if(![meta isKindOfClass:NSDictionary.class] || !meta[@"state"] ||
               [@[@"warming",@"seek-preroll"] containsObject:meta[@"state"]])ready=NO;
        }
        if(ready || now>_warmDeadline) {
            if(_warmState==IIVEWarmResume && [self send:@[@"set",@"pause",@"no"]]>=0)_observed[@"pause"]=@NO;
            iive_switch_first(&_switchTiming.warm_end,now,_switchTiming.warm_start);
            _warmState=IIVEWarmIdle;
        }
    }
    s[@"engine-paused"]=_observed[@"pause"]?:NSNull.null;
    s[@"enhancement-warming"]=@(_warmState!=IIVEWarmIdle);
    s[@"pause"]=_warmState==IIVEWarmResume?@NO:_observed[@"pause"]?:NSNull.null;
    s[@"playback-phase"]=_warmState==IIVEWarmResume?@"warming-play":_warmState==IIVEWarmStayPaused?@"warming-paused":
        [s[@"pause"] isEqual:@YES]?@"paused":@"playing";
    NSMutableArray *switches=[_switchHistory mutableCopy]?:[NSMutableArray array];
    if(_switchTiming.epoch)[switches addObject:[self mediaSwitchTimingSnapshot]];
    s[@"media-switch-timing"]=switches;
    s[@"media-switch-history-overwritten"]=@(_switchHistoryOverwritten);
    if(_metrics){
        NSDictionary *record=[self sanitizedMetricsRecordFromSnapshot:s];
        NSData *json=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
        if(json){
            @try { [_metrics writeData:json]; [_metrics writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]]; _metricsSamples++; }
            @catch (NSException *e) { @try { [_metrics closeFile]; } @catch (NSException *i) {} _metrics=nil;_metricsPath=nil; }
        }
    }
    s[@"metrics-recording"]=@(_metrics!=nil);
    s[@"metrics-samples"]=@(_metricsSamples);
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
- (void)loadSubtitle:(NSString *)path secondary:(BOOL)secondary {
    if(_closed)return;
    dispatch_async(_queue, ^{
        if(!self->_mpv)return;
        id original=[self property:@"path"];
        id before=[self property:@"track-list"];
        NSMutableSet *ids=[NSMutableSet set];
        if([before isKindOfClass:NSArray.class])for(NSDictionary *track in before)
            if([track[@"type"] isEqual:@"sub"] && track[@"id"])[ids addObject:track[@"id"]];
        if([self send:@[@"sub-add",path,@"auto"]]<0 || ![[self property:@"path"] isEqual:original])return;
        id after=[self property:@"track-list"];
        if([after isKindOfClass:NSArray.class])for(NSDictionary *track in after) {
            if([track[@"type"] isEqual:@"sub"] && track[@"id"] && ![ids containsObject:track[@"id"]]) {
                [self send:@[@"set",secondary?@"secondary-sid":@"sid",[track[@"id"] stringValue]]];break;
            }
        }
    });
}
- (void)setCaptionAudioEnabled:(BOOL)enabled handler:(void (^)(NSDictionary *))handler {
    if(_closed)return;
    dispatch_async(_queue, ^{
        if(!self->_mpv)return;
        self->_captionHandler=nil;
        id filters=[self property:@"af"];
        if([filters isKindOfClass:NSArray.class])for(NSDictionary *filter in filters)
            if([filter[@"label"] isEqual:@"iive-captions"])[self send:@[@"af",@"remove",@"@iive-captions"]];
        self->_captionEpoch++;
        if(enabled) {
            if([self send:@[@"af",@"pre",@"@iive-captions:iive-captions"]]>=0)self->_captionHandler=[handler copy];
            else if(handler)handler(@{@"state":@"tap-unavailable"});
        }
    });
}
- (nullable NSString *)activeMetricsPath {
    __block NSString *path=nil; if(_closed)return nil;
    dispatch_sync(_queue,^{ path=[self->_metricsPath copy]; }); return path;
}
- (void)closeMetricsOnQueue {
    if(_metrics){ @try { [_metrics synchronizeFile]; [_metrics closeFile]; } @catch (NSException *i) {} _metrics=nil; }
    _metricsPath=nil; _metricsSamples=0;
}
- (void)startMetricsRecordingToPath:(NSString *)path completion:(void (^)(NSString * _Nullable))completion {
    if(_closed){ dispatch_async(dispatch_get_main_queue(),^{ completion(@"Playback session is closed."); }); return; }
    NSString *target=[path copy];
    dispatch_async(_queue,^{
        [self closeMetricsOnQueue];
        int fd=open([target fileSystemRepresentation],O_WRONLY|O_CREAT|O_EXCL,0600);
        if(fd<0){ NSString *err=[NSString stringWithFormat:@"Unable to create metrics file (%s).",strerror(errno)]; dispatch_async(dispatch_get_main_queue(),^{ completion(err); }); return; }
        self->_metrics=[[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
        self->_metricsPath=target; self->_metricsSamples=0; self->_peakFootprint=0; self->_resources=nil; self->_resourceTime=0;
        [self->_view resetRenderTiming]; [self poll];
        dispatch_async(dispatch_get_main_queue(),^{ completion(nil); });
    });
}
- (void)stopMetricsRecordingWithCompletion:(void (^)(NSInteger, NSString * _Nullable))completion {
    if(_closed){ dispatch_async(dispatch_get_main_queue(),^{ completion(0,nil); }); return; }
    dispatch_async(_queue,^{
        NSInteger count=self->_metricsSamples; NSString *saved=[self->_metricsPath copy];
        [self closeMetricsOnQueue]; [self poll];
        dispatch_async(dispatch_get_main_queue(),^{ completion(count,saved); });
    });
}
- (void)shutdown {
    if(_closed)return;_closed=YES;self.onSnapshot=nil;self.onResolveNetwork=nil;
    if(_timer)dispatch_source_cancel(_timer);
    // Drain client calls while render updates still service advanced controls.
    dispatch_sync(_queue,^{
        // mpv's pinned implementation serializes unregister with its wakeup lock.
        // Keep userdata alive until unregister returns; queued handlers see closed.
        if(self->_mpv)mpv_set_wakeup_callback(self->_mpv,NULL,NULL);
        if(self->_eventWakeup){dispatch_source_cancel(self->_eventWakeup);self->_eventWakeup=nil;}
        [self cancelRemoteRecovery];if(self->_mpv && self->_pendingNetworkHook){mpv_hook_continue(self->_mpv,self->_pendingNetworkHook.unsignedLongLongValue);self->_pendingNetworkHook=nil;}if(self->_interactionTimer){dispatch_source_cancel(self->_interactionTimer);self->_interactionTimer=nil;}
    });
    [_view stopRenderer];
    dispatch_sync(_queue,^{if(self->_mpv){mpv_terminate_destroy(self->_mpv);self->_mpv=NULL;}self->_captionHandler=nil;[self closeMetricsOnQueue];});
}
@end
