// SPDX-License-Identifier: GPL-3.0-or-later
#import "VideoView.h"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include <mpv/render_gl.h>
#include <OpenGL/gl3.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <math.h>
@interface VideoView () {
    mpv_render_context *_render;
    dispatch_queue_t _queue;
    dispatch_source_t _updates;
    atomic_int _pixelWidth, _pixelHeight;
    atomic_bool _redraw;
    atomic_bool _windowTransition;
    atomic_uint_fast64_t _renders;
    NSPoint _mouseDownPoint;
    BOOL _mouseDragged;
    dispatch_block_t _pendingSingleClick;
}
@end
static void *resolveGL(void *ctx,const char *name){return dlsym(RTLD_DEFAULT,name);}
static void update(void *ctx){dispatch_source_merge_data((__bridge dispatch_source_t)ctx,1);}
@implementation VideoView
- (instancetype)initWithFrame:(NSRect)frame {
    NSOpenGLPixelFormatAttribute attrs[]={NSOpenGLPFAOpenGLProfile,NSOpenGLProfileVersion3_2Core,NSOpenGLPFAAccelerated,NSOpenGLPFADoubleBuffer,0};
    self=[super initWithFrame:frame pixelFormat:[[NSOpenGLPixelFormat alloc] initWithAttributes:attrs]];
    if(self){self.wantsBestResolutionOpenGLSurface=YES;_queue=dispatch_queue_create("org.iive.render",DISPATCH_QUEUE_SERIAL);}
    return self;
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
- (void)mouseDown:(NSEvent *)event {
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
    if(fabs(event.scrollingDeltaY)>fabs(event.scrollingDeltaX) && fabs(event.scrollingDeltaY)>0.05) {
        double scale=event.hasPreciseScrollingDeltas?0.18:1.5;
        if(self.onScrollVolume)self.onScrollVolume(event.scrollingDeltaY*scale);
    } else {
        [super scrollWheel:event];
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
- (void)reshape {
    // Fullscreen animates geometry repeatedly. Defer expensive drawable updates
    // until the transition ends, instead of waiting on the GPU from AppKit.
    if(!atomic_load(&_windowTransition)) {
        CGLContextObj gl=self.openGLContext.CGLContextObj;
        if(gl)CGLLockContext(gl);[super reshape];if(gl)CGLUnlockContext(gl);
    }
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
    [self.openGLContext makeCurrentContext];
    CGLContextObj context=self.openGLContext.CGLContextObj;CGLLockContext(context);
    uint64_t flags=mpv_render_context_update(_render);
    if((flags&MPV_RENDER_UPDATE_FRAME)||atomic_exchange(&_redraw,false)) {
        mpv_opengl_fbo fbo={.fbo=0,.w=atomic_load(&_pixelWidth),.h=atomic_load(&_pixelHeight)};int flip=1;
        mpv_render_param params[]={{MPV_RENDER_PARAM_OPENGL_FBO,&fbo},{MPV_RENDER_PARAM_FLIP_Y,&flip},{0}};
        if(mpv_render_context_render(_render,params)>=0){
            [self.openGLContext flushBuffer];mpv_render_context_report_swap(_render);atomic_fetch_add(&_renders,1);
        }
    }
    CGLUnlockContext(context);[NSOpenGLContext clearCurrentContext];
}
- (NSSize)pixelSize { return NSMakeSize(atomic_load(&_pixelWidth),atomic_load(&_pixelHeight)); }
- (uint64_t)renderCount{return atomic_load(&_renders);}
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
    dispatch_sync(_queue,^{[self.openGLContext makeCurrentContext];mpv_render_context_free(self->_render);self->_render=NULL;[NSOpenGLContext clearCurrentContext];});
    _updates=nil;
}
@end
