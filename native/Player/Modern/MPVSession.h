// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import "VideoView.h"
NS_ASSUME_NONNULL_BEGIN
@interface MPVSession : NSObject
@property (nonatomic, copy, nullable) void (^onSnapshot)(NSDictionary *snapshot);
@property (nonatomic, copy, nullable) void (^onResolveNetwork)(NSString *key, uint64_t hookID);
@property (nonatomic, copy, nullable) void (^onPrepareLocal)(NSString *path, uint64_t hookID);
- (void)finishLocalHook:(uint64_t)hookID options:(NSDictionary<NSString *, NSString *> *)options;
- (void)finishNetworkHook:(uint64_t)hookID url:(nullable NSString *)url options:(NSDictionary<NSString *, NSString *> *)options error:(nullable NSString *)error;
- (instancetype)initWithView:(VideoView *)view;
- (void)configureColorOutput:(NSArray<NSArray<NSString *> *> *)commands completion:(void (^)(BOOL accepted))completion;
- (void)command:(NSArray<NSString *> *)arguments;
- (void)selectPreferredAudioDevice:(NSString *)device;
- (void)configureTrackPreferences:(NSDictionary<NSString *, NSString *> *)options;
- (void)setLoopPoint:(NSString *)point expectedEpoch:(uint64_t)epoch;
- (void)setVideoGeometry:(NSString *)option value:(NSString *)value expectedEpoch:(uint64_t)epoch;
- (void)loadRemoteQueue:(NSArray<NSString *> *)keys selected:(NSInteger)selected append:(BOOL)append;
- (void)enqueueRemoteNext:(NSArray<NSString *> *)keys;
- (void)retryNetworkPlaybackForPath:(NSString *)path NS_SWIFT_NAME(retryNetworkPlayback(forPath:));
- (void)loadNetworkURL:(NSString *)url options:(NSDictionary<NSString *, NSString *> *)options append:(BOOL)append;
- (void)seekToSeconds:(double)seconds expectedPath:(NSString *)path requestID:(NSString *)requestID;
// Bounded interactive requests; final positioning still uses seekToSeconds.
- (void)previewScrubTo:(double)seconds expectedPath:(NSString *)path NS_SWIFT_NAME(previewScrub(to:expectedPath:));
- (void)cancelScrubForPath:(NSString *)path NS_SWIFT_NAME(cancelScrub(forPath:));
- (void)updateSplit:(double)ratio expectedPath:(NSString *)path NS_SWIFT_NAME(updateSplit(_:expectedPath:));
- (void)saveFrameTo:(NSString *)destination expectedPath:(NSString *)path completion:(void (^)(NSString * _Nullable error))completion;
- (void)saveSourceFrameTo:(NSString *)destination expectedPath:(NSString *)path completion:(void (^)(NSString * _Nullable error))completion;
- (void)applyFilters:(NSArray<NSString *> *)filters shader:(nullable NSString *)shader;
- (void)setRIFEPerformanceState:(NSDictionary<NSString *, NSString *> *)state;
// Display-only sampling. Playback safety and diagnostic recording stay at 4 Hz.
- (void)setDetailedTelemetryEnabled:(BOOL)enabled;
// Queue mutations resolve IDs against the live playlist on the client queue.
- (void)playPlaylistID:(int64_t)entryID;
- (void)removePlaylistID:(int64_t)entryID;
- (void)reorderPlaylist:(NSArray<NSNumber *> *)ids expectedNextRevision:(uint64_t)revision;
- (void)appendUniqueFiles:(NSArray<NSString *> *)paths around:(NSString *)selected completion:(void (^)(NSInteger added))completion;
// Callback runs on the client queue, never a real-time audio callback.
- (void)setCaptionAudioEnabled:(BOOL)enabled handler:(nullable void (^)(NSDictionary *packet))handler;
- (void)loadSubtitle:(NSString *)path secondary:(BOOL)secondary;
- (nullable NSString *)activeMetricsPath;
- (void)startMetricsRecordingToPath:(NSString *)path completion:(void (^)(NSString * _Nullable error))completion NS_SWIFT_NAME(startMetricsRecording(to:completion:));
- (void)stopMetricsRecordingWithCompletion:(void (^)(NSInteger samples, NSString * _Nullable path))completion NS_SWIFT_NAME(stopMetricsRecording(completion:));
- (void)shutdown;
@end
NS_ASSUME_NONNULL_END
