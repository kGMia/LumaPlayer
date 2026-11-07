# Playback feedback and Previous navigation — 2026-10-19

- Network playback no longer promotes every mpv error-level log into a visible “Playback failed” banner. Demuxer probing, connection attempts and decoder fallback may log errors and still succeed. Only `MPV_END_FILE_REASON_ERROR` publishes a media failure; command failures remain visible immediately. Known HTTP/TLS/timeout messages are converted to fixed, safe descriptions. The candidate diagnostic clears on successful load/restart and at the next file. Signed URLs/headers are not displayed. Opening a file now shows an opening indicator.
- The transport panel shows the current media title for 1.8 seconds after its initial playback-start event and enhancement warm-up. At the existing 4 Hz UI cadence, removal normally occurs within 2 seconds, plus the short fade. Ordinary and mini-player panels support it. The controls are revealed and protected from automatic hiding during the notice.
- A separate mpv media epoch identifies each open, including consecutive entries referencing the same URL. Seeking, metadata updates and pause/resume do not restart the timer. Slow network opens do not use up the display interval before playback is ready. Metadata corrections can update the text within that interval.
- Previous immediately selects the previous queue item when position is **less than 10 seconds OR less than one quarter of duration**. This deliberately means the first quarter of a long movie also qualifies. After both thresholds it restarts the current item; the next press can select the previous item. With no previous item it restarts the current one if seeking is possible. Unknown duration uses the 10-second threshold; non-seekable streams select the previous item when available.

Implementation: `MPVSession.m` owns playback lifecycle/error candidates; `PlayerTimeline.swift` contains deterministic title timing and navigation policies; `PlayerModel`, `PlaybackChrome`, `PlayerView`, and `PlayerWindowModes` connect the state to SwiftUI.

Basic checks only: Xcode Debug build, development signature checks, and `tests/TransportFeedbackSmoke.swift` for navigation boundaries, unknown duration, title readiness/expiry, metadata changes, seeks, repeated URLs and rapid replacement. No GUI, full regression suite or new performance benchmark. The actual cloud server's startup behavior remains for user verification.

Logs: `benchmarks/results/transport-feedback-build-20261019.log` and `transport-feedback-smoke-20261019.log`.

Re-run the state check:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -swift-version 5 -parse-as-library -module-cache-path build/checks/swift-modules \
  PlayerSystem/PlayerTimeline.swift tests/TransportFeedbackSmoke.swift \
  -o build/checks/transport-feedback-smoke
build/checks/transport-feedback-smoke
```
