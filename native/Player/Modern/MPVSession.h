// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import "VideoView.h"
NS_ASSUME_NONNULL_BEGIN
@interface MPVSession : NSObject
@property (nonatomic, copy, nullable) void (^onSnapshot)(NSDictionary *snapshot);
- (instancetype)initWithView:(VideoView *)view;
- (void)command:(NSArray<NSString *> *)arguments;
- (void)applyFilters:(NSArray<NSString *> *)filters shader:(nullable NSString *)shader;
// Queue mutations resolve IDs against the live playlist on the client queue.
- (void)playPlaylistID:(int64_t)entryID;
- (void)removePlaylistID:(int64_t)entryID;
- (void)reorderPlaylist:(NSArray<NSNumber *> *)ids;
- (void)appendUniqueFiles:(NSArray<NSString *> *)paths around:(NSString *)selected completion:(void (^)(NSInteger added))completion;
- (void)shutdown;
@end
NS_ASSUME_NONNULL_END
