// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <stdatomic.h>
#import "HDRFrame.h"
#import <AVKit/AVKit.h>
#include "HDRClock.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

typedef struct { float headroom,phase,referenceWhite; uint32_t animate; float imageAspect,displayAspect,chromaOffsetX; uint32_t hlg; } HDRUniforms;

static id<MTLRenderPipelineState> HDRCreatePipeline(id<MTLDevice> device, NSString *fragment, NSError **error) {
    NSString *path=[[NSBundle mainBundle] pathForResource:@"Pattern" ofType:@"metal"];
    NSString *source=path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:error] : nil;
    id<MTLLibrary> library=source ? [device newLibraryWithSource:source options:nil error:error] : nil;
    MTLRenderPipelineDescriptor *desc=[MTLRenderPipelineDescriptor new];
    desc.vertexFunction=[library newFunctionWithName:@"hdrVertex"];
    desc.fragmentFunction=[library newFunctionWithName:fragment];
    desc.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA16Float;
    if(desc.vertexFunction && desc.fragmentFunction) return [device newRenderPipelineStateWithDescriptor:desc error:error];
    return nil;
}

@interface HDRView : NSView {
    CAMetalLayer *_metal;
    id<MTLCommandQueue> _commands;
    id<MTLRenderPipelineState> _pipeline, _videoPipeline;
    HDRFrame *_frame;
    NSURL *_selectedURL;
    AVPlayerView *_systemView;
    AVPlayer *_systemPlayer;
    HDRStream *_stream;
    NSMutableArray<HDRFrame *> *_frames;
    NSUInteger _mediaGeneration, _lateFrames;
    BOOL _reading, _eof, _awaitingFirst, _occluded;
    double _duration, _lastInterval, _lastTitleUpdate;
    HDRClock _clock;
    NSString *_filename;
    BOOL _loading, _inputFailed, _forceMetal;
    NSString *_systemRouteLabel;
    NSString *_inputStatus;
    dispatch_queue_t _presentQueue;
    dispatch_semaphore_t _capacity;
    NSTimer *_timer;
    atomic_uint_fast64_t _generation;
    NSUInteger _ticks, _completed, _skipped;
    CGSize _lastSize;
    CGFloat _lastHeadroom;
    BOOL _paused, _stopped, _dirty;
    NSString *_error;
}
- (void)stop;
- (void)openVideo;
- (void)openSystemVideo;
- (void)openMetalVideo;
- (void)returnToPattern;
@end
@implementation HDRView
- (instancetype)initWithFrame:(NSRect)frame {
    if(!(self=[super initWithFrame:frame])) return nil;
    atomic_init(&_generation,1);
    _presentQueue=dispatch_queue_create("com.august.lumaplayer.hdr-prototype.present",DISPATCH_QUEUE_SERIAL);
    _capacity=dispatch_semaphore_create(2);
    self.wantsLayer=YES;
    _metal=[CAMetalLayer layer]; self.layer=_metal;
    _metal.device=MTLCreateSystemDefaultDevice();
    _metal.pixelFormat=MTLPixelFormatRGBA16Float;
    _metal.wantsExtendedDynamicRangeContent=YES;
    _metal.maximumDrawableCount=2;
    _metal.allowsNextDrawableTimeout=YES;
    _metal.framebufferOnly=YES;
    CGColorSpaceRef cs=CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    _metal.colorspace=cs; CGColorSpaceRelease(cs);
    _commands=[_metal.device newCommandQueue];
    NSError *error=nil;
    _pipeline=HDRCreatePipeline(_metal.device,@"hdrPattern",&error);
    _videoPipeline=HDRCreatePipeline(_metal.device,@"hdrVideo",&error);
    if(!_pipeline || !_videoPipeline || !_commands) _error=error.localizedDescription ?: @"Metal device or pipeline unavailable";
    _dirty=YES;_frames=[NSMutableArray array];_lastInterval=1.0/24.0;
    __weak HDRView *weakSelf=self;
    _timer=[NSTimer timerWithTimeInterval:1.0/30.0 repeats:YES block:^(NSTimer *timer){ (void)timer; [weakSelf tick]; }];
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    return self;
}
- (void)fillFrames {
    if(!_stream || _inputFailed || _reading || _loading || _eof || _frames.count>=3 || _stopped)return;
    _reading=YES;
    NSUInteger generation=_mediaGeneration;
    [_stream readNext:^(HDRFrame *frame,NSError *error,BOOL eof){
        dispatch_async(dispatch_get_main_queue(), ^{
            if(generation!=self->_mediaGeneration || self->_stopped)return;
            self->_reading=NO;
            if(error) { [self reportInputError:error];return; }
            if(frame.hlg && !self->_forceMetal && self->_selectedURL) {
                [self playSystemURL:self->_selectedURL];
                self->_systemRouteLabel=@"HLG source · System AVKit";
                return;
            }
            if(frame)[self->_frames addObject:frame];
            self->_eof=eof;
            [self fillFrames];
        });
    }];
}
- (void)seekVideo:(double)position {
    if(!_stream)return;
    _mediaGeneration++;NSUInteger generation=_mediaGeneration;
    atomic_fetch_add(&_generation,1);
    [_frames removeAllObjects];_reading=NO;_eof=NO;_awaitingFirst=YES;_loading=YES;_inputFailed=NO;
    _inputStatus=@"Opening / seeking HDR…";
    hdr_clock_set(&_clock,position,CACurrentMediaTime(),false);
    [_stream seekTo:position completion:^(double duration,NSError *error){
        dispatch_async(dispatch_get_main_queue(), ^{
            if(generation!=self->_mediaGeneration || self->_stopped)return;
            self->_loading=NO;
            if(error) { [self reportInputError:error];return; }
            self->_duration=duration;self->_inputStatus=nil;
            [self fillFrames];
        });
    }];
}
- (void)reportInputError:(NSError *)error {
    if(error.code==2 && [error.domain isEqualToString:@"com.august.lumaplayer.hdrprototype"] && _selectedURL) {
        [self playSystemURL:_selectedURL];_systemRouteLabel=@"Dolby Vision source · System AVKit";return;
    }
    _loading=NO;_inputFailed=YES;_paused=YES;_awaitingFirst=NO;
    _inputStatus=error.localizedDescription ?: @"Video could not be opened.";
    hdr_clock_run(&_clock,CACurrentMediaTime(),false);
    [_frames removeAllObjects];
    NSAlert *alert=[NSAlert new];
    alert.messageText=@"Cannot open HDR video";
    alert.informativeText=[_inputStatus stringByAppendingString:@"\n\nThis independent prototype uses AVFoundation and accepts tagged PQ or HLG HDR video. Container support differs from Luma Player. Try a supported HDR MP4 or MOV; MKV is not generally supported by this decoder."];
    [alert addButtonWithTitle:@"OK"];
    if(self.window && !self.window.attachedSheet) [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response){
        (void)response;[self.window makeFirstResponder:self];
    }];
}
- (void)endSystemPlayback {
    [_systemPlayer pause];[_systemPlayer replaceCurrentItemWithPlayerItem:nil];
    _systemView.player=nil;[_systemView removeFromSuperview];_systemView=nil;_systemPlayer=nil;
}
- (void)returnToPattern {
    [self endSystemPlayback];[_stream cancel];_stream=nil;_mediaGeneration++;[_frames removeAllObjects];
    _loading=NO;_inputFailed=NO;_frame=nil;_inputStatus=nil;_paused=NO;_dirty=YES;
    atomic_fetch_add(&_generation,1);[self.window makeFirstResponder:self];
}
- (void)playSystemURL:(NSURL *)url {
    if(_stopped)return;
    [self returnToPattern];_paused=YES;
    _selectedURL=url;_filename=url.lastPathComponent;_systemRouteLabel=@"System AVKit";
    _systemPlayer=[AVPlayer playerWithURL:url];
    _systemView=[[AVPlayerView alloc] initWithFrame:self.bounds];
    _systemView.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    _systemView.controlsStyle=AVPlayerViewControlsStyleFloating;
    _systemView.player=_systemPlayer;
    [self addSubview:_systemView];
    [_systemPlayer play];
}
- (void)openVideo { [self chooseVideoUsingSystem:NO metalPreview:NO]; }
- (void)openSystemVideo { [self chooseVideoUsingSystem:YES metalPreview:NO]; }
- (void)openMetalVideo { [self chooseVideoUsingSystem:NO metalPreview:YES]; }
- (void)chooseVideoUsingSystem:(BOOL)system metalPreview:(BOOL)metalPreview {
    if(_stopped || self.window.attachedSheet)return;
    if(_error && !system) { [self reportInputError:[NSError errorWithDomain:@"HDRPrototype" code:1 userInfo:@{NSLocalizedDescriptionKey:_error}]];return; }
    NSOpenPanel *panel=[NSOpenPanel openPanel];
    panel.allowedContentTypes=@[UTTypeMovie,UTTypeData];panel.allowsMultipleSelection=NO;
    panel.canChooseDirectories=NO;panel.canChooseFiles=YES;panel.prompt=@"Open Video";
    panel.message=system?@"System AVKit playback with audio. HDR and Dolby Vision support depends on macOS, display and the file profile.":metalPreview?@"Diagnostic Metal preview, no audio. HLG brightness is not validated and may be too bright. Dolby Vision still uses AVKit.":@"HLG and detected Dolby Vision use system AVKit with audio. PQ uses the experimental Metal path without audio.";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response){
        [self.window makeFirstResponder:self];
        if(response!=NSModalResponseOK || self->_stopped)return;
        self->_selectedURL=panel.URL;self->_forceMetal=metalPreview;
        if(system) { [self playSystemURL:panel.URL];return; }
        [self endSystemPlayback];[self->_stream cancel];self->_frame=nil;
        self->_stream=[[HDRStream alloc] initWithURL:panel.URL device:self->_metal.device];
        self->_filename=panel.URL.lastPathComponent;self->_paused=NO;self->_lateFrames=0;
        [self seekVideo:0];
    }];
}
- (void)advanceVideo:(double)now {
    if(!_stream || _loading || _inputFailed)return;
    if(_awaitingFirst && _frames.count) {
        _frame=_frames.firstObject;[_frames removeObjectAtIndex:0];
        _awaitingFirst=NO;_dirty=YES;
        hdr_clock_set(&_clock,_frame.pts,now,!_paused);
    }
    if(_awaitingFirst && _eof && !_frames.count) {
        _awaitingFirst=NO;_paused=YES;_inputStatus=@"No frame at this position — ←: seek back";
    }
    if(!_paused && !_awaitingFirst) {
        double target=hdr_clock_time(_clock,now);NSUInteger consumed=0;
        while(_frames.count && _frames.firstObject.pts<=target+0.0005) {
            HDRFrame *next=_frames.firstObject;
            _lastInterval=fmax(0.001,fmin(0.5,next.pts-_frame.pts));
            _frame=next;[_frames removeObjectAtIndex:0];_dirty=YES;consumed++;
        }
        if(consumed>1)_lateFrames+=consumed-1;
        if(_eof && !_frames.count && (!_frame || target>=_frame.pts+_lastInterval)) {
            _paused=YES;hdr_clock_run(&_clock,now,false);_inputStatus=@"End of video — Space: replay";
        }
    }
    [self fillFrames];
}
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event {
    if(event.keyCode==31) { [self openVideo]; }
    else if(event.keyCode==15) {
        [self returnToPattern];
    } else if(event.keyCode==49) {
        if(_inputFailed) { [self openVideo];return; }
        if(_stream && _eof && !_frames.count && _paused) { _paused=NO;[self seekVideo:0];return; }
        _paused=!_paused;hdr_clock_run(&_clock,CACurrentMediaTime(),!_paused && !_awaitingFirst);
        _dirty=YES;atomic_fetch_add(&_generation,1);
    } else if((event.keyCode==123 || event.keyCode==124) && _stream) {
        double target=fmax(0,hdr_clock_time(_clock,CACurrentMediaTime())+(event.keyCode==123?-5:5));
        if(_duration>0)target=fmin(target,fmax(0,_duration-0.001));
        [self seekVideo:target];
    } else if(event.keyCode==53) { [self.window close]; }
    else [super keyDown:event];
}
- (void)tick {
    NSAssert(NSThread.isMainThread,@"UI snapshots belong to main thread");
    if(_stopped || !self.window) return;
    if(_systemView) {
        if(CACurrentMediaTime()-_lastTitleUpdate>=0.25) {
            _lastTitleUpdate=CACurrentMediaTime();
            self.window.title=[NSString stringWithFormat:@"%@ • %@ • HDR eligible: %@ • audio on • no enhancements",_filename,_systemRouteLabel,AVPlayer.eligibleForHDRPlayback?@"yes":@"no"];
        }
        if(_systemPlayer.currentItem.status==AVPlayerItemStatusFailed && !_inputFailed) {
            [self reportInputError:_systemPlayer.currentItem.error ?: [NSError errorWithDomain:@"SystemPlayback" code:1 userInfo:@{NSLocalizedDescriptionKey:@"System player could not decode this file/profile."}]];
        }
        return;
    }
    if(_error) { self.window.title=[@"HDR Prototype — " stringByAppendingString:_error]; return; }
    if(!(self.window.occlusionState & NSWindowOcclusionStateVisible) || self.window.miniaturized) {
        if(!_occluded) { hdr_clock_run(&_clock,CACurrentMediaTime(),false);_occluded=YES; }
        atomic_fetch_add(&_generation,1); _dirty=YES; return;
    }
    if(_occluded) { _occluded=NO;hdr_clock_run(&_clock,CACurrentMediaTime(),!_paused && !_awaitingFirst); }
    [self advanceVideo:CACurrentMediaTime()];
    NSScreen *screen=self.window.screen;
    CGFloat scale=self.window.backingScaleFactor;
    CGSize size=CGSizeMake(floor(self.bounds.size.width*scale),floor(self.bounds.size.height*scale));
    if(size.width<1 || size.height<1) return;
    CGFloat headroom=fmax(1.0,screen.maximumExtendedDynamicRangeColorComponentValue);
    if(!CGSizeEqualToSize(size,_lastSize) || fabs(headroom-_lastHeadroom)>0.01) {
        atomic_fetch_add(&_generation,1);
        _metal.contentsScale=scale; _metal.drawableSize=size;
        _lastSize=size; _lastHeadroom=headroom; _dirty=YES;
    }
    if(_dirty || CACurrentMediaTime()-_lastTitleUpdate>=0.25) {
        _lastTitleUpdate=CACurrentMediaTime();
    self.window.title=[NSString stringWithFormat:@"HDR PQ test • EDR %.2f× • GPU completed %lu • skipped %lu • Space: pause • Esc: close",headroom,(unsigned long)_completed,(unsigned long)_skipped];
    if(_inputStatus) self.window.title=[NSString stringWithFormat:@"%@ • EDR %.2f× • O: open • R: test pattern",_inputStatus,headroom];
    else self.window.title=[self.window.title stringByAppendingString:@" • O: HDR video"];
    if(_stream && !_inputStatus) self.window.title=[NSString stringWithFormat:@"%@ • %.2f / %.2fs • %@ • queued %lu • late %lu • EDR %.2f× • Space: pause • ←/→: 5s • NO AUDIO",_filename,hdr_clock_time(_clock,CACurrentMediaTime()),_duration,_paused?@"Paused":@"Playing",(unsigned long)_frames.count,(unsigned long)_lateFrames,headroom];
    }
    if(_frame && !_inputStatus && !_error) {
        NSString *transfer=_frame.hlg?@"EXPERIMENTAL HLG · brightness unverified":@"PQ";
        if(![self.window.title containsString:transfer]) self.window.title=[self.window.title stringByAppendingFormat:@" • %@",transfer];
    }
    if((_paused || _stream) && !_dirty) return;
    // Admission happens BEFORE dispatch: GPU or drawable stalls cannot create an unbounded CPU queue.
    if(dispatch_semaphore_wait(_capacity,DISPATCH_TIME_NOW)!=0) { _skipped++; return; }
    uint64_t generation=atomic_load(&_generation);
    HDRFrame *frame=_frame;
    HDRUniforms uniforms={(float)headroom,(float)(_ticks++%180)/180.0f,frame.hlg?203.0f:100.0f,!_paused,
        frame?frame.aspect:1.0f,(float)(size.width/size.height),frame?frame.chromaOffsetX:0,frame.hlg};
    _dirty=NO;
    dispatch_semaphore_t capacity=_capacity;
    // This block keeps its view/layer alive until encoding ends. No UI or GL lock is held.
    dispatch_async(_presentQueue, ^{
        @autoreleasepool {
            if(generation!=atomic_load(&self->_generation)) { dispatch_semaphore_signal(capacity); return; }
            id<CAMetalDrawable> drawable=[self->_metal nextDrawable];
            if(!drawable || generation!=atomic_load(&self->_generation) ||
               drawable.texture.width!=(NSUInteger)size.width || drawable.texture.height!=(NSUInteger)size.height) {
                dispatch_semaphore_signal(capacity);
                dispatch_async(dispatch_get_main_queue(), ^{ if(generation==atomic_load(&self->_generation)) self->_dirty=YES; });
                return;
            }
            id<MTLCommandBuffer> command=[self->_commands commandBuffer];
            MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture=drawable.texture;
            pass.colorAttachments[0].loadAction=MTLLoadActionDontCare;
            pass.colorAttachments[0].storeAction=MTLStoreActionStore;
            id<MTLRenderCommandEncoder> encoder=command ? [command renderCommandEncoderWithDescriptor:pass] : nil;
            if(!encoder) {
                dispatch_semaphore_signal(capacity);
                dispatch_async(dispatch_get_main_queue(), ^{ self->_error=@"Metal encoder unavailable"; }); return;
            }
            [encoder setRenderPipelineState:frame?self->_videoPipeline:self->_pipeline];
            if(frame) { [encoder setFragmentTexture:frame.luma atIndex:0]; [encoder setFragmentTexture:frame.chroma atIndex:1]; }
            [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [encoder endEncoding];
            if(generation!=atomic_load(&self->_generation)) { dispatch_semaphore_signal(capacity); return; }
            [command addCompletedHandler:^(id<MTLCommandBuffer> done){
                // Keep CVMetalTexture wrappers AND the decoded CVPixelBuffer alive until GPU completion.
                (void)frame.luma;
                dispatch_semaphore_signal(capacity);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if(generation!=atomic_load(&self->_generation)) return;
                    if(done.status==MTLCommandBufferStatusError) self->_error=done.error.localizedDescription ?: @"GPU failure";
                    else self->_completed++;
                });
            }];
            [command presentDrawable:drawable]; [command commit];
        }
    });
}
- (void)stop {
    [self endSystemPlayback];
    _stopped=YES;_mediaGeneration++;[_stream cancel];_stream=nil;[_frames removeAllObjects]; atomic_fetch_add(&_generation,1);
    [_timer invalidate]; _timer=nil;
    // Never synchronously drain GPU/drawable work during close or resize.
}
- (void)dealloc { [_timer invalidate]; }
@end

@interface HDRApp : NSObject <NSApplicationDelegate,NSWindowDelegate,NSToolbarDelegate>
@property(nonatomic,strong) NSWindow *window;
@property(nonatomic,strong) HDRView *view;
@end
@implementation HDRApp
- (void)openVideo:(id)sender { (void)sender;[self.view openVideo]; }
- (void)openSystemVideo:(id)sender { (void)sender;[self.view openSystemVideo]; }
- (void)openMetalVideo:(id)sender { (void)sender;[self.view openMetalVideo]; }
- (void)returnToPattern:(id)sender { (void)sender;[self.view returnToPattern]; }
- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    (void)toolbar;return @[@"open-video",@"system-video",@"pattern",NSToolbarFlexibleSpaceItemIdentifier];
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    (void)toolbar;return @[@"open-video",@"system-video",@"pattern",NSToolbarFlexibleSpaceItemIdentifier];
}
- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)identifier willBeInsertedIntoToolbar:(BOOL)inserted {
    (void)toolbar;(void)inserted;
    NSToolbarItem *item=[[NSToolbarItem alloc] initWithItemIdentifier:identifier];
    item.label=@"Open Video";item.paletteLabel=item.label;item.toolTip=@"Open HDR video (⌘O)";
    item.image=[NSImage imageWithSystemSymbolName:@"folder" accessibilityDescription:item.label];
    item.target=self;item.action=@selector(openVideo:);
    if([identifier isEqualToString:@"system-video"]) { item.label=@"System Playback";item.toolTip=@"Use native HDR / Dolby Vision playback with audio";item.image=[NSImage imageWithSystemSymbolName:@"play.rectangle" accessibilityDescription:item.label];item.action=@selector(openSystemVideo:); }
    if([identifier isEqualToString:@"pattern"]) { item.label=@"Test Pattern";item.toolTip=@"Stop playback and return to the PQ pattern";item.image=[NSImage imageWithSystemSymbolName:@"rectangle.on.rectangle" accessibilityDescription:item.label];item.action=@selector(returnToPattern:); }
    return item;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,960,540)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.releasedWhenClosed=NO; self.window.delegate=self;
    NSToolbar *toolbar=[[NSToolbar alloc] initWithIdentifier:@"HDRPrototypeToolbar"];
    toolbar.delegate=self;toolbar.displayMode=NSToolbarDisplayModeIconAndLabel;self.window.toolbar=toolbar;
    NSMenu *main=[NSMenu new];
    NSMenuItem *appItem=[NSMenuItem new];[main addItem:appItem];
    NSMenu *appMenu=[NSMenu new];appItem.submenu=appMenu;
    [appMenu addItemWithTitle:@"Quit HDR Prototype" action:@selector(terminate:) keyEquivalent:@"q"];
    NSMenuItem *fileItem=[NSMenuItem new];[main addItem:fileItem];
    NSMenu *fileMenu=[[NSMenu alloc] initWithTitle:@"File"];fileItem.submenu=fileMenu;
    NSMenuItem *open=[fileMenu addItemWithTitle:@"Open Video…" action:@selector(openVideo:) keyEquivalent:@"o"];open.target=self;
    NSMenuItem *systemOpen=[fileMenu addItemWithTitle:@"Open in System Player…" action:@selector(openSystemVideo:) keyEquivalent:@""];systemOpen.target=self;
    NSMenuItem *pattern=[fileMenu addItemWithTitle:@"Return to Test Pattern" action:@selector(returnToPattern:) keyEquivalent:@"r"];pattern.target=self;
    NSMenuItem *metalOpen=[fileMenu addItemWithTitle:@"Experimental Metal Preview…" action:@selector(openMetalVideo:) keyEquivalent:@""];metalOpen.target=self;
    NSApp.mainMenu=main;
    self.view=[[HDRView alloc] initWithFrame:self.window.contentView.bounds];
    self.window.contentView=self.view;
    [self.window center]; [self.window makeKeyAndOrderFront:nil]; [self.window makeFirstResponder:self.view];
    [NSApp activateIgnoringOtherApps:YES];
}
- (void)windowWillClose:(NSNotification *)notification { (void)notification; [self.view stop]; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { (void)sender; return YES; }
- (void)applicationWillTerminate:(NSNotification *)notification { (void)notification; [self.view stop]; }
@end
int main(int argc, const char *argv[]) { @autoreleasepool {
    if(argc==2 && strcmp(argv[1],"--check-shader")==0) {
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        if(!device) { fprintf(stderr,"SKIP: no Metal device available\n"); return 77; }
        NSError *error=nil;
        if(!HDRCreatePipeline(device,@"hdrPattern",&error) || !HDRCreatePipeline(device,@"hdrVideo",&error)) {
            fprintf(stderr,"FAIL: %s\n",(error.localizedDescription ?: @"missing shader resource/function").UTF8String); return 1;
        }
        puts("PASS: runtime Metal shader and RGBA16Float render pipeline compilation; no window created");
        return 0;
    }
    if(argc==3 && strcmp(argv[1],"--check-frame")==0) {
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        if(!device) { fprintf(stderr,"SKIP: no Metal device available\n");return 77; }
        dispatch_semaphore_t completed=dispatch_semaphore_create(0);
        __block int result=1;
        [HDRFrame readFirstFrame:[NSURL fileURLWithPath:@(argv[2])] device:device completion:^(HDRFrame *frame,NSError *error){
            if(!frame) {
                fprintf(stderr,"REJECTED: %s\n",error.localizedDescription.UTF8String);
                dispatch_semaphore_signal(completed);return;
            }
            NSError *pipelineError=nil;
            id<MTLRenderPipelineState> pipeline=HDRCreatePipeline(device,@"hdrVideo",&pipelineError);
            id<MTLCommandQueue> queue=[device newCommandQueue];
            id<MTLCommandBuffer> command=[queue commandBuffer];
            MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:32 height:32 mipmapped:NO];
            desc.storageMode=MTLStorageModeShared;desc.usage=MTLTextureUsageRenderTarget;
            id<MTLTexture> target=[device newTextureWithDescriptor:desc];
            if(!pipeline || !command || !target) {
                fprintf(stderr,"FAIL: offscreen pipeline allocation\n");dispatch_semaphore_signal(completed);return;
            }
            MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction=MTLLoadActionDontCare;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
            id<MTLRenderCommandEncoder> encoder=[command renderCommandEncoderWithDescriptor:pass];
            if(!encoder) { fprintf(stderr,"FAIL: offscreen encoder\n");dispatch_semaphore_signal(completed);return; }
            HDRUniforms u={4,0,frame.hlg?203.0f:100.0f,0,frame.aspect,frame.aspect,frame.chromaOffsetX,frame.hlg};
            [encoder setRenderPipelineState:pipeline];[encoder setFragmentBytes:&u length:sizeof(u) atIndex:0];
            [encoder setFragmentTexture:frame.luma atIndex:0];[encoder setFragmentTexture:frame.chroma atIndex:1];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[encoder endEncoding];
            [command addCompletedHandler:^(id<MTLCommandBuffer> done){
                if(done.status==MTLCommandBufferStatusCompleted) {
                    __fp16 pixels[32*32*4];float maximum=0;BOOL valid=YES;
                    [target getBytes:pixels bytesPerRow:32*8 fromRegion:MTLRegionMake2D(0,0,32,32) mipmapLevel:0];
                    for(int i=0;i<32*32*4;i++) { float v=pixels[i]; if(!isfinite(v) || v<0 || v>4.001f)valid=NO;maximum=fmaxf(maximum,v); }
                    if(valid) { result=0;printf("PASS: P010 %lux%lu PTS %.3f decoded, Metal-converted to RGBA16F; max component %.4f (no window)\n",(unsigned long)frame.luma.width,(unsigned long)frame.luma.height,frame.pts,maximum); }
                    else fprintf(stderr,"FAIL: invalid converted pixels\n");
                } else fprintf(stderr,"FAIL: GPU conversion: %s\n",done.error.localizedDescription.UTF8String);
                dispatch_semaphore_signal(completed);
            }];
            [command commit];
        }];
        if(dispatch_semaphore_wait(completed,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))!=0) { fprintf(stderr,"FAIL: decoder timeout\n");return 1; }
        return result;
    }
    if(argc==3 && strcmp(argv[1],"--check-stream")==0) {
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        if(!device) { fprintf(stderr,"SKIP: no Metal device available\n");return 77; }
        HDRStream *stream=[[HDRStream alloc] initWithURL:[NSURL fileURLWithPath:@(argv[2])] device:device];
        dispatch_semaphore_t ready=dispatch_semaphore_create(0);
        __block NSError *failure=nil;
        __block HDRFrame *next=nil;
        __block BOOL eof=NO;
        [stream seekTo:0 completion:^(double duration,NSError *error){ (void)duration;failure=error;dispatch_semaphore_signal(ready); }];
        if(dispatch_semaphore_wait(ready,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC)) || failure) { fprintf(stderr,"FAIL: stream prepare\n");return 1; }
        NSUInteger count=0;double previous=-INFINITY;
        while(!eof && count<240) {
            next=nil;
            [stream readNext:^(HDRFrame *frame,NSError *error,BOOL ended){next=frame;failure=error;eof=ended;dispatch_semaphore_signal(ready);}];
            if(dispatch_semaphore_wait(ready,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC)) || failure) { fprintf(stderr,"FAIL: stream read %s\n",failure.localizedDescription.UTF8String);return 1; }
            if(next) { if(next.pts<=previous)return 1;previous=next.pts;count++; }
        }
        if(!eof || count<2) { fprintf(stderr,"FAIL: expected a short multi-frame fixture ending within 240 frames\n");return 1; }
        for(int attempt=0;attempt<2;attempt++) {
            double seek=attempt==0?previous/2:0;
            [stream seekTo:seek completion:^(double duration,NSError *error){(void)duration;failure=error;dispatch_semaphore_signal(ready);}];
            if(dispatch_semaphore_wait(ready,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC)) || failure)return 1;
            [stream readNext:^(HDRFrame *frame,NSError *error,BOOL ended){next=frame;failure=error;eof=ended;dispatch_semaphore_signal(ready);}];
            if(dispatch_semaphore_wait(ready,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC)) || failure || !next || next.pts+0.001<seek)return 1;
            if(attempt==1 && fabs(next.pts)>0.001)return 1;
        }
        [stream cancel];
        printf("PASS: %lu ordered decoded frames, EOF, forward seek and replay from zero; no window\n",(unsigned long)count);
        return 0;
    }
    NSApplication *app=[NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    HDRApp *delegate=[HDRApp new]; app.delegate=delegate; [app run];
} return 0; }
