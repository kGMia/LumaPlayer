// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#import <CoreGraphics/CoreGraphics.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>

NS_ASSUME_NONNULL_BEGIN
/// Isolated research prototype, NOT connected to the player after reported hangs.
/// Its nextDrawable/drain waits must be redesigned before application integration.
/// Experimental IOSurface (RGBA16F) OpenGL -> CAMetalLayer EDR presenter.
/// Caller supplies extended-linear pixels, drives pending presentation via
/// poll/drain callbacks when paused, and reverts mpv color parameters on fallback.
@interface IIVEEDRBridge : NSObject
@property(nonatomic, readonly) CAMetalLayer *layer;
/// Invoked by Metal after actual drawable presentation; not on a UI queue.
@property(nonatomic, copy, nullable) void (^onFramePresented)(void);
@property(nonatomic, readonly) CGSize pixelSize;
@property(nonatomic, readonly) CGFloat maximumEDRHeadroom;
@property(nonatomic, readonly) CGFloat sourcePeakNits;
@property(nonatomic, readonly) BOOL hasPendingFrames;
@property(nonatomic, readonly, nullable) NSError *failure;
- (nullable instancetype)initWithContext:(CGLContextObj)context
                                  width:(NSUInteger)width height:(NSUInteger)height
                                  error:(NSError * _Nullable * _Nullable)error;
/// Updates target display headroom (>= 1.0), source peak nits, and extended linear color space.
- (void)updateDisplayHeadroom:(CGFloat)headroom
               sourcePeakNits:(CGFloat)sourcePeakNits
               colorSpaceName:(nullable CFStringRef)colorSpaceName;
/// Safely drains in-flight slots and resizes the RGBA16F IOSurface ring and CAMetalLayer drawable.
- (BOOL)resizeToWidth:(NSUInteger)width height:(NSUInteger)height;
/// Returns a nonzero offscreen FBO, or zero when both slots are occupied.
- (GLuint)beginFrame;
/// Call after rendering into the FBO. Inserts GL fence + flush, without waiting.
- (void)endFrame;
/// Polls GL fences with zero timeout and maps/presents a completed GL frame to CAMetalLayer.
- (BOOL)presentReadyFrame;
/// Drains both APIs before releasing surfaces. Resize also uses this blocking drain.
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
