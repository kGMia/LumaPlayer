// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#include <mpv/client.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

NS_ASSUME_NONNULL_BEGIN

@interface VideoView : NSOpenGLView
@property (nonatomic, copy, nullable) void (^onSingleClick)(void);
@property (nonatomic, copy, nullable) void (^onDoubleClick)(void);
@property (nonatomic, copy, nullable) void (^onScrollVolume)(double delta);
@property (nonatomic, copy, nullable) void (^onScrollSeek)(double deltaSeconds);
@property (nonatomic, copy, nullable) void (^onMagnify)(double magnification);
@property (nonatomic, copy, nullable) NSMenu * _Nullable (^contextMenuProvider)(void);
- (BOOL)startRenderer:(mpv_handle *)mpv;
- (void)stopRenderer;
- (uint64_t)renderCount;
- (NSDictionary *)renderTiming;
- (void)resetRenderTiming;
- (void)beginMediaRenderObservation:(uint64_t)epoch;
- (NSDictionary *)mediaRenderObservation;
- (NSSize)pixelSize;
- (void)setLuminanceSamplingEnabled:(BOOL)enabled;
// Approximate displayed-canvas brightness for chrome only; NaN until sampled.
- (double)presentationLuminance;
- (void)prepareForWindowTransition:(void (^)(void))completion;
- (void)finishWindowTransition;
- (void)setICCProfileData:(NSData * _Nullable)data completion:(void (^ _Nonnull)(BOOL accepted))completion;
@end

NS_ASSUME_NONNULL_END

#pragma clang diagnostic pop
