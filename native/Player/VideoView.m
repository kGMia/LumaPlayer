// SPDX-License-Identifier: GPL-3.0-or-later
#import "VideoView.h"
#import <QuartzCore/QuartzCore.h>
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include <mpv/render_gl.h>
#include <OpenGL/gl3.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <math.h>
#include "../mpv-filter/iive_profile.h"
#include "RenderDiagnostics.h"
@interface VideoView () {
    mpv_render_context *_render;
    dispatch_queue_t _queue;
    dispatch_source_t _updates;
    atomic_int _pixelWidth, _pixelHeight;
    atomic_bool _redraw;
    atomic_bool _windowTransition;
    atomic_bool _inLiveResize;
    atomic_bool _renderingFrame;
    atomic_bool _swapIntervalUpdateNeeded;
    atomic_uint_fast64_t _renders;
    CFTimeInterval _lastLiveReshapeTime;
    NSPoint _mouseDownPoint;
    BOOL _mouseDragged;
    int _scrollAxis;
    double _accumulatedMagnification;
    dispatch_block_t _pendingSingleClick;
    atomic_bool _sampleLuminance;
    _Atomic(double) _presentationLuminance;
    GLuint _lumaFBO, _lumaColor, _lumaPBO;
    GLsync _lumaFence;
    double _lastLumaRead;
    BOOL _lumaUnavailable;
    NSLock *_timingLock;
    struct iive_render_diagnostics _renderDiagnostics;
    struct iive_latency_window _lumaPollLatency;
    double _lumaPollMaxMS;
    uint64_t _reportedSlowCount;
    struct iive_latency_window _drawLatency, _swapLatency, _contextWaitLatency;
    double _drawMaxMS, _swapMaxMS, _contextWaitMaxMS, _submitGapMaxMS, _lastSubmitTime, _lastSubmitGapMS;
    struct iive_submit_probe _mediaSubmitProbe;

}
@end
static void *resolveGL(void *ctx,const char *name){return dlsym(RTLD_DEFAULT,name);}
static void update(void *ctx){dispatch_source_merge_data((__bridge dispatch_source_t)ctx,1);}
@implementation VideoView
- (instancetype)initWithFrame:(NSRect)frame {
    NSOpenGLPixelFormatAttribute attrs[]={NSOpenGLPFAOpenGLProfile,NSOpenGLProfileVersion3_2Core,NSOpenGLPFAAccelerated,NSOpenGLPFADoubleBuffer,0};
    self=[super initWithFrame:frame pixelFormat:[[NSOpenGLPixelFormat alloc] initWithAttributes:attrs]];
    if(self){
        self.wantsBestResolutionOpenGLSurface=YES;
        self.wantsLayer=YES;
        self.layerContentsRedrawPolicy=NSViewLayerContentsRedrawDuringViewResize;
        self.layerContentsPlacement=NSViewLayerContentsPlacementScaleAxesIndependently;
        _queue=dispatch_queue_create("org.iive.render",DISPATCH_QUEUE_SERIAL);
        _timingLock=[NSLock new];
        atomic_store(&_presentationLuminance,NAN);

    }
    return self;
}
- (BOOL)preservesContentDuringLiveResize {
    return YES;
}
- (BOOL)mouseDownCanMoveWindow {
    // Return NO so AppKit delivers mouseDown/mouseDragged/mouseUp to VideoView;
    // window dragging is initiated explicitly in mouseDragged: after a 3pt threshold.
    return NO;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}
- (BOOL)acceptsFirstResponder {
    return YES;
}
- (void)cancelPendingSingleClick {
    if(_pendingSingleClick) {
        dispatch_block_cancel(_pendingSingleClick);
        _pendingSingleClick=nil;
    }
}
- (NSMenu *)menuForEvent:(NSEvent *)event {
    return self.contextMenuProvider ? self.contextMenuProvider() : [super menuForEvent:event];
}
- (void)mouseDown:(NSEvent *)event {
    if (event.modifierFlags & NSEventModifierFlagControl) {
        NSMenu *menu = [self menuForEvent:event];
        if (menu) [NSMenu popUpContextMenu:menu withEvent:event forView:self];
        return;
    }
    if(self.window && self.window.firstResponder != self) {
        [self.window makeFirstResponder:self];
    }
    _mouseDownPoint=event.locationInWindow;
    _mouseDragged=NO;
    if(event.clickCount>=2) {
        [self cancelPendingSingleClick];
    }
}
- (void)mouseDragged:(NSEvent *)event {
    NSPoint cur=event.locationInWindow;
    if(hypot(cur.x-_mouseDownPoint.x,cur.y-_mouseDownPoint.y)>3.0) {
        _mouseDragged=YES;
        [self cancelPendingSingleClick];
        if(self.window && !(self.window.styleMask & NSWindowStyleMaskFullScreen)) {
            [self.window performWindowDragWithEvent:event];
        }
    }
}
- (void)mouseUp:(NSEvent *)event {
    if(_mouseDragged)return;
    if(event.clickCount>=2) {
        [self cancelPendingSingleClick];
        if(self.onDoubleClick)self.onDoubleClick();
    } else if(event.clickCount==1) {
        [self cancelPendingSingleClick];
        __weak VideoView *weakSelf=self;
        dispatch_block_t block=dispatch_block_create(0,^{
            VideoView *strongSelf=weakSelf;
            if(!strongSelf)return;
            strongSelf->_pendingSingleClick=nil;
            if(strongSelf.onSingleClick)strongSelf.onSingleClick();
        });
        _pendingSingleClick=block;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.20*NSEC_PER_SEC)),dispatch_get_main_queue(),block);
    }
}
- (void)scrollWheel:(NSEvent *)event {
    if(event.phase==NSEventPhaseBegan) {
        _scrollAxis=0;
    }
    double dx=event.scrollingDeltaX;
    double dy=event.scrollingDeltaY;
    if(_scrollAxis==0 && (fabs(dx)>0.08 || fabs(dy)>0.08)) {
        _scrollAxis=fabs(dx)>fabs(dy)*1.15?2:1;
    }
    if(_scrollAxis==2 && event.hasPreciseScrollingDeltas) {
        // Ignore momentum phase for horizontal seek so releasing fingers stops scrubbing immediately.
        if(event.momentumPhase==NSEventPhaseNone && fabs(dx)>0.15) {
            if(self.onScrollSeek)self.onScrollSeek(dx * 0.14);
        }
    } else if((_scrollAxis==1 || !event.hasPreciseScrollingDeltas) && fabs(dy)>fabs(dx) && fabs(dy)>0.05) {
        double scale=event.hasPreciseScrollingDeltas?0.18:1.5;
        if(self.onScrollVolume)self.onScrollVolume(dy*scale);
    } else {
        [super scrollWheel:event];
    }
    if(event.phase==NSEventPhaseEnded || event.phase==NSEventPhaseCancelled) {
        _scrollAxis=0;
    }
}
- (void)magnifyWithEvent:(NSEvent *)event {
    if(event.phase==NSEventPhaseBegan) {
        _accumulatedMagnification=0;
    }
    _accumulatedMagnification+=event.magnification;
    if(fabs(_accumulatedMagnification)>=0.22) {
        double delta=_accumulatedMagnification;
        _accumulatedMagnification=0;
        if(self.onMagnify)self.onMagnify(delta);
    }
    if(event.phase==NSEventPhaseEnded || event.phase==NSEventPhaseCancelled) {
        _accumulatedMagnification=0;
    }
}
- (BOOL)startRenderer:(mpv_handle *)mpv {
    [self.openGLContext setView:self];[self.openGLContext update];
    [self.openGLContext makeCurrentContext];GLint interval=1;[self.openGLContext setValues:&interval forParameter:NSOpenGLContextParameterSwapInterval];
    [NSOpenGLContext clearCurrentContext];
    __block int result;
    dispatch_sync(_queue,^{
        [self.openGLContext makeCurrentContext];
        mpv_opengl_init_params gl={.get_proc_address=resolveGL};
        int advanced=1;
        mpv_render_param params[]={{MPV_RENDER_PARAM_API_TYPE,MPV_RENDER_API_TYPE_OPENGL},{MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,&gl},{MPV_RENDER_PARAM_ADVANCED_CONTROL,&advanced},{0}};
        result=mpv_render_context_create(&self->_render,mpv,params);
        [NSOpenGLContext clearCurrentContext];
    });
    if(result<0)return NO;
    _updates=dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD,0,0,_queue);
    __weak VideoView *weakSelf=self;
    dispatch_source_set_event_handler(_updates,^{[weakSelf renderFrame];});
    dispatch_resume(_updates);
    mpv_render_context_set_update_callback(_render,update,(__bridge void *)_updates);
    [self reshape];return YES;
}
- (void)viewWillStartLiveResize {
    [super viewWillStartLiveResize];
    atomic_store(&_inLiveResize,true);
    atomic_store(&_swapIntervalUpdateNeeded,true);
    _lastLiveReshapeTime=0;
}
- (void)viewDidEndLiveResize {
    [super viewDidEndLiveResize];
    atomic_store(&_inLiveResize,false);
    atomic_store(&_swapIntervalUpdateNeeded,true);
    _lastLiveReshapeTime=0;
    [self reshape];
}
- (void)reshape {
    // Fullscreen animates geometry repeatedly. Defer expensive drawable updates
    // until the transition ends, instead of waiting on the GPU from AppKit.
    if(atomic_load(&_windowTransition)) {
        [self updatePixelSize];
        return;
    }
    CGLContextObj gl=self.openGLContext.CGLContextObj;
    if(atomic_load(&_inLiveResize)) {
        CFTimeInterval now=CACurrentMediaTime();
        // Throttle OpenGL drawable reallocation during live window dragging to ~30 Hz
        // and skip if _queue is actively rendering so the main thread never stalls on CGLLockContext.
        if(now - _lastLiveReshapeTime < 0.033 || atomic_load(&_renderingFrame)) {
            return;
        }
        _lastLiveReshapeTime=now;
        if(gl)CGLLockContext(gl);
        [super reshape];
        if(gl)CGLUnlockContext(gl);
        [self updatePixelSize];
        return;
    }
    if(gl)CGLLockContext(gl);
    [super reshape];
    if(gl)CGLUnlockContext(gl);
    [self updatePixelSize];
}
- (void)updatePixelSize {
    NSRect size=[self convertRectToBacking:self.bounds];
    atomic_store(&_pixelWidth,MAX(1,(int)size.size.width));atomic_store(&_pixelHeight,MAX(1,(int)size.size.height));
    atomic_store(&_redraw,true);if(_updates)dispatch_source_merge_data(_updates,1);
}
- (void)drawRect:(NSRect)rect {atomic_store(&_redraw,true);if(_updates)dispatch_source_merge_data(_updates,1);}
- (void)renderFrame {
    if(!_render || atomic_load(&_windowTransition))return;
    // Capture before rendering. An already-running old-file draw must never
    // complete an observation armed concurrently by FILE_LOADED.
    double renderBegan=NSProcessInfo.processInfo.systemUptime;
    [_timingLock lock];
    uint64_t observedEpoch=_mediaSubmitProbe.first==0?_mediaSubmitProbe.epoch:0;
    [_timingLock unlock];
    atomic_store(&_renderingFrame,true);
    struct iive_render_event event={0};
    double phaseStart=iive_profile_seconds();
    [self.openGLContext makeCurrentContext];
    event.ms[IIVE_CURRENT]=(iive_profile_seconds()-phaseStart)*1000;
    CGLContextObj context=self.openGLContext.CGLContextObj;
    double contextWaitStart=iive_profile_seconds();
    CGLLockContext(context);
    double contextWaitMS=(iive_profile_seconds()-contextWaitStart)*1000;
    if(atomic_exchange(&_swapIntervalUpdateNeeded,false)) {
        // Disable VSync blocking during live window resize so flushBuffer never stalls
        // the main thread's CGLLockContext in -[VideoView reshape].
        GLint interval=atomic_load(&_inLiveResize)?0:1;
        [self.openGLContext setValues:&interval forParameter:NSOpenGLContextParameterSwapInterval];
    }
    event.ms[IIVE_CONTEXT_WAIT]=contextWaitMS;
    phaseStart=iive_profile_seconds();
    [self collectPresentationLuminance];
    event.ms[IIVE_LUMA_COLLECT]=(iive_profile_seconds()-phaseStart)*1000;
    double drawMS=NAN,swapMS=NAN;
    phaseStart=iive_profile_seconds();
    uint64_t flags=mpv_render_context_update(_render);
    mpv_render_frame_info frameInfo={0};
    BOOL freshMediaFrame=NO;
    if(observedEpoch && (flags&MPV_RENDER_UPDATE_FRAME)) {
        mpv_render_param query={MPV_RENDER_PARAM_NEXT_FRAME_INFO,&frameInfo};
        freshMediaFrame=mpv_render_context_get_info(_render,query)>=0 &&
            (frameInfo.flags&MPV_RENDER_FRAME_INFO_PRESENT) &&
            !(frameInfo.flags&(MPV_RENDER_FRAME_INFO_REDRAW|MPV_RENDER_FRAME_INFO_REPEAT));
    }
    event.ms[IIVE_UPDATE]=(iive_profile_seconds()-phaseStart)*1000;
    int w=atomic_load(&_pixelWidth),h=atomic_load(&_pixelHeight);
    // Consume the explicit redraw request even when mpv also reports a frame.
    BOOL redraw=atomic_exchange(&_redraw,false);
    event.redraw=redraw;event.mpv_frame=(flags&MPV_RENDER_UPDATE_FRAME)!=0;
    if((flags&MPV_RENDER_UPDATE_FRAME)||redraw) {
        mpv_opengl_fbo fbo={.fbo=0,.w=w,.h=h};
        int flip=1,blockForTargetTime=0;
        mpv_render_param params[]={
            {MPV_RENDER_PARAM_OPENGL_FBO,&fbo},
            {MPV_RENDER_PARAM_FLIP_Y,&flip},
            {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME,&blockForTargetTime},
            {0}
        };
        double drawStart=iive_profile_seconds();
        if(mpv_render_context_render(_render,params)>=0){
            drawMS=(iive_profile_seconds()-drawStart)*1000;
            phaseStart=iive_profile_seconds();
            [self samplePresentationLuminance];
            event.ms[IIVE_LUMA_ENQUEUE]=(iive_profile_seconds()-phaseStart)*1000;
            double swapStart=iive_profile_seconds();
            [self.openGLContext flushBuffer];
            swapMS=(iive_profile_seconds()-swapStart)*1000;
            phaseStart=iive_profile_seconds();
            mpv_render_context_report_swap(_render);
            event.ms[IIVE_REPORT_SWAP]=(iive_profile_seconds()-phaseStart)*1000;
            event.serial=atomic_fetch_add(&_renders,1)+1;
        }
    }
    CGLUnlockContext(context);[NSOpenGLContext clearCurrentContext];
    atomic_store(&_renderingFrame,false);
    if(isfinite(drawMS)) {
        double submitted=iive_profile_seconds();
        // Match the player snapshot clock, independently of duration timing.
        event.time_s=NSProcessInfo.processInfo.systemUptime;
        [_timingLock lock];
        iive_submit_probe_finish(&_mediaSubmitProbe,observedEpoch,renderBegan,event.time_s,freshMediaFrame);
        iive_latency_add(&_drawLatency,drawMS);iive_latency_add(&_swapLatency,swapMS);
        iive_latency_add(&_contextWaitLatency,contextWaitMS);
        _drawMaxMS=fmax(_drawMaxMS,drawMS);_swapMaxMS=fmax(_swapMaxMS,swapMS);
        _contextWaitMaxMS=fmax(_contextWaitMaxMS,contextWaitMS);
        _lastSubmitGapMS=_lastSubmitTime>0?(submitted-_lastSubmitTime)*1000:0;
        _submitGapMaxMS=fmax(_submitGapMaxMS,_lastSubmitGapMS);_lastSubmitTime=submitted;
        event.gap_ms=_lastSubmitGapMS;
        event.ms[IIVE_DRAW]=drawMS;event.ms[IIVE_SWAP]=swapMS;
        iive_render_record(&_renderDiagnostics,event);
        [_timingLock unlock];
        if(iive_profile_enabled())fprintf(stderr,"IIVE_PROFILE {\"stage\":\"render\",\"event\":\"submit\",\"time_s\":%.9f,\"draw_ms\":%.6f,\"swap_ms\":%.6f}\n",iive_profile_seconds(),drawMS,swapMS);
    }
}
- (NSSize)pixelSize { return NSMakeSize(atomic_load(&_pixelWidth),atomic_load(&_pixelHeight)); }
- (void)beginMediaRenderObservation:(uint64_t)epoch {
    [_timingLock lock];
    _mediaSubmitProbe=(struct iive_submit_probe){.epoch=epoch,.armed=NSProcessInfo.processInfo.systemUptime};
    [_timingLock unlock];
}
- (NSDictionary *)mediaRenderObservation {
    [_timingLock lock];
    uint64_t epoch=_mediaSubmitProbe.epoch;
    double armed=_mediaSubmitProbe.armed,submitted=_mediaSubmitProbe.first;
    [_timingLock unlock];
    return @{@"epoch":@(epoch),@"armed_at_s":@(armed),@"fresh_submit_s":submitted>0?@(submitted):NSNull.null};
}
- (uint64_t)renderCount{return atomic_load(&_renders);}
- (void)resetRenderTiming {
    [_timingLock lock];
    iive_latency_reset(&_drawLatency);
    iive_latency_reset(&_swapLatency);
    iive_latency_reset(&_contextWaitLatency);
    memset(&_renderDiagnostics,0,sizeof(_renderDiagnostics));_reportedSlowCount=0;
    iive_latency_reset(&_lumaPollLatency);_lumaPollMaxMS=0;
    _drawMaxMS=_swapMaxMS=_contextWaitMaxMS=_submitGapMaxMS=_lastSubmitTime=_lastSubmitGapMS=0;
    [_timingLock unlock];
}
- (NSDictionary *)renderTiming {
    // Copy bounded plain data and consume the event cursor under the lock.
    // Sorting and Foundation allocations must never hold up the render queue.
    [_timingLock lock];
    struct iive_render_diagnostics diagnostics=_renderDiagnostics;
    struct iive_latency_window drawLatency=_drawLatency,swapLatency=_swapLatency;
    struct iive_latency_window contextWaitLatency=_contextWaitLatency,lumaPollLatency=_lumaPollLatency;
    double drawMaxMS=_drawMaxMS,swapMaxMS=_swapMaxMS,contextWaitMaxMS=_contextWaitMaxMS;
    double submitGapMaxMS=_submitGapMaxMS,lastSubmitGapMS=_lastSubmitGapMS,lumaPollMaxMS=_lumaPollMaxMS;
    uint64_t unread=diagnostics.slow_count-_reportedSlowCount;
    _reportedSlowCount=diagnostics.slow_count;
    [_timingLock unlock];

    NSMutableDictionary *result=[NSMutableDictionary dictionaryWithDictionary:@{@"samples":@(drawLatency.count)}];
    double p50,p95;
    if(iive_latency_read(&drawLatency,&p50,&p95)){result[@"draw_p50_ms"]=@(p50);result[@"draw_p95_ms"]=@(p95);}
    if(iive_latency_read(&swapLatency,&p50,&p95)){result[@"swap_p50_ms"]=@(p50);result[@"swap_p95_ms"]=@(p95);}
    if(iive_latency_read(&contextWaitLatency,&p50,&p95))result[@"context_wait_p95_ms"]=@(p95);
    if(drawLatency.count) {
        result[@"draw_max_ms"]=@(drawMaxMS);result[@"swap_max_ms"]=@(swapMaxMS);
        result[@"context_wait_max_ms"]=@(contextWaitMaxMS);
        // Submission intervals include intentional pause/seek/occlusion gaps.
        // They are evidence for correlation, not an independent dropped-frame counter.
        result[@"submit_gap_max_ms"]=@(submitGapMaxMS);result[@"last_submit_gap_ms"]=@(lastSubmitGapMS);
    }
    static NSString *const names[]={@"make_current",@"context_wait",@"update",@"draw",
        @"luma_collect",@"luma_enqueue",@"swap",@"report_swap"};
    for(int i=0;i<IIVE_RENDER_PHASES;i++) {
        if(iive_latency_read(&diagnostics.phases[i],&p50,&p95)) {
            result[[names[i] stringByAppendingString:@"_p95_ms"]]=@(p95);
            result[[names[i] stringByAppendingString:@"_max_ms"]]=@(diagnostics.maxima[i]);
        }
    }
    if(iive_latency_read(&lumaPollLatency,&p50,&p95)) {
        result[@"luma_poll_p95_ms"]=@(p95);result[@"luma_poll_max_ms"]=@(lumaPollMaxMS);
    }
    // The single session snapshot consumer forwards these to UI/recording.
    // Emit each event once rather than repeating the full ring at 4 Hz.
    unsigned count=(unsigned)MIN(unread,diagnostics.count);
    NSMutableArray *events=[NSMutableArray arrayWithCapacity:count];
    for(unsigned n=0;n<count;n++) {
        unsigned index=(diagnostics.next+IIVE_SLOW_FRAMES-count+n)%IIVE_SLOW_FRAMES;
        struct iive_render_event e=diagnostics.slow[index];
        NSMutableDictionary *item=[@{@"time_s":@(e.time_s),@"frame_serial":@(e.serial),
            @"submit_gap_ms":@(e.gap_ms),@"explicit_redraw":@(e.redraw),@"mpv_frame":@(e.mpv_frame)} mutableCopy];
        for(int i=0;i<IIVE_RENDER_PHASES;i++)if(isfinite(e.ms[i]))
            item[[names[i] stringByAppendingString:@"_ms"]]=@(e.ms[i]);
        [events addObject:item];
    }
    result[@"slow_frame_count"]=@(diagnostics.slow_count);
    result[@"slow_frames"]=events;
    result[@"slow_frames_overwritten"]=@(unread-count);
    result[@"slow_event_clock"]=@"system-uptime";
    return result;
}
- (void)setLuminanceSamplingEnabled:(BOOL)enabled {
    if(atomic_exchange(&_sampleLuminance,enabled)==enabled)return;
    if(!enabled)atomic_store(&_presentationLuminance,NAN);
    atomic_store(&_redraw,true);if(_updates)dispatch_source_merge_data(_updates,1);
}
- (double)presentationLuminance { return atomic_load(&_sampleLuminance)?atomic_load(&_presentationLuminance):NAN; }
// Render-queue only. Readback uses one tiny PBO and a zero-timeout fence probe;
// never wait for the GPU and never decode another video just to theme the UI.
- (void)collectPresentationLuminance {
    if(!atomic_load(&_sampleLuminance) || _lumaUnavailable || atomic_load(&_inLiveResize))return;
    if(_lumaFence) {
        GLenum status=glClientWaitSync(_lumaFence,0,0);
        if(status==GL_TIMEOUT_EXPIRED)return;
        glDeleteSync(_lumaFence);_lumaFence=NULL;
        if(status==GL_WAIT_FAILED){_lumaUnavailable=YES;return;}
        GLint pack=0;glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING,&pack);
        glBindBuffer(GL_PIXEL_PACK_BUFFER,_lumaPBO);
        const uint8_t *pixels=glMapBufferRange(GL_PIXEL_PACK_BUFFER,0,16*9*4,GL_MAP_READ_BIT);
        if(pixels) {
            double total=0;
            for(int i=0;i<16*9;i++)total+=0.2126*pixels[i*4]+0.7152*pixels[i*4+1]+0.0722*pixels[i*4+2];
            if(glUnmapBuffer(GL_PIXEL_PACK_BUFFER))atomic_store(&_presentationLuminance,total/(16*9*255));
        }
        glBindBuffer(GL_PIXEL_PACK_BUFFER,pack);
    }
}
// This timer only collects a pending PBO. It must not run mpv update/render or
// cause an extra presentation. Normal frames also collect completed readbacks.
- (void)pollPresentationLuminance {
    if(!_render || !_lumaFence || !atomic_load(&_sampleLuminance) ||
       atomic_load(&_windowTransition) || atomic_load(&_inLiveResize))return;
    double start=iive_profile_seconds();
    atomic_store(&_renderingFrame,true);
    [self.openGLContext makeCurrentContext];
    CGLContextObj context=self.openGLContext.CGLContextObj;
    CGLLockContext(context);
    [self collectPresentationLuminance];
    CGLUnlockContext(context);[NSOpenGLContext clearCurrentContext];
    atomic_store(&_renderingFrame,false);
    double ms=(iive_profile_seconds()-start)*1000;
    [_timingLock lock];
    iive_latency_add(&_lumaPollLatency,ms);_lumaPollMaxMS=fmax(_lumaPollMaxMS,ms);
    [_timingLock unlock];
}
- (void)samplePresentationLuminance {
    if(!atomic_load(&_sampleLuminance) || _lumaUnavailable || atomic_load(&_inLiveResize) || _lumaFence)return;
    double now=CACurrentMediaTime();
    if(now-_lastLumaRead<2)return;
    _lastLumaRead=now;
    GLint pack=0;glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING,&pack);
    GLint readFBO=0,drawFBO=0,readBuffer=0,renderbuffer=0;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING,&readFBO);glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,&drawFBO);
    glGetIntegerv(GL_READ_BUFFER,&readBuffer);glGetIntegerv(GL_RENDERBUFFER_BINDING,&renderbuffer);
    if(!_lumaFBO) {
        glGenFramebuffers(1,&_lumaFBO);glGenRenderbuffers(1,&_lumaColor);glGenBuffers(1,&_lumaPBO);
        glBindRenderbuffer(GL_RENDERBUFFER,_lumaColor);glRenderbufferStorage(GL_RENDERBUFFER,GL_RGBA8,16,9);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER,_lumaFBO);
        glFramebufferRenderbuffer(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_RENDERBUFFER,_lumaColor);
        _lumaUnavailable=glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE;
        glBindBuffer(GL_PIXEL_PACK_BUFFER,_lumaPBO);glBufferData(GL_PIXEL_PACK_BUFFER,16*9*4,NULL,GL_STREAM_READ);
    }
    if(!_lumaUnavailable) {
        GLboolean scissor=glIsEnabled(GL_SCISSOR_TEST),srgb=glIsEnabled(GL_FRAMEBUFFER_SRGB);
        glDisable(GL_SCISSOR_TEST);glDisable(GL_FRAMEBUFFER_SRGB);
        glBindFramebuffer(GL_READ_FRAMEBUFFER,0);glReadBuffer(GL_BACK);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER,_lumaFBO);
        glBlitFramebuffer(0,0,atomic_load(&_pixelWidth),atomic_load(&_pixelHeight),0,0,16,9,GL_COLOR_BUFFER_BIT,GL_LINEAR);
        glBindFramebuffer(GL_READ_FRAMEBUFFER,_lumaFBO);glReadBuffer(GL_COLOR_ATTACHMENT0);
        glBindBuffer(GL_PIXEL_PACK_BUFFER,_lumaPBO);
        GLenum keys[]={GL_PACK_ALIGNMENT,GL_PACK_ROW_LENGTH,GL_PACK_SKIP_ROWS,GL_PACK_SKIP_PIXELS};
        GLint values[4];
        for(int i=0;i<4;i++){glGetIntegerv(keys[i],&values[i]);glPixelStorei(keys[i],i==0?1:0);}
        glReadPixels(0,0,16,9,GL_RGBA,GL_UNSIGNED_BYTE,0);
        for(int i=0;i<4;i++)glPixelStorei(keys[i],values[i]);
        _lumaFence=glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE,0);
        if(!_lumaFence)_lumaUnavailable=YES;
        else {
            // A paused video may produce no next frame. Collect once later without
            // requesting another mpv render or blocking the main thread.
            __weak VideoView *weakSelf=self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),_queue,^{[weakSelf pollPresentationLuminance];});
        }
        if(scissor)glEnable(GL_SCISSOR_TEST);
        if(srgb)glEnable(GL_FRAMEBUFFER_SRGB);
    }
    glBindBuffer(GL_PIXEL_PACK_BUFFER,pack);glBindRenderbuffer(GL_RENDERBUFFER,renderbuffer);
    glBindFramebuffer(GL_READ_FRAMEBUFFER,readFBO);glReadBuffer(readBuffer);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER,drawFBO);
}
- (void)destroyLuminanceSampler {
    if(_lumaFence)glDeleteSync(_lumaFence);
    if(_lumaPBO)glDeleteBuffers(1,&_lumaPBO);
    if(_lumaFBO)glDeleteFramebuffers(1,&_lumaFBO);
    if(_lumaColor)glDeleteRenderbuffers(1,&_lumaColor);
    _lumaFence=NULL;_lumaPBO=_lumaFBO=_lumaColor=0;_lumaUnavailable=NO;_lastLumaRead=0;
    atomic_store(&_presentationLuminance,NAN);
}
- (void)prepareForWindowTransition:(void (^)(void))completion {
    // Finish the current GL frame off the main thread. During the subsequent
    // AppKit resize, reshape can acquire the context without competing draws.
    atomic_store(&_windowTransition,true);
    dispatch_async(_queue,^{dispatch_async(dispatch_get_main_queue(),completion);});
}
- (void)finishWindowTransition {
    // The same context now targets another NSWindow's drawable. Preserve all
    // mpv GPU resources, but explicitly refresh the surface before drawing.
    CGLContextObj gl=self.openGLContext.CGLContextObj;
    if(gl)CGLLockContext(gl);
    [self.openGLContext setView:self];
    [self.openGLContext update];
    [super reshape];
    if(gl)CGLUnlockContext(gl);
    [self updatePixelSize];
    atomic_store(&_windowTransition,false);
    atomic_store(&_redraw,true);
    if(_updates)dispatch_source_merge_data(_updates,1);
}
- (void)setICCProfileData:(NSData *)data completion:(void (^)(BOOL))completion {
    NSData *profile=[data copy];
    dispatch_async(_queue, ^{
        BOOL accepted=NO;
        if(self->_render) {
            [self.openGLContext makeCurrentContext];
            CGLContextObj gl=self.openGLContext.CGLContextObj;CGLLockContext(gl);
            mpv_byte_array bytes={.data=(void *)profile.bytes,.size=profile.length};
            mpv_render_param parameter={MPV_RENDER_PARAM_ICC_PROFILE,&bytes};
            accepted=mpv_render_context_set_parameter(self->_render,parameter)>=0;
            CGLUnlockContext(gl);[NSOpenGLContext clearCurrentContext];
            atomic_store(&self->_redraw,true);
            if(self->_updates)dispatch_source_merge_data(self->_updates,1);
        }
        dispatch_async(dispatch_get_main_queue(), ^{completion(accepted);});
    });
}
- (void)stopRenderer {
    [self cancelPendingSingleClick];
    if(!_render)return;
    mpv_render_context_set_update_callback(_render,NULL,NULL);
    dispatch_source_cancel(_updates);
    dispatch_sync(_queue,^{
        [self.openGLContext makeCurrentContext];
        [self destroyLuminanceSampler];
        mpv_render_context_free(self->_render);self->_render=NULL;
        [NSOpenGLContext clearCurrentContext];
    });
    _updates=nil;
}
@end
