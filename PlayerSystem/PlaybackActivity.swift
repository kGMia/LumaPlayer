// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// FILE_LOADED can precede decoder parameters, especially when resuming a file.
/// Never substitute video-out-params: it can still describe the previous file.
enum EnhancementInputReadiness {
    static func ready(source: [String: Any], fps: Double?, started: Bool) -> Bool {
        guard let w = (source["w"] as? NSNumber)?.doubleValue,
              let h = (source["h"] as? NSNumber)?.doubleValue,
              w.isFinite, h.isFinite, w > 0, h > 0 else { return false }
        // Unknown-rate video remains supported once playback has started.
        return started || (fps.map { $0.isFinite && $0 > 0 } ?? false)
    }
}

/// Presentation-only state: never controls engine pause/seek. A request is tied
/// to its old epoch so an already queued old-file snapshot cannot dismiss it.
struct MediaSwitchPresentation: Equatable {
    private(set) var hasOpened = false
    private(set) var active = false
    private var requestedEpoch: UInt64?
    private var requestedAt = 0.0
    private var graceUntil = 0.0
    private var wasLoaded = false
    private var explicitlyStopped = false

    mutating func begin(epoch: UInt64, now: Double) {
        hasOpened = true; active = true; requestedEpoch = epoch; requestedAt = now; explicitlyStopped = false
    }
    mutating func stop() {
        active = false; requestedEpoch = nil; graceUntil = 0; wasLoaded = false; explicitlyStopped = true
    }
    mutating func update(_ snapshot: [String: Any], now: Double) {
        let epoch = (snapshot["media-epoch"] as? NSNumber)?.uint64Value ?? 0
        let loaded = snapshot["media-loaded"] as? Bool == true
        let activity = PlaybackActivity.resolve(snapshot)
        if activity == .opening || activity == .reconnecting { explicitlyStopped = false }
        if explicitlyStopped { return }
        if loaded || activity == .opening || activity == .reconnecting { hasOpened = true }
        if let old = requestedEpoch, epoch != old { requestedEpoch = nil }
        if activity == .failed { stop(); return }
        // Bound a rejected/no-op navigation request. Real opening/reconnection
        // remains visible for as long as the engine reports it (including network).
        if requestedEpoch != nil && now - requestedAt >= 5 && !activity.isBusy { requestedEpoch = nil }
        if wasLoaded && !loaded && requestedEpoch == nil { graceUntil = now + 0.35 }
        wasLoaded = loaded
        let preparing = [.opening, .starting, .reconnecting, .warming].contains(activity)
        active = requestedEpoch != nil || preparing || (!loaded && now < graceUntil)
        if loaded && !preparing && requestedEpoch == nil { graceUntil = 0; active = false }
    }
}

/// One presentation state from one engine snapshot. Engine facts remain intact:
/// this resolver never pauses, seeks, or resumes playback on its own.
enum PlaybackActivity: String {
    case idle, opening, starting, reconnecting, failed, buffering, seeking, warming
    case paused, playing, ended

    static func resolve(_ snapshot: [String: Any], pendingSeek: Bool = false,
                        scrubbing: Bool = false) -> Self {
        func flag(_ name: String) -> Bool { snapshot[name] as? Bool == true }
        // Reconnection can retain the previous path/frame while unloading. Old
        // cache/EOF/pause flags must not win over the current load operation.
        if flag("network-reconnecting") { return .reconnecting }
        if flag("media-opening") { return .opening }
        if flag("network-retry-available") { return .failed }
        guard flag("media-loaded") else {
            return (snapshot["error"] as? String ?? "").isEmpty ? .idle : .failed
        }
        if flag("paused-for-cache") { return .buffering }
        if pendingSeek || scrubbing || flag("seeking") { return .seeking }
        if flag("enhancement-warming") { return .warming }
        if flag("eof-reached") { return .ended }
        if !flag("media-started") { return .starting }
        return flag("pause") ? .paused : .playing
    }

    var isBusy: Bool {
        switch self {
        case .opening, .starting, .reconnecting, .buffering, .seeking, .warming: true
        default: false
        }
    }
    var allowsMediaNotice: Bool { self == .playing || self == .paused }
    var showsError: Bool { self != .opening && self != .reconnecting }
    var interruptionReason: String? {
        switch self {
        case .playing: nil
        case .warming: "model-warmup"
        case .idle, .failed: "not-loaded"
        default: rawValue
        }
    }
    func progressMessage(paused: Bool, retryAttempt: Int) -> String? {
        switch self {
        case .opening: "Opening media…"
        case .starting: "Preparing playback…"
        case .reconnecting: retryAttempt > 0 ? "Reconnecting · attempt \(retryAttempt) of 2…" : "Reconnecting network media…"
        case .buffering: "Buffering media…"
        case .warming: paused ? "Preparing enhancement · staying paused" : "Preparing enhancement…"
        // Seeking retains the timeline's delayed indication; short seeks do not flash.
        default: nil
        }
    }
}
