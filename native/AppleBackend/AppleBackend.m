// SPDX-License-Identifier: GPL-3.0-or-later
#import <VideoToolbox/VideoToolbox.h>
#import "IIVEApple.h"
@interface AppleEngine : NSObject
@property VTFrameProcessor *processor;
@property BOOL interpolation;
@property CVPixelBufferPoolRef inputs;
@property CVPixelBufferPoolRef outputs;
@end
@implementation AppleEngine
- (void)dealloc {
    [_processor endSession];
    if (_inputs) CFRelease(_inputs);
    if (_outputs) CFRelease(_outputs);
}
@end
void *iive_apple_create(int w, int h, int fi, float scale) { @autoreleasepool {
    id<VTFrameProcessorConfiguration> config;
    if (fi) {
        if (![VTLowLatencyFrameInterpolationConfiguration isSupported] ||
            MAX(w,h)>[VTLowLatencyFrameInterpolationConfiguration maximumDimensionForSpatialScaleFactor:1] ||
            (int64_t)w*h>[VTLowLatencyFrameInterpolationConfiguration maximumPixelCountForSpatialScaleFactor:1]) return NULL;
        config=[[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:w frameHeight:h numberOfInterpolatedFrames:1];
    } else {
        if (![VTLowLatencySuperResolutionScalerConfiguration isSupported] ||
            ![[VTLowLatencySuperResolutionScalerConfiguration supportedScaleFactorsForFrameWidth:w frameHeight:h] containsObject:@(scale)]) return NULL;
        config=[[VTLowLatencySuperResolutionScalerConfiguration alloc] initWithFrameWidth:w frameHeight:h scaleFactor:scale];
    }
    if (!config || ![config.frameSupportedPixelFormats containsObject:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)]) return NULL;
    AppleEngine *engine=[AppleEngine new];engine.interpolation=fi;
    CVPixelBufferPoolRef inputs=NULL,outputs=NULL;
    CVReturn a=CVPixelBufferPoolCreate(NULL,NULL,(__bridge CFDictionaryRef)config.sourcePixelBufferAttributes,&inputs);
    CVReturn b=CVPixelBufferPoolCreate(NULL,NULL,(__bridge CFDictionaryRef)config.destinationPixelBufferAttributes,&outputs);
    engine.inputs=inputs;engine.outputs=outputs;if (a || b) return NULL;
    engine.processor=[VTFrameProcessor new];NSError *error;
    if (![engine.processor startSessionWithConfiguration:config error:&error]) {
        NSLog(@"IIVE Apple session unavailable: %@",error);return NULL;
    }
    return (__bridge_retained void *)engine;
}}
CVPixelBufferRef iive_apple_input(void *handle) {
    if (!handle) return NULL;
    AppleEngine *engine=(__bridge AppleEngine *)handle;
    CVPixelBufferRef pixels=NULL;
    CVPixelBufferPoolCreatePixelBuffer(NULL,engine.inputs,&pixels);
    return pixels;
}
CVPixelBufferRef iive_apple_process(void *handle,CVPixelBufferRef current,CVPixelBufferRef previous,double pts,double prev) { @autoreleasepool {
    if (!handle || !current) return NULL;
    AppleEngine *engine=(__bridge AppleEngine *)handle;
    CVPixelBufferRef output=NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL,engine.outputs,&output)) return NULL;
    VTFrameProcessorFrame *source=[[VTFrameProcessorFrame alloc] initWithBuffer:current presentationTimeStamp:CMTimeMakeWithSeconds(pts,1000000)];
    VTFrameProcessorFrame *destination=[[VTFrameProcessorFrame alloc] initWithBuffer:output presentationTimeStamp:CMTimeMakeWithSeconds(engine.interpolation?(pts+prev)/2:pts,1000000)];
    id<VTFrameProcessorParameters> parameters;
    if (engine.interpolation && previous) {
        VTFrameProcessorFrame *reference=[[VTFrameProcessorFrame alloc] initWithBuffer:previous presentationTimeStamp:CMTimeMakeWithSeconds(prev,1000000)];
        parameters=[[VTLowLatencyFrameInterpolationParameters alloc] initWithSourceFrame:source previousFrame:reference interpolationPhase:@[@0.5] destinationFrames:@[destination]];
    } else if (!engine.interpolation) {
        parameters=[[VTLowLatencySuperResolutionScalerParameters alloc] initWithSourceFrame:source destinationFrame:destination];
    }
    NSError *error;
    if (!parameters || ![engine.processor processWithParameters:parameters error:&error]) {
        NSLog(@"IIVE Apple frame failed: %@",error);CVPixelBufferRelease(output);return NULL;
    }
    CVBufferPropagateAttachments(current,output);
    return output;
}}
void iive_apple_destroy(void *handle) { if (handle) { id released=CFBridgingRelease(handle);(void)released; } }

void iive_apple_trim(void *handle) {
    if (!handle) return;
    AppleEngine *engine=(__bridge AppleEngine *)handle;
    CVPixelBufferPoolFlush(engine.inputs,kCVPixelBufferPoolFlushExcessBuffers);
    CVPixelBufferPoolFlush(engine.outputs,kCVPixelBufferPoolFlushExcessBuffers);
}
