// SPDX-License-Identifier: GPL-3.0-or-later
// Deterministic state checks only: no player, GUI, or video is launched.
import Foundation

@main struct TimelineSeekSmoke {
    @MainActor static func main() {
        let timeline = PlayerTimelineState()
        func sample(_ position: Double?, _ id: String? = nil, seeking: Bool = false,
                    result: Int? = nil, path: String = "movie", now: Double = 1) -> PlayerTimelineState.SeekOutcome? {
            timeline.update(position: position, duration: 100, path: path, seeking: seeking,
                            requestID: id, commandResult: result, speed: 1, now: now)
        }
        _ = sample(10)
        let first = timeline.beginSeek(to: 80, path: "movie", now: 1)!
        _ = sample(11, now: 1.25)
        precondition(timeline.presentationPosition == 80 && timeline.position == 11)
        _ = sample(11, first.id, result: 0, now: 1.5)
        precondition(timeline.pendingSeek?.id == first.id) // accepted is not completed

        let second = timeline.beginSeek(to: 20, path: "movie", now: 2)!
        _ = sample(20, first.id, result: 0, now: 2.1)
        precondition(timeline.pendingSeek?.id == second.id) // old acknowledgment cannot win
        _ = sample(11, second.id, seeking: true, result: 0, now: 2.2)
        precondition(timeline.presentationPosition == 20)
        _ = sample(20.1, second.id, result: 0, now: 2.5)
        precondition(timeline.pendingSeek == nil && timeline.presentationPosition == 20.1)

        let fast = timeline.beginSeek(to: 50, path: "movie", now: 3)!
        _ = sample(50, fast.id, result: 0, now: 3.25)
        precondition(timeline.pendingSeek == nil) // short/paused seek between polls
        let failed = timeline.beginSeek(to: 80, path: "movie", now: 4)!
        precondition(sample(50, failed.id, result: -12, now: 4.25) == .failed)
        precondition(timeline.presentationPosition == 50)
        let stalled = timeline.beginSeek(to: 80, path: "movie", now: 5)!
        _ = sample(nil, stalled.id, result: 0, now: 5.5)
        precondition(timeline.position == 50 && timeline.presentationPosition == 80)
        precondition(sample(nil, stalled.id, result: 0, now: 13) == .timedOut)
        precondition(timeline.presentationPosition == 50)

        _ = timeline.beginSeek(to: 80, path: "movie", now: 14)
        _ = sample(nil, path: "another movie", now: 14.25)
        precondition(timeline.pendingSeek == nil && timeline.position == 0)
        precondition(timeline.beginSeek(to: .nan, path: "another movie") == nil)
        precondition(timeline.beginSeek(to: 200, path: "another movie")?.target == 100)
        precondition(timeline.beginSeek(to: -20, path: "another movie")?.target == 0)
        timeline.reset()
        precondition(timeline.pendingSeek == nil && timeline.position == 0 && timeline.duration == 0)
        print("PASS: stale clocks, request ordering, completion, short/paused seek, failure, timeout, missing clock, file change, bounds, reset")
    }
}
