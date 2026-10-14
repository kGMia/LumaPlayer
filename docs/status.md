# Current: native player 0.4

Settings and controls: [Native settings, codec/bitrate information and playback basics](player-basics-20261014.md).

Latest update: [M5 surface sharing, Liquid Glass controls and live video information (2026-10-14)](m5-glass-20261014.md).

2026-10-14: actual FSRCNNX 8/16 trained MPSGraph models and native RIFE NV12 input/output are integrated. Build, tiny GPU checks and combined native-filter smoke passed. See [native models](native-models-20261014.md).

- Implemented: Xcode 27 project, macOS 27 arm64 SwiftUI UI, FSRCNNX 8/16 + RIFE integration, Apple low-latency SR and midpoint FI, track/subtitle controls, persistence, renderer-pass status and bounded fallbacks.
- Development build only: workspace/Homebrew dependent, SDR focus, one window, OpenGL presentation.
- Not complete: pure Metal presentation, end-to-end zero-copy/hardware decoding, measured Neural Accelerator/ANE utilization, full HDR and long-film quality/performance acceptance.
- Focused build/playback evidence and install/run instructions: [player-0.4.md](player-0.4.md).

---

# Delivery status

| Phase | Delivered | Verified | Remaining |
|---|---|---|---|
| Foundation | source review, dependency lock, license notices, architecture | M5 environment; installed/latest libmpv probes | stock IINA has no loadable native-filter ABI |
| Super resolution | installable TypeScript plugin, FSRCNNX 8/16, RAVU, CAS, Sidebar, ownership, color guard | FSRCNNX 8/16 actual IINA render; model switching and paused status confirmed | natural-video quality acceptance; RAVU/CAS render acceptance; HDR bypass only |
| CPU Motion | Removed from plugin in 0.2.0; preferences migrate to Off; legacy cleanup retained | previous measurements and user feedback show severe stalls; migration regression test passes | not a supported playback feature |
| RIFE | vendored model; Swift stream; C ABI; asynchronous mpv filter and visible AppKit/OpenGL host | arm64 build; 24→48/60 MOV and mpv output; visible fast720p48/60 + CoreAudio; pause/seek/2× fallback | stock IINA integration; sustained and comprehensive interactive validation; HDR |
| Optimization | bounded queue, cache-reset policy, overload ladder, selectable quality tiers | targeted policy/PTS tests | 1080/4K full benchmark, thermal and natural-video quality work |

No functionality is claimed merely because a control exists. RIFE is disabled in
the stock plugin. Missing presentation FPS and AI telemetry in stock playback are
N/A. Quality/RAVU/CAS fail closed unless final GPU execution passes are observed.
The user requested no complete test campaign; unrun cases are recorded in
benchmarks.md. The development link used for smoke testing was removed; normal
installation uses the package in dist/.

Update 2026-10-13: existing installed plugin backed up and upgraded. Updated IINA
1.5.0 runs the new plugin; FSRCNNX again verified on actual playback. Motion is
left disabled in its persisted config after overload during the short test.
Native filter build is in build/mpv, intentionally separate from the signed app.

## Preview 0.2.0

Adds visible running-state indicators, stale-telemetry handling, exact SR model
reporting, and an independent FSRCNNX 8/16 selector. Removes minterpolate activation
and selectable UI, rather than retaining a misleading experimental switch.
See super-resolution-evaluation.md and realtime-rife-plan.md for the candidate
models and staged native integration plan. No new heavy SR model has been ported.

Focused 0.2 smoke: 720p24 → 1440p in IINA 1.5.0 confirmed FSRCNNX 16
final GPU pass, Active → Paused, and restoration to FSRCNNX 8. Snapshot drops
were zero; this is not a sustained-performance or natural-video quality result.
Raw captures are benchmarks/results/status-v020-*.json.

Native iteration 0.3 adds separate real-time playback. See [measured results](realtime-rife-results.md). The plugin version remains 0.2.0; no new plugin package is necessary.
