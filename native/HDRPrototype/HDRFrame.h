// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
NS_ASSUME_NONNULL_BEGIN
/// Immutable texture owners. Retain this object through command completion.
@interface HDRFrame : NSObject
@property(nonatomic,readonly) id<MTLTexture> luma;
@property(nonatomic,readonly) id<MTLTexture> chroma;
@property(nonatomic,readonly) float aspect;
@property(nonatomic,readonly) float chromaOffsetX;
@property(nonatomic,readonly) double pts;
@property(nonatomic,readonly) BOOL hlg;
+ (void)readFirstFrame:(NSURL *)url device:(id<MTLDevice>)device
           completion:(void (^)(HDRFrame * _Nullable, NSError * _Nullable))completion;
@end
NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN
/// Serial pull decoder. Caller permits only one outstanding read; cancellation never waits on the UI thread.
@interface HDRStream : NSObject
- (instancetype)initWithURL:(NSURL *)url device:(id<MTLDevice>)device;
- (void)seekTo:(double)seconds completion:(void (^)(double duration, NSError * _Nullable error))completion;
- (void)readNext:(void (^)(HDRFrame * _Nullable frame, NSError * _Nullable error, BOOL eof))completion;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
