// SPDX-License-Identifier: GPL-3.0-or-later
#import "IIVEEDRBridge.h"
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <OpenGL/CGLIOSurface.h>
#import <Metal/Metal.h>
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

typedef struct {
    float maxHeadroom;
    float kneeStart;
    float exposureScale;
    uint32_t flipY;
} IIVEEDRUniforms;

static NSString *const kIIVEEDRShaderSource = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct EDRUniforms { float maxHeadroom; float kneeStart; float exposureScale; uint flipY; };\n"
"inline float3 softKneeEDR(float3 v, float knee, float peak) {\n"
"    float3 pos = max(v, float3(0.0));\n"
"    if (peak <= 1.0001f) return clamp(pos, float3(0.0), float3(1.0));\n"
"    float3 over = max(pos - knee, float3(0.0));\n"
"    float span = max(peak - knee, 1e-4f);\n"
"    float3 compressed = knee + (span * over) / (over + span);\n"
"    return select(pos, min(compressed, float3(peak)), pos > knee);\n"
"}\n"
"kernel void iivePresentEDR(texture2d<half, access::read> src [[texture(0)]],\n"
"                           texture2d<half, access::write> dst [[texture(1)]],\n"
"                           constant EDRUniforms &u [[buffer(0)]],\n"
"                           uint2 gid [[thread_position_in_grid]]) {\n"
"    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;\n"
"    uint srcX = min(gid.x, src.get_width() - 1);\n"
"    uint rawY = min(gid.y, src.get_height() - 1);\n"
"    uint srcY = u.flipY ? (src.get_height() - 1 - rawY) : rawY;\n"
"    float4 px = float4(src.read(uint2(srcX, srcY)));\n"
"    float3 mapped = softKneeEDR(px.rgb * u.exposureScale, u.kneeStart, u.maxHeadroom);\n"
"    dst.write(half4(half3(mapped), half(px.a)), gid);\n"
"}\n";

@interface IIVEEDRSlot : NSObject {
@public
    CVPixelBufferRef pixels;
    GLuint texture, fbo;
    GLsync fence;
}
@property(nonatomic) id<MTLTexture> metalTexture;
@property(nonatomic) id<MTLCommandBuffer> command;
@property(nonatomic) uint64_t serial;
@end
@implementation IIVEEDRSlot
- (void)dealloc { if(pixels)CVPixelBufferRelease(pixels); }
@end

@implementation IIVEEDRBridge {
    CGLContextObj _context;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _metalQueue;
    id<MTLComputePipelineState> _presentPipeline;
    NSArray<IIVEEDRSlot *> *_slots;
    IIVEEDRSlot *_writing;
    uint64_t _serial;
    BOOL _invalid;
}
- (void)fail:(NSString *)message {
    _failure=[NSError errorWithDomain:@"org.iive.edr-prototype" code:1
                            userInfo:@{NSLocalizedDescriptionKey:message}];
}
- (BOOL)allocateSlotsWithWidth:(NSUInteger)width height:(NSUInteger)height {
    GLint oldFBO=0,oldTexture=0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING,&oldFBO);
    glGetIntegerv(GL_TEXTURE_BINDING_RECTANGLE,&oldTexture);
    NSMutableArray<IIVEEDRSlot *> *slots=[NSMutableArray array];
    for(int i=0;i<2 && !_failure;i++) {
        IIVEEDRSlot *slot=[IIVEEDRSlot new];[slots addObject:slot];
        NSDictionary *attributes=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},
            (id)kCVPixelBufferMetalCompatibilityKey:@YES,
            (id)kCVPixelBufferOpenGLCompatibilityKey:@YES};
        CVReturn result=CVPixelBufferCreate(NULL,width,height,kCVPixelFormatType_64RGBAHalf,
            (__bridge CFDictionaryRef)attributes,&slot->pixels);
        IOSurfaceRef surface=slot->pixels?CVPixelBufferGetIOSurface(slot->pixels):NULL;
        if(result!=kCVReturnSuccess || !surface){[self fail:@"RGBA16F IOSurface allocation unavailable."];break;}
        glGenTextures(1,&slot->texture);glBindTexture(GL_TEXTURE_RECTANGLE,slot->texture);
        CGLError glResult=CGLTexImageIOSurface2D(_context,GL_TEXTURE_RECTANGLE,GL_RGBA16F,
            (GLsizei)width,(GLsizei)height,GL_RGBA,GL_HALF_FLOAT,surface,0);
        if(glResult!=kCGLNoError){[self fail:[NSString stringWithFormat:@"RGBA16F CGL binding: %s",CGLErrorString(glResult)]];break;}
        glGenFramebuffers(1,&slot->fbo);glBindFramebuffer(GL_FRAMEBUFFER,slot->fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_RECTANGLE,slot->texture,0);
        if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE){[self fail:@"RGBA16F framebuffer incomplete."];break;}
        MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
            width:width height:height mipmapped:NO];
        desc.storageMode=MTLStorageModeShared;desc.usage=MTLTextureUsageShaderRead;
        slot.metalTexture=[_device newTextureWithDescriptor:desc iosurface:surface plane:0];
        if(!slot.metalTexture){[self fail:@"Metal cannot bind the RGBA16F IOSurface."];break;}
    }
    glBindFramebuffer(GL_FRAMEBUFFER,(GLuint)oldFBO);glBindTexture(GL_TEXTURE_RECTANGLE,(GLuint)oldTexture);
    if(_failure) {
        for(IIVEEDRSlot *slot in slots) {
            if(slot->fbo)glDeleteFramebuffers(1,&slot->fbo);
            if(slot->texture)glDeleteTextures(1,&slot->texture);
            if(slot->pixels){CVPixelBufferRelease(slot->pixels);slot->pixels=NULL;}
        }
        return NO;
    }
    _slots=slots;
    _pixelSize=CGSizeMake(width,height);
    _layer.drawableSize=_pixelSize;
    return YES;
}
- (void)releaseSlots {
    if(!_slots.count)return;
    for(IIVEEDRSlot *slot in _slots)[slot.command waitUntilCompleted];
    glFinish();
    for(IIVEEDRSlot *slot in _slots) {
        if(slot->fence){glDeleteSync(slot->fence);slot->fence=NULL;}
        if(slot->fbo){glDeleteFramebuffers(1,&slot->fbo);slot->fbo=0;}
        if(slot->texture){glDeleteTextures(1,&slot->texture);slot->texture=0;}
        slot.metalTexture=nil;slot.command=nil;
        if(slot->pixels){CVPixelBufferRelease(slot->pixels);slot->pixels=NULL;}
    }
    _slots=@[];
    _writing=nil;
}
- (instancetype)initWithContext:(CGLContextObj)context width:(NSUInteger)width height:(NSUInteger)height error:(NSError **)error {
    if(!(self=[super init]))return nil;
    if(!context || CGLGetCurrentContext()!=context || !width || !height || width>8192 || height>8192) {
        [self fail:@"A current CGL context and dimensions within 1…8192 are required."];
        if(error)*error=_failure;return nil;
    }
    _context=CGLRetainContext(context);
    _device=MTLCreateSystemDefaultDevice();
    _metalQueue=[_device newCommandQueue];
    _maximumEDRHeadroom=2.0;
    _sourcePeakNits=203.0;
    _layer=[CAMetalLayer layer];
    _layer.device=_device;_layer.pixelFormat=MTLPixelFormatRGBA16Float;
    _layer.framebufferOnly=NO;_layer.maximumDrawableCount=2;
    _layer.wantsExtendedDynamicRangeContent=YES;
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    _layer.colorspace=space;CGColorSpaceRelease(space);
    if(!_metalQueue)[self fail:@"Metal command queue unavailable."];
    if(_device && !_failure) {
        NSError *shaderErr=nil;
        id<MTLLibrary> lib=[_device newLibraryWithSource:kIIVEEDRShaderSource options:nil error:&shaderErr];
        id<MTLFunction> fn=[lib newFunctionWithName:@"iivePresentEDR"];
        if(fn)_presentPipeline=[_device newComputePipelineStateWithFunction:fn error:&shaderErr];
        if(!_presentPipeline)[self fail:shaderErr.localizedDescription ?: @"EDR presentation shader unavailable."];
    }
    if(!_failure)[self allocateSlotsWithWidth:width height:height];
    if(_failure){if(error)*error=_failure;[self invalidate];return nil;}
    return self;
}
- (void)updateDisplayHeadroom:(CGFloat)headroom sourcePeakNits:(CGFloat)sourcePeakNits colorSpaceName:(CFStringRef)colorSpaceName {
    _maximumEDRHeadroom=fmax(1.0,headroom);
    _sourcePeakNits=fmax(100.0,sourcePeakNits);
    CFStringRef targetSpace=colorSpaceName ?: kCGColorSpaceExtendedLinearSRGB;
    CGColorSpaceRef space=CGColorSpaceCreateWithName(targetSpace);
    if(space){_layer.colorspace=space;CGColorSpaceRelease(space);}
}
- (BOOL)resizeToWidth:(NSUInteger)width height:(NSUInteger)height {
    if(_invalid || !width || !height || width>8192 || height>8192)return NO;
    if((NSUInteger)_pixelSize.width==width && (NSUInteger)_pixelSize.height==height)return YES;
    NSAssert(CGLGetCurrentContext()==_context,@"Bridge requires its CGL context");
    _failure=nil;
    [self releaseSlots];
    return [self allocateSlotsWithWidth:width height:height];
}
- (GLuint)beginFrame {
    if(_invalid || _failure || _writing)return 0;
    NSAssert(CGLGetCurrentContext()==_context,@"Bridge requires its CGL context");
    for(IIVEEDRSlot *slot in _slots) {
        if(slot->fence || slot.serial)continue;
        if(slot.command) {
            if(slot.command.status==MTLCommandBufferStatusError){[self fail:slot.command.error.localizedDescription];return 0;}
            if(slot.command.status!=MTLCommandBufferStatusCompleted)continue;
            slot.command=nil;
        }
        _writing=slot;return slot->fbo;
    }
    return 0;
}
- (BOOL)hasPendingFrames {
    if(_invalid || _failure)return NO;
    for(IIVEEDRSlot *slot in _slots) {
        if(slot.serial != 0 || (slot.command && slot.command.status!=MTLCommandBufferStatusCompleted))return YES;
    }
    return NO;
}
- (void)endFrame {
    if(!_writing)return;
    _writing->fence=glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE,0);
    _writing.serial=++_serial;
    if(!_writing->fence)[self fail:@"Could not insert the GL completion fence."];
    glFlush();_writing=nil;
}
- (BOOL)presentReadyFrame {
    if(_invalid || _failure)return NO;
    for(IIVEEDRSlot *slot in _slots) {
        if(slot.command.status==MTLCommandBufferStatusError) {
            [self fail:slot.command.error.localizedDescription ?: @"Metal presentation failed."];return NO;
        }
    }
    IIVEEDRSlot *oldest=nil;
    for(IIVEEDRSlot *slot in _slots)
        if(slot.serial && (!oldest || slot.serial<oldest.serial))oldest=slot;
    if(!oldest)return NO;
    if(oldest->fence) {
        GLenum status=glClientWaitSync(oldest->fence,GL_SYNC_FLUSH_COMMANDS_BIT,0);
        if(status==GL_TIMEOUT_EXPIRED)return NO;
        if(status==GL_WAIT_FAILED){[self fail:@"GL fence failed; Metal read suppressed."];return NO;}
        glDeleteSync(oldest->fence);oldest->fence=NULL;
    }
    if((NSUInteger)_layer.drawableSize.width!=(NSUInteger)_pixelSize.width ||
       (NSUInteger)_layer.drawableSize.height!=(NSUInteger)_pixelSize.height) {
        _layer.drawableSize=_pixelSize;
    }
    id<CAMetalDrawable> drawable=[_layer nextDrawable];
    if(!drawable)return NO;
    id<MTLCommandBuffer> command=[_metalQueue commandBuffer];
    if(!command){[self fail:@"Metal command buffer unavailable."];return NO;}
    if(_presentPipeline && (drawable.texture.usage==MTLTextureUsageUnknown ||
                             (drawable.texture.usage & MTLTextureUsageShaderWrite))) {
        id<MTLComputeCommandEncoder> enc=[command computeCommandEncoder];
        if(!enc){[self fail:@"Metal compute encoder unavailable."];return NO;}
        float headroom=(float)fmax(1.0,_maximumEDRHeadroom);
        float knee=headroom>1.05f ? fmaxf(1.0f,headroom*0.82f) : 1.0f;
        IIVEEDRUniforms u={.maxHeadroom=headroom,.kneeStart=knee,.exposureScale=1.0f,.flipY=0};
        [enc setComputePipelineState:_presentPipeline];
        [enc setTexture:oldest.metalTexture atIndex:0];
        [enc setTexture:drawable.texture atIndex:1];
        [enc setBytes:&u length:sizeof(u) atIndex:0];
        NSUInteger tw=_presentPipeline.threadExecutionWidth;
        NSUInteger th=MAX(1,_presentPipeline.maxTotalThreadsPerThreadgroup/tw);
        MTLSize tg=MTLSizeMake(tw,th,1);
        MTLSize groups=MTLSizeMake((drawable.texture.width+tw-1)/tw,(drawable.texture.height+th-1)/th,1);
        [enc dispatchThreadgroups:groups threadsPerThreadgroup:tg];
        [enc endEncoding];
    } else {
        [self fail:@"EDR drawable does not support the required compute write path."];return NO;
    }
    void (^presented)(void)=[self.onFramePresented copy];
    if(presented)[drawable addPresentedHandler:^(id<MTLDrawable> shown){(void)shown;presented();}];
    [command presentDrawable:drawable];
    oldest.command=command;oldest.serial=0;[command commit];return YES;
}
- (void)invalidate {
    if(_invalid)return;_invalid=YES;
    if(_context) {
        CGLContextObj prior=CGLGetCurrentContext();CGLLockContext(_context);CGLSetCurrentContext(_context);
        [self releaseSlots];
        CGLSetCurrentContext(prior);CGLUnlockContext(_context);CGLReleaseContext(_context);_context=NULL;
    }
}
- (void)dealloc { [self invalidate]; }
@end
