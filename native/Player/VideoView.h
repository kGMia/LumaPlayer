// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#include <mpv/client.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

NS_ASSUME_NONNULL_BEGIN

@interface VideoView : NSOpenGLView
@property (nonatomic, copy, nullable) void (^onSingleClick)(void);
@property (nonatomic, copy, nullable) void (^onDoubleClick)(void);
- (BOOL)startRenderer:(mpv_handle *)mpv;
- (void)stopRenderer;
- (uint64_t)renderCount;
- (NSSize)pixelSize;
- (void)prepareForWindowTransition:(void (^)(void))completion;
- (void)finishWindowTransition;
- (void)setICCProfileData:(NSData * _Nullable)data completion:(void (^ _Nonnull)(BOOL accepted))completion;
@end

NS_ASSUME_NONNULL_END

#pragma clang diagnostic pop
