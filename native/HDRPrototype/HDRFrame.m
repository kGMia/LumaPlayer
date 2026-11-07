// SPDX-License-Identifier: GPL-3.0-or-later
#import "HDRFrame.h"
#import <AVFoundation/AVFoundation.h>
#include <stdatomic.h>
static NSError *HDRInputError(NSString *message) {
    return [NSError errorWithDomain:@"com.august.lumaplayer.hdrprototype" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL attachmentEquals(CVPixelBufferRef pixels, CFStringRef key, CFStringRef expected) {
    CFTypeRef value=CVBufferCopyAttachment(pixels,key,NULL);
    BOOL equal=value && CFEqual(value,expected);
    if(value) CFRelease(value);
    return equal;
}
@implementation HDRFrame {
    CVPixelBufferRef _pixels;
    CVMetalTextureCacheRef _cache;
    CVMetalTextureRef _y, _uv;
}
- (instancetype)initWithSample:(CMSampleBufferRef)sample device:(id<MTLDevice>)device cache:(CVMetalTextureCacheRef)cache error:(NSError **)error {
    if(!(self=[super init]))return nil;
    CVPixelBufferRef pixels=CMSampleBufferGetImageBuffer(sample);
    if(!pixels || CVPixelBufferGetPixelFormatType(pixels)!=kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
       CVPixelBufferGetPlaneCount(pixels)!=2 || !CVPixelBufferGetIOSurface(pixels)) {
        *error=HDRInputError(@"Requires an IOSurface-backed video-range P010 frame.");return nil;
    }
    _hlg=attachmentEquals(pixels,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_2100_HLG);
    if((!_hlg && !attachmentEquals(pixels,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)) ||
       !attachmentEquals(pixels,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_2020) ||
       !attachmentEquals(pixels,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_2020)) {
        NSDictionary *tags=CFBridgingRelease(CVBufferCopyAttachments(pixels,kCVAttachmentMode_ShouldPropagate));
        *error=HDRInputError([NSString stringWithFormat:@"Requires BT.2020/(PQ or HLG)/BT.2020; decoded tags: %@ / %@ / %@", tags[(__bridge NSString *)kCVImageBufferColorPrimariesKey],tags[(__bridge NSString *)kCVImageBufferTransferFunctionKey],tags[(__bridge NSString *)kCVImageBufferYCbCrMatrixKey]]);return nil;
    }
    size_t width=CVPixelBufferGetWidth(pixels),height=CVPixelBufferGetHeight(pixels);
    CGRect clean=CVImageBufferGetCleanRect(pixels);
    CGSize display=CVImageBufferGetDisplaySize(pixels);
    NSNumber *fields=CFBridgingRelease(CVBufferCopyAttachment(pixels,kCVImageBufferFieldCountKey,NULL));
    if(!width || !height || width>8192 || height>8192 || fields.intValue>1 ||
       !CGRectEqualToRect(clean,CGRectMake(0,0,width,height)) || fabs(display.width/display.height-(double)width/height)>0.001) {
        *error=HDRInputError(@"This stage requires progressive, uncropped, square-pixel frames up to 8192 pixels per side.");return nil;
    }
    NSString *chromaLocation=CFBridgingRelease(CVBufferCopyAttachment(pixels,kCVImageBufferChromaLocationTopFieldKey,NULL));
    if(!chromaLocation || (![chromaLocation isEqualToString:(__bridge NSString *)kCVImageBufferChromaLocation_Left] && ![chromaLocation isEqualToString:(__bridge NSString *)kCVImageBufferChromaLocation_Center])) {
        *error=HDRInputError(@"Only explicitly tagged left or centered chroma siting is supported.");return nil;
    }
    _chromaOffsetX=[chromaLocation isEqualToString:(__bridge NSString *)kCVImageBufferChromaLocation_Left]?0.5f/(float)width:0;
    _pixels=CVPixelBufferRetain(pixels);_aspect=(float)width/height;
    _pts=CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
    (void)device;
    if(cache)_cache=(CVMetalTextureCacheRef)CFRetain(cache);
    CVReturn status=_cache?kCVReturnSuccess:kCVReturnError;
    if(status==kCVReturnSuccess) status=CVMetalTextureCacheCreateTextureFromImage(NULL,_cache,pixels,NULL,MTLPixelFormatR16Unorm,
        CVPixelBufferGetWidthOfPlane(pixels,0),CVPixelBufferGetHeightOfPlane(pixels,0),0,&_y);
    if(status==kCVReturnSuccess) status=CVMetalTextureCacheCreateTextureFromImage(NULL,_cache,pixels,NULL,MTLPixelFormatRG16Unorm,
        CVPixelBufferGetWidthOfPlane(pixels,1),CVPixelBufferGetHeightOfPlane(pixels,1),1,&_uv);
    _luma=_y?CVMetalTextureGetTexture(_y):nil;_chroma=_uv?CVMetalTextureGetTexture(_uv):nil;
    if(status!=kCVReturnSuccess || !_luma || !_chroma) {
        *error=HDRInputError([NSString stringWithFormat:@"P010 Metal texture binding failed (%d).",status]);return nil;
    }
    return self;
}
+ (void)readFirstFrame:(NSURL *)url device:(id<MTLDevice>)device completion:(void (^)(HDRFrame *,NSError *))completion {
    HDRStream *stream=[[HDRStream alloc] initWithURL:url device:device];
    [stream seekTo:0 completion:^(double duration,NSError *error){
        (void)duration;
        if(error) { completion(nil,error);return; }
        [stream readNext:^(HDRFrame *frame,NSError *readError,BOOL eof){
            (void)eof; [stream cancel];
            completion(frame,readError ?: (frame?nil:HDRInputError(@"No decoded frame.")));
        }];
    }];
}
- (void)dealloc {
    if(_y) CFRelease(_y);if(_uv) CFRelease(_uv);if(_cache) CFRelease(_cache);if(_pixels) CVPixelBufferRelease(_pixels);
}
@end

@implementation HDRStream {
    AVURLAsset *_asset;
    id<MTLDevice> _device;
    dispatch_queue_t _queue;
    AVAssetReader *_reader;
    AVAssetReaderTrackOutput *_output;
    atomic_uint_fast64_t _generation;
    double _lastPTS;
    CVMetalTextureCacheRef _textureCache;
    NSUInteger _decoded;
}
- (instancetype)initWithURL:(NSURL *)url device:(id<MTLDevice>)device {
    if(!(self=[super init]))return nil;
    if(url.isFileURL) _asset=[AVURLAsset URLAssetWithURL:url options:nil];
    CVMetalTextureCacheCreate(NULL,NULL,device,NULL,&_textureCache);
    _device=device;_lastPTS=-INFINITY;atomic_init(&_generation,0);
    _queue=dispatch_queue_create("com.august.lumaplayer.hdrprototype.decode",DISPATCH_QUEUE_SERIAL);
    return self;
}
- (void)seekTo:(double)seconds completion:(void (^)(double,NSError *))completion {
    uint64_t generation=atomic_fetch_add(&_generation,1)+1;
    if(!_asset || !isfinite(seconds) || seconds<0) { completion(0,HDRInputError(@"Invalid local media or seek time."));return; }
    [_asset loadTracksWithMediaType:AVMediaTypeVideo completionHandler:^(NSArray<AVAssetTrack *> *tracks,NSError *loadError){
        dispatch_async(self->_queue, ^{ @autoreleasepool {
            if(generation!=atomic_load(&self->_generation))return;
            [self->_reader cancelReading];self->_reader=nil;self->_output=nil;self->_lastPTS=-INFINITY;
            AVAssetTrack *track=tracks.firstObject;
            if(!track) { completion(0,loadError ?: HDRInputError(@"No supported video track."));return; }
            if(!CGAffineTransformIsIdentity(track.preferredTransform)) {
                completion(0,HDRInputError(@"Rotated video is not supported in this prototype."));return;
            }
            for(id description in track.formatDescriptions) {
                CMFormatDescriptionRef format=(__bridge CMFormatDescriptionRef)description;
                NSDictionary *atoms=(__bridge NSDictionary *)CMFormatDescriptionGetExtension(format,kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
                FourCharCode codec=CMFormatDescriptionGetMediaSubType(format);
                if(codec=='dvh1' || codec=='dvhe' || atoms[@"dvcC"] || atoms[@"dvvC"]) {
                    completion(0,[NSError errorWithDomain:@"com.august.lumaplayer.hdrprototype" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Dolby Vision requires system-managed playback."}]);return;
                }
            }
            double duration=CMTimeGetSeconds(self->_asset.duration);
            NSError *error=nil;
            AVAssetReader *reader=[[AVAssetReader alloc] initWithAsset:self->_asset error:&error];
            NSDictionary *settings=@{AVVideoAllowWideColorKey:@YES,(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
                (id)kCVPixelBufferMetalCompatibilityKey:@YES,(id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
            AVAssetReaderTrackOutput *output=[[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
            output.alwaysCopiesSampleData=NO;
            if(!reader || ![reader canAddOutput:output]) { completion(0,error ?: HDRInputError(@"Cannot configure P010 decoding."));return; }
            [reader addOutput:output];
            reader.timeRange=CMTimeRangeMake(CMTimeMakeWithSeconds(seconds,60000),kCMTimePositiveInfinity);
            if(![reader startReading]) { completion(0,reader.error ?: HDRInputError(@"Cannot start decoding."));return; }
            if(generation!=atomic_load(&self->_generation)) { [reader cancelReading];return; }
            self->_reader=reader;self->_output=output;
            completion(isfinite(duration)?duration:0,nil);
        }});
    }];
}
- (void)readNext:(void (^)(HDRFrame *,NSError *,BOOL))completion {
    uint64_t generation=atomic_load(&_generation);
    dispatch_async(_queue, ^{ @autoreleasepool {
        if(generation!=atomic_load(&self->_generation))return;
        if(!self->_output) { completion(nil,HDRInputError(@"Decoder not ready."),NO);return; }
        CMSampleBufferRef sample=[self->_output copyNextSampleBuffer];
        NSError *error=nil;
        HDRFrame *frame=sample?[[HDRFrame alloc] initWithSample:sample device:self->_device cache:self->_textureCache error:&error]:nil;
        if(sample) CFRelease(sample);
        if(generation!=atomic_load(&self->_generation))return;
        if(frame && (!isfinite(frame.pts) || frame.pts<=self->_lastPTS)) {
            frame=nil;error=HDRInputError(@"Invalid or non-increasing presentation timestamp.");
        }
        if(frame) { self->_lastPTS=frame.pts; if(++self->_decoded%120==0)CVMetalTextureCacheFlush(self->_textureCache,0); }
        BOOL eof=!frame && !error && self->_reader.status==AVAssetReaderStatusCompleted;
        if(!frame && !eof && !error)error=self->_reader.error ?: HDRInputError(@"Decoder ended unexpectedly.");
        if(error || eof) { [self->_reader cancelReading];self->_output=nil;self->_reader=nil; }
        completion(frame,error,eof);
    }});
}
- (void)cancel {
    atomic_fetch_add(&_generation,1);
    dispatch_async(_queue, ^{ [self->_reader cancelReading];self->_reader=nil;self->_output=nil; });
}
- (void)dealloc { if(_textureCache)CFRelease(_textureCache); }

@end
