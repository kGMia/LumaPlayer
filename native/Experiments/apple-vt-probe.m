// SPDX-License-Identifier: GPL-3.0-or-later
// Read-only capability probe; does not claim measured performance.
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <MetalFX/MetalFX.h>
static NSString *fourcc(NSNumber *n){uint32_t v=n.unsignedIntValue;char s[5]={(v>>24)&255,(v>>16)&255,(v>>8)&255,v&255,0};return [NSString stringWithUTF8String:s]?:n.stringValue;}
static NSDictionary *smoke(NSInteger w,NSInteger h){
 if(@available(macOS 26.0,*)){
  NSMutableDictionary *r=[@{@"width":@(w),@"height":@(h),@"scope":@"synthetic NV12 midpoint API smoke; not playback/quality acceptance"} mutableCopy];
  VTLowLatencyFrameInterpolationConfiguration *c=[[VTLowLatencyFrameInterpolationConfiguration alloc]initWithFrameWidth:w frameHeight:h numberOfInterpolatedFrames:1];
  if(!c){r[@"error"]=@"configuration rejected";return r;}
  CVPixelBufferPoolRef inPool=NULL,outPool=NULL;
  CVReturn a=CVPixelBufferPoolCreate(NULL,NULL,(__bridge CFDictionaryRef)c.sourcePixelBufferAttributes,&inPool);
  CVReturn b=CVPixelBufferPoolCreate(NULL,NULL,(__bridge CFDictionaryRef)c.destinationPixelBufferAttributes,&outPool);
  if(a||b){r[@"error"]=@"pool creation failed";if(inPool)CFRelease(inPool);if(outPool)CFRelease(outPool);return r;}
  CVPixelBufferRef src[2]={NULL,NULL},dst=NULL;
  for(int k=0;k<2;k++){
   CVPixelBufferPoolCreatePixelBuffer(NULL,inPool,&src[k]);
   if(!src[k])break;
   CVPixelBufferLockBaseAddress(src[k],0);
   for(size_t plane=0;plane<CVPixelBufferGetPlaneCount(src[k]);plane++){
    unsigned char *base=CVPixelBufferGetBaseAddressOfPlane(src[k],plane);size_t stride=CVPixelBufferGetBytesPerRowOfPlane(src[k],plane),height=CVPixelBufferGetHeightOfPlane(src[k],plane),width=CVPixelBufferGetWidthOfPlane(src[k],plane);
    memset(base,plane?128:16,stride*height);
    if(!plane)for(size_t y=0;y<height;y++)for(size_t x=0;x<width;x++)base[y*stride+x]=16+(((x+k*8)/16+y/16)%2)*180;
   }
   CVPixelBufferUnlockBaseAddress(src[k],0);
   CVBufferSetAttachment(src[k],kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
   CVBufferSetAttachment(src[k],kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
   CVBufferSetAttachment(src[k],kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
  }
  CVPixelBufferPoolCreatePixelBuffer(NULL,outPool,&dst);
  if(!src[0]||!src[1]||!dst){r[@"error"]=@"buffer creation failed";}
  else {
   VTFrameProcessor *processor=[VTFrameProcessor new];NSError *error=nil;double t=NSProcessInfo.processInfo.systemUptime;
   BOOL ok=[processor startSessionWithConfiguration:c error:&error];r[@"start_ms"]=@((NSProcessInfo.processInfo.systemUptime-t)*1000);r[@"started"]=@(ok);
   NSMutableArray *times=[NSMutableArray array];
   if(ok)for(int i=0;i<6;i++){
    VTFrameProcessorFrame *previous=[[VTFrameProcessorFrame alloc]initWithBuffer:src[0] presentationTimeStamp:CMTimeMake(i*2,24)];
    VTFrameProcessorFrame *current=[[VTFrameProcessorFrame alloc]initWithBuffer:src[1] presentationTimeStamp:CMTimeMake(i*2+1,24)];
    VTFrameProcessorFrame *output=[[VTFrameProcessorFrame alloc]initWithBuffer:dst presentationTimeStamp:CMTimeMake(i*4+1,48)];
    VTLowLatencyFrameInterpolationParameters *params=[[VTLowLatencyFrameInterpolationParameters alloc]initWithSourceFrame:current previousFrame:previous interpolationPhase:@[@0.5] destinationFrames:@[output]];
    t=NSProcessInfo.processInfo.systemUptime;ok=params&&[processor processWithParameters:params error:&error];
    [times addObject:@((NSProcessInfo.processInfo.systemUptime-t)*1000)];if(!ok)break;
   }
   r[@"process_ms"]=times;r[@"processed"]=@(ok&&times.count==6);
   if(error){r[@"error"]=error.description;}
   if(ok){CVPixelBufferLockBaseAddress(dst,kCVPixelBufferLock_ReadOnly);unsigned char *base=CVPixelBufferGetBaseAddressOfPlane(dst,0);size_t stride=CVPixelBufferGetBytesPerRowOfPlane(dst,0);uint64_t sum=0;for(int y=0;y<h;y+=16)for(int x=0;x<w;x+=16)sum+=base[y*stride+x];CVPixelBufferUnlockBaseAddress(dst,kCVPixelBufferLock_ReadOnly);r[@"output_luma_sample_sum"]=@(sum);}
   [processor endSession];
  }
  for(int k=0;k<2;k++)if(src[k])CVPixelBufferRelease(src[k]);if(dst)CVPixelBufferRelease(dst);CFRelease(inPool);CFRelease(outPool);return r;
 }
 return @{@"error":@"requires macOS 26"};
}
int main(int argc,const char **argv){@autoreleasepool{
 NSMutableDictionary *result=[NSMutableDictionary dictionary];result[@"os"]=NSProcessInfo.processInfo.operatingSystemVersionString;
 id<MTLDevice> gpu=MTLCreateSystemDefaultDevice();result[@"gpu"]=gpu.name?:@"N/A";
 if(@available(macOS 26.0,*)){
  result[@"low_latency_supported"]=@([VTLowLatencyFrameInterpolationConfiguration isSupported]);
  result[@"metalfx_supported"]=@([MTLFXFrameInterpolatorDescriptor supportsDevice:gpu]);
  NSMutableArray *sizes=[NSMutableArray array];
  for(NSArray *size in @[@[@1280,@720],@[@1920,@1080],@[@3840,@2160]]){
   VTLowLatencyFrameInterpolationConfiguration *c=[[VTLowLatencyFrameInterpolationConfiguration alloc]initWithFrameWidth:[size[0] integerValue] frameHeight:[size[1] integerValue] numberOfInterpolatedFrames:1];
   NSMutableDictionary *r=[@{@"width":size[0],@"height":size[1],@"configuration_created":@(c!=nil)} mutableCopy];
   if(c){NSMutableArray *formats=[NSMutableArray array];for(NSNumber *f in c.frameSupportedPixelFormats)[formats addObject:fourcc(f)];r[@"formats"]=formats;r[@"source_attributes"]=c.sourcePixelBufferAttributes.description;r[@"destination_attributes"]=c.destinationPixelBufferAttributes.description;}
   [sizes addObject:r];
  }
  result[@"sizes"]=sizes;
  NSMutableArray *sr=[NSMutableArray array];
  for(NSArray *size in @[@[@640,@360],@[@960,@540],@[@1280,@720],@[@1920,@1080]]) {
   [sr addObject:@{@"width":size[0],@"height":size[1],@"scales":[VTLowLatencySuperResolutionScalerConfiguration supportedScaleFactorsForFrameWidth:[size[0] integerValue] frameHeight:[size[1] integerValue]]}];
  }
  result[@"low_latency_sr_scales"]=sr;

  if(@available(macOS 27.0,*)){result[@"max_dimension"]=@([VTLowLatencyFrameInterpolationConfiguration maximumDimensionForSpatialScaleFactor:1]);result[@"max_pixels"]=@([VTLowLatencyFrameInterpolationConfiguration maximumPixelCountForSpatialScaleFactor:1]);}
 }
 if(@available(macOS 15.4,*))result[@"frame_rate_conversion_supported"]=@([VTFrameRateConversionConfiguration isSupported]);
 if(argc>1 && strcmp(argv[1],"--process")==0)result[@"midpoint_smoke"]=@[smoke(1280,720),smoke(1920,1080)];
 NSData *data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];puts([[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
}}
