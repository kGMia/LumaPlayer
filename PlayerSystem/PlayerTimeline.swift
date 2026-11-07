// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation

/// Presentation may lead the decoder during an explicit seek. The measured
/// clock remains separate for history, subtitles, telemetry, and screenshots.
@MainActor @Observable final class PlayerTimelineState {
    struct PendingSeek: Equatable {
        let id: String
        let target: Double
        let issuedAt: Double
        var observedSeeking = false
    }
    enum SeekOutcome { case failed, timedOut }
    private(set) var position = 0.0
    private(set) var duration = 0.0
    private(set) var pendingSeek: PendingSeek?
    @ObservationIgnored private var mediaPath = ""
    var presentationPosition: Double { pendingSeek?.target ?? position }

    @discardableResult
    func beginSeek(to target: Double, path: String, now: Double = ProcessInfo.processInfo.systemUptime) -> PendingSeek? {
        guard target.isFinite, duration > 0, !path.isEmpty else { return nil }
        let request = PendingSeek(id: UUID().uuidString, target: min(duration, max(0, target)), issuedAt: now)
        mediaPath = path
        pendingSeek = request
        return request
    }

    @discardableResult
    func update(position nextPosition: Double?, duration nextDuration: Double, path: String,
                seeking: Bool, requestID: String?, commandResult: Int?, speed: Double,
                now: Double = ProcessInfo.processInfo.systemUptime) -> SeekOutcome? {
        if path != mediaPath {
            mediaPath = path; cancelSeek()
            if position != 0 { position = 0 }
        }
        let validDuration = nextDuration.isFinite ? max(0, nextDuration) : 0
        if abs(duration - validDuration) > 0.001 { duration = validDuration }
        let actual = nextPosition.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if let actual, abs(position - actual) > 0.001 { position = actual }
        guard var pending = pendingSeek else { return nil }
        if requestID == pending.id {
            if let commandResult, commandResult < 0 {
                cancelSeek(); return .failed
            }
            if commandResult != nil {
                if seeking, !pending.observedSeeking {
                    pending.observedSeeking = true
                    pendingSeek = pending
                }
                // Short seeks may finish between two 250 ms polls. Otherwise
                // observe the transition out of seeking and accept the real clock.
                let tolerance = max(0.15, min(2, abs(speed.isFinite ? speed : 1) * 0.35))
                if !seeking, let actual,
                   pending.observedSeeking || abs(actual - pending.target) <= tolerance {
                    cancelSeek(); return nil
                }
            }
        }
        // A command failure/stall must never pin the UI to an invented clock forever.
        if now - pending.issuedAt >= 8 { cancelSeek(); return .timedOut }
        return nil
    }

    func cancelSeek() { if pendingSeek != nil { pendingSeek = nil } }
    func reset() {
        cancelSeek(); mediaPath = ""
        if position != 0 { position = 0 }
        if duration != 0 { duration = 0 }
    }
}

/// Previous skips within the shorter of ten seconds and a quarter of the item.
enum PreviousMediaPolicy {
    static func isNearBeginning(position: Double, duration: Double) -> Bool {
        guard position.isFinite else { return true }
        let threshold = duration.isFinite && duration > 0 ? min(10, duration / 4) : 10
        return position < threshold
    }
}

/// Uses a playback epoch, not the filename: consecutive queue entries can refer
/// to the same URL. Seeks and metadata changes do not restart the notice timer.
struct MediaTitleNotice {
    private var epoch: UInt64?
    private var expires: Double?
    mutating func update(epoch: UInt64, ready: Bool, title: String, now: Double, hovering: Bool = false) -> String {
        if self.epoch != epoch { self.epoch = epoch; expires = nil }
        guard ready else { return "" }
        if expires == nil { expires = now + 2.3 }
        if hovering { expires = max(expires!, now + 0.5) }
        return now < expires! ? title : ""
    }
}
