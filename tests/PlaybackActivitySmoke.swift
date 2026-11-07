// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main struct PlaybackActivitySmoke {
    static func main() {
        var snapshot: [String: Any] = [:]
        func phase(pending: Bool = false, scrubbing: Bool = false) -> PlaybackActivity {
            PlaybackActivity.resolve(snapshot, pendingSeek: pending, scrubbing: scrubbing)
        }
        precondition(phase() == .idle)
        snapshot = ["media-opening": true, "eof-reached": true, "pause": true, "error": "old error"]
        precondition(phase() == .opening && !phase().showsError)
        snapshot = ["media-loaded": true, "media-started": false]
        precondition(phase() == .starting && !phase().allowsMediaNotice)
        snapshot["enhancement-warming"] = true
        precondition(phase() == .warming)
        snapshot["paused-for-cache"] = true
        precondition(phase() == .buffering) // Exactly one progress message.
        snapshot["network-reconnecting"] = true
        snapshot["network-retry-available"] = true
        precondition(phase() == .reconnecting && !phase().showsError)
        snapshot["network-reconnecting"] = false
        precondition(phase() == .failed && phase().showsError)

        // A new ready media snapshot cannot retain prior-file activity.
        snapshot = ["media-loaded": true, "media-started": true, "pause": false]
        precondition(phase() == .playing && phase().allowsMediaNotice)
        precondition(phase(pending: true) == .seeking) // Before mpv acknowledges seek.
        precondition(phase(scrubbing: true) == .seeking)
        snapshot["seeking"] = true
        precondition(phase() == .seeking)
        snapshot["seeking"] = false
        snapshot["pause"] = true
        precondition(phase() == .paused && phase().allowsMediaNotice)
        snapshot["eof-reached"] = true
        precondition(phase() == .ended && phase().interruptionReason != nil)
        precondition(phase(pending: true) == .seeking) // Replay seek beats stale EOF.

        snapshot = ["media-loaded": false, "paused-for-cache": true, "enhancement-warming": true]
        precondition(phase() == .idle) // Unloaded flags cannot leave a spinner stuck.
        snapshot["error"] = "Cannot open media"
        precondition(phase() == .failed)

        var gate = PlaybackContinuityGate()
        precondition(gate.update(now: 0, interruption: nil))
        precondition(!gate.update(now: 1, interruption: PlaybackActivity.seeking.interruptionReason))
        precondition(!gate.update(now: 2, interruption: PlaybackActivity.playing.interruptionReason))
        precondition(gate.update(now: 3, interruption: PlaybackActivity.playing.interruptionReason))
        precondition(!gate.update(now: 4, interruption: PlaybackActivity.ended.interruptionReason))
        precondition(PlaybackActivity.seeking.progressMessage(paused: false, retryAttempt: 0) == nil)
        precondition(PlaybackActivity.warming.progressMessage(paused: true, retryAttempt: 0)?.contains("staying paused") == true)
        var transition = MediaSwitchPresentation()
        precondition(!transition.hasOpened && !transition.active)
        let first: [String: Any] = ["media-epoch": 1, "media-loaded": true, "media-started": true]
        transition.update(first, now: 0)
        precondition(transition.hasOpened && !transition.active)
        transition.begin(epoch: 1, now: 1)
        transition.update(first, now: 1.1) // queued old-file snapshot
        precondition(transition.active)
        transition.update(["media-epoch": 2, "media-opening": true], now: 1.2)
        transition.update(["media-epoch": 2, "media-loaded": true], now: 1.3)
        precondition(transition.active) // wait for playback restart, not FILE_LOADED alone
        transition.update(["media-epoch": 2, "media-loaded": true, "media-started": true], now: 1.4)
        precondition(!transition.active)
        transition.update([:], now: 2) // automatic EOF -> next-file gap
        precondition(transition.active)
        transition.update([:], now: 2.4)
        precondition(!transition.active && transition.hasOpened)
        transition.begin(epoch: 2, now: 3)
        transition.update(["error": "Unavailable"], now: 3.2)
        precondition(!transition.active)
        transition.begin(epoch: 1, now: 4)
        transition.update(first, now: 9.1) // rejected/no-op request is bounded
        precondition(!transition.active)
        transition.begin(epoch: 1, now: 10)
        transition.update(["media-epoch": 1, "network-reconnecting": true], now: 20)
        precondition(transition.active) // genuine slow network is not timed out by UI
        transition.stop()
        transition.update(first, now: 21)
        transition.update([:], now: 21.1)
        precondition(!transition.active)
        precondition(!EnhancementInputReadiness.ready(source: [:], fps: nil, started: false))
        precondition(!EnhancementInputReadiness.ready(source: [:], fps: 30, started: true))
        let video: [String: Any] = ["w": 1920, "h": 1080]
        precondition(EnhancementInputReadiness.ready(source: video, fps: 30, started: false))
        precondition(!EnhancementInputReadiness.ready(source: video, fps: nil, started: false))
        precondition(EnhancementInputReadiness.ready(source: video, fps: nil, started: true))
        precondition(!EnhancementInputReadiness.ready(source: ["w": Double.nan, "h": 1080], fps: 30, started: true))
        print("PASS: incomplete decoder metadata defers planning; unknown-rate started video remains supported")
        print("PASS: load/reconnect priority, exclusive progress, first-frame readiness, pending seeks, pause/EOF, stale flags, protection grace")
        print("PASS: media switch epochs, first-frame handoff, automatic advance grace, error/stop/no-op and network transitions")
    }
}
