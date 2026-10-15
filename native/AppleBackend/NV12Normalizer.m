// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "IIVEApple.h"
#include "NV12NormalizeLibrary.h"

static NSString *const kIIVENV12NormalizeShaderSource =
@"#include <metal_stdlib>\n"
"using namespace metal;\n"
"kernel void normalizeNV12(texture2d<float, access::read> y [[texture(0)]],\n"
"                          texture2d<float, access::sample> uv [[texture(1)]],\n"
"                          texture2d<float, access::write> outY [[texture(2)]],\n"
"                          texture2d<float, access::write> outUV [[texture(3)]],\n"
"                          constant uint3 &options [[buffer(0)]],\n"
"                          uint2 p [[thread_position_in_grid]]) {\n"
"    if (p.x >= outY.get_width() || p.y >= outY.get_height()) return;\n"
"    bool fullRange = options.x != 0;\n"
"    bool leftChroma = options.y != 0;\n"
"    bool tenBit = options.z != 0;\n"
"    float luma = y.read(p).r;\n"
"    if (tenBit) {\n"
"        if (fullRange) {\n"
"            float code10 = luma * (65535.0f / 64.0f);\n"
"            luma = (16.0f + (code10 / 1023.0f) * 219.0f) / 255.0f;\n"
"        } else {\n"
"            luma = luma * (257.0f / 256.0f);\n"
"        }\n"
"    } else if (fullRange) {\n"
"        luma = (16.0f + luma * 219.0f) / 255.0f;\n"
"    }\n"
"    outY.write(float4(clamp(luma, 0.0f, 1.0f), 0, 0, 1), p);\n"
"    if (p.x < outUV.get_width() && p.y < outUV.get_height()) {\n"
"        constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);\n"
"        float2 offset = float2(leftChroma ? 0.25f : 0.0f, 0);\n"
"        float2 at = (float2(p) + 0.5f + offset) / float2(uv.get_width(), uv.get_height());\n"
"        float2 chroma = uv.sample(linearClamp, at).rg;\n"
"        if (tenBit) {\n"
"            if (fullRange) {\n"
"                float2 code10 = chroma * (65535.0f / 64.0f);\n"
"                chroma = (128.0f + (code10 - 512.0f) * (224.0f / 1023.0f)) / 255.0f;\n"
"            } else {\n"
"                chroma = chroma * (257.0f / 256.0f);\n"
"            }\n"
"        } else if (fullRange) {\n"
"            chroma = (128.0f + (chroma * 255.0f - 128.0f) * (224.0f / 255.0f)) / 255.0f;\n"
"        }\n"
"        outUV.write(float4(clamp(chroma, 0.0f, 1.0f), 0, 1), p);\n"
"    }\n"
"}\n";

@interface IIVENormalizer : NSObject
@property id<MTLDevice> device;
@property id<MTLCommandQueue> queue;
@property id<MTLComputePipelineState> pipeline;
@property CVMetalTextureCacheRef textures;
@end
@implementation IIVENormalizer
- (void)dealloc { if (_textures) CFRelease(_textures); }
@end

void *iive_nv12_create(void) { @autoreleasepool {
    IIVENormalizer *engine=[IIVENormalizer new];
    engine.device=MTLCreateSystemDefaultDevice();
    if(!engine.device)return NULL;
    engine.queue=[engine.device newCommandQueue];
    id<MTLLibrary> library=[engine.device newLibraryWithSource:kIIVENV12NormalizeShaderSource options:nil error:nil];
    if(!library) {
        dispatch_data_t bytes=dispatch_data_create(iive_nv12_library,sizeof(iive_nv12_library),NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        library=[engine.device newLibraryWithData:bytes error:nil];
    }
    id<MTLFunction> function=[library newFunctionWithName:@"normalizeNV12"];
    if(!function || !engine.queue)return NULL;
    engine.pipeline=[engine.device newComputePipelineStateWithFunction:function error:nil];
    CVMetalTextureCacheRef textures=NULL;
    if(!engine.pipeline || CVMetalTextureCacheCreate(NULL,NULL,engine.device,NULL,&textures)!=kCVReturnSuccess)return NULL;
    engine.textures=textures;
    return (__bridge_retained void *)engine;
}}

bool iive_nv12_normalize(void *handle,CVPixelBufferRef source,CVPixelBufferRef destination,bool fullRange,bool leftChroma) { @autoreleasepool {
    if(!handle || !source || !destination || source==destination)return false;
    IIVENormalizer *engine=(__bridge IIVENormalizer *)handle;
    size_t w=CVPixelBufferGetWidth(source),h=CVPixelBufferGetHeight(source);
    OSType sourceFmt=CVPixelBufferGetPixelFormatType(source);
    OSType expected8=fullRange?kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    OSType expected10=fullRange?kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    bool tenBit=(sourceFmt==expected10);
    if(!w || !h || w%2 || h%2 || (sourceFmt!=expected8 && !tenBit) ||
       CVPixelBufferGetPixelFormatType(destination)!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
       CVPixelBufferGetWidth(destination)!=w || CVPixelBufferGetHeight(destination)!=h ||
       CVPixelBufferGetPlaneCount(source)!=2 || CVPixelBufferGetPlaneCount(destination)!=2 ||
       !CVPixelBufferGetIOSurface(source) || !CVPixelBufferGetIOSurface(destination))return false;
    CVMetalTextureRef refs[4]={0};
    id<MTLTexture> textures[4];
    bool ok=true;
    for(int i=0;i<4;i++) {
        CVPixelBufferRef pixels=i<2?source:destination;
        int plane=i%2;
        bool isSource=(i<2);
        MTLPixelFormat mtlFmt;
        if(isSource && tenBit) {
            mtlFmt=plane?MTLPixelFormatRG16Unorm:MTLPixelFormatR16Unorm;
        } else {
            mtlFmt=plane?MTLPixelFormatRG8Unorm:MTLPixelFormatR8Unorm;
        }
        NSDictionary *attrs=@{(__bridge NSString *)kCVMetalTextureUsage:@(isSource?MTLTextureUsageShaderRead:MTLTextureUsageShaderWrite)};
        CVReturn result=CVMetalTextureCacheCreateTextureFromImage(NULL,engine.textures,pixels,(__bridge CFDictionaryRef)attrs,
            mtlFmt,
            CVPixelBufferGetWidthOfPlane(pixels,plane),CVPixelBufferGetHeightOfPlane(pixels,plane),plane,&refs[i]);
        if(result!=kCVReturnSuccess || !refs[i] || !(textures[i]=CVMetalTextureGetTexture(refs[i]))){ok=false;break;}
    }
    if(ok) {
        id<MTLCommandBuffer> command=[engine.queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        if(!command || !encoder)ok=false;
        else {
            command.label=@"IIVE NV12/P010 range/chroma normalization";
            [encoder setComputePipelineState:engine.pipeline];
            for(int i=0;i<4;i++)[encoder setTexture:textures[i] atIndex:i];
            uint32_t options[4]={fullRange?1u:0u,leftChroma?1u:0u,tenBit?1u:0u,0u};
            [encoder setBytes:options length:sizeof(options) atIndex:0];
            NSUInteger x=engine.pipeline.threadExecutionWidth;
            NSUInteger y=MIN(8,engine.pipeline.maxTotalThreadsPerThreadgroup/x);
            [encoder dispatchThreads:MTLSizeMake(w,h,1) threadsPerThreadgroup:MTLSizeMake(x,y,1)];
            [encoder endEncoding];[command commit];[command waitUntilCompleted];
            ok=command.status==MTLCommandBufferStatusCompleted;
        }
    }
    // Keep all CVMetalTexture wrappers alive until GPU completion.
    for(int i=0;i<4;i++)if(refs[i])CFRelease(refs[i]);
    if(ok) {
        CVBufferSetAttachment(destination,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(destination,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(destination,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(destination,kCVImageBufferChromaLocationTopFieldKey,kCVImageBufferChromaLocation_Center,kCVAttachmentMode_ShouldPropagate);
    }
    return ok;
}}
void iive_nv12_destroy(void *handle) { if(handle){id released=CFBridgingRelease(handle);(void)released;} }
