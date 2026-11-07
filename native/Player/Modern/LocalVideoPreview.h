// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
NS_ASSUME_NONNULL_BEGIN
@interface IIVELocalPreviewFrame : NSObject
@property(nonatomic, readonly) CGImageRef image;
@property(nonatomic, readonly) double seconds;
- (instancetype)initWithImage:(CGImageRef)image seconds:(double)seconds;
@end
// One utility-queue reader per timeline, with one open local MKV/WebM decoder.
// read/close must be serialized; cancel is atomic and terminal for this instance.
@interface IIVELocalVideoPreview : NSObject
- (nullable IIVELocalPreviewFrame *)readPath:(NSString *)path seconds:(double)seconds;
- (void)close;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
