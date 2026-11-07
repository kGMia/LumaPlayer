// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface RemoteMediaProbe : NSObject
- (void)cancel;
// Local metadata fallback: regular files only, no manifests or nested I/O.
- (NSDictionary *)readFile:(NSString *)path cover:(BOOL)cover;
- (nullable NSData *)readAttachedCover:(NSString *)path;
// Blocking utility-thread operation; no window, subprocess, or image files.
- (NSDictionary *)readURL:(NSString *)url options:(NSDictionary<NSString *, NSString *> *)options cover:(BOOL)cover;
@end
NS_ASSUME_NONNULL_END
