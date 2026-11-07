// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main struct PolicySmoke {
    static func tick(_ policy: inout RIFEPerformancePolicy, _ t: Double,
                     requested: String = "balanced", observed: String = "balanced",
                     state: String = "active", p95: Double = 49, drops: Double = 0,
                     eligible: Bool = true) -> RIFEPerformancePolicy.Stage? {
        policy.observe(now: t, requestedTier: requested, observedTier: observed,
                       generation: "1", state: state, p95: p95, budget: 41.667,
                       samples: 120, drops: drops, avsync: 0, eligible: eligible)
    }
    static func main() {
        var gate = PlaybackContinuityGate()
        assert(gate.update(now: 0, interruption: nil))
        assert(!gate.update(now: 1, interruption: "buffering"))
        assert(gate.reason == "buffering")
        assert(!gate.update(now: 2, interruption: nil))
        assert(gate.reason == "recovery-grace")
        assert(!gate.update(now: 2.5, interruption: "reconnecting"))
        assert(!gate.update(now: 4, interruption: nil))
        assert(gate.update(now: 4.5, interruption: nil))
        assert(gate.reason.isEmpty)
        var p = RIFEPerformancePolicy()
        for i in 0..<32 { assert(tick(&p, Double(i) / 4) == nil) }
        assert(tick(&p, 8) == .fast)
        assert(p.effectiveTier("balanced") == "fast")
        // Metadata from the retired balanced filter must not turn fast off.
        assert(tick(&p, 8.25, state: "degraded") == nil)
        for i in 34..<90 { assert(tick(&p, Double(i) / 4, observed: "fast", p95: 27) == nil) }
        p.suspend()
        assert(p.stage == .fast)
        assert(tick(&p, 30, observed: "fast", state: "degraded") == .off)
        assert(tick(&p, 31, observed: "fast", state: "degraded") == nil)
        p.reset(); assert(p.stage == .requested)

        for i in 0..<80 {
            assert(tick(&p, Double(i) / 4, requested: "fast", observed: "fast", p95: 27,
                        drops: i >= 40 ? 10 : 0) == nil)
        }
        assert(p.stage == .requested) // isolated dropped-frame burst is tolerated
        assert(tick(&p, 21, requested: "fast", observed: "fast", state: "degraded", eligible: false) == nil)
        assert(tick(&p, 22, requested: "fast", observed: "fast", state: "degraded") == .off)

        p.reset()
        for i in 0...28 { _ = tick(&p, Double(i) / 4) }
        _ = tick(&p, 7.25, p95: 25) // lower hysteresis threshold clears pressure
        for i in 30..<38 { assert(tick(&p, Double(i) / 4) == nil) }
        assert(tick(&p, 9.5) == .fast)
        p.reset()
        assert(tick(&p, 0, requested: "hq", observed: "hq", state: "degraded") == .fast)
        print("PASS: staged fallback, warm-up, hysteresis, stale tier rejection, isolated drops, suspend/reset and manual protection off")
    }
}
