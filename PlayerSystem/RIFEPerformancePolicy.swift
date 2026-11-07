// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A short stable interval is required after an interruption before evaluating
/// playback pressure or admitting optional background work. Uses monotonic time.
struct PlaybackContinuityGate {
    private var resumeAfter: Double = 0
    private(set) var reason = ""
    mutating func update(now: Double, interruption: String?, grace: Double = 2) -> Bool {
        guard now.isFinite else { reason = "invalid-clock"; return false }
        if let interruption {
            resumeAfter = now + grace; reason = interruption; return false
        }
        guard now >= resumeAfter else { reason = "recovery-grace"; return false }
        reason = ""; return true
    }
}

/// Per-file, monotonic quality fallback. Preferences remain the user's request.
/// Explicit Retry/configuration or a new file resets it; seek/pause do not upgrade.
struct RIFEPerformancePolicy {
    enum Stage: String { case requested, fast, off }
    private(set) var stage: Stage = .requested
    private(set) var reason = ""
    private var started: Double?
    private var lastTime: Double?
    private var generation: String?
    private var lastDrops: Double?
    private var budgetSince: Double?
    private var playbackSince: Double?

    func effectiveTier(_ requested: String) -> String {
        stage == .fast ? "fast" : requested
    }
    mutating func reset() { self = Self() }
    mutating func suspend() {
        started = nil; lastTime = nil; generation = nil; lastDrops = nil
        budgetSince = nil; playbackSince = nil
    }

    /// Returns the destination stage only when a transition occurs.
    mutating func observe(now: Double, requestedTier: String, observedTier: String?,
                          generation nextGeneration: String?, state: String,
                          p95: Double?, budget: Double?, samples: Int,
                          drops: Double?, avsync: Double?, eligible: Bool) -> Stage? {
        guard eligible, stage != .off, now.isFinite,
              observedTier == effectiveTier(requestedTier) else {
            suspend(); return nil
        }
        if let lastTime, now <= lastTime { return nil }
        if generation != nextGeneration || lastTime.map({ now - $0 > 1 }) == true {
            suspend()
        }
        generation = nextGeneration; lastTime = now
        // The native worker has already restored source playback: don't wait for
        // a second warm-up grace period before recovering at a cheaper tier.
        if state == "degraded" || state == "degraded-finished" {
            return advance(requestedTier, reason: "native processing budget exceeded")
        }
        guard state == "active" else { suspend(); return nil }
        if started == nil { started = now }
        let dropDelta = drops.flatMap { current in lastDrops.map { max(0, current - $0) } } ?? 0
        lastDrops = drops
        guard now - (started ?? now) >= 6 else { return nil }

        if let p95, let budget, p95.isFinite, budget.isFinite, budget > 0, samples >= 48 {
            let ratio = p95 / budget
            if ratio > 0.95 {
                if budgetSince == nil { budgetSince = now }
                if now - (budgetSince ?? now) >= 2 {
                    return advance(requestedTier, reason: "sustained inference budget pressure")
                }
            } else if ratio < 0.80 { budgetSince = nil }
        } else { budgetSince = nil }

        let syncPressure = avsync.map { $0.isFinite && abs($0) > 0.080 } ?? false
        if dropDelta >= 3 || syncPressure {
            if playbackSince == nil { playbackSince = now }
            if now - (playbackSince ?? now) >= 2 {
                return advance(requestedTier, reason: "sustained drops or A/V drift")
            }
        } else { playbackSince = nil }
        return nil
    }

    private mutating func advance(_ requested: String, reason: String) -> Stage {
        stage = effectiveTier(requested) == "fast" ? .off : .fast
        self.reason = reason
        suspend()
        return stage
    }
}
