# Delivery and network playback follow-up — 2026-10-21

## 1. One delivery entry point

Run `scripts/build-player-modern.sh Debug` (or `Release`). It builds the modern Xcode target, stages the bundle, checks arm64 Mach-O dependency resolution, essential resources, version metadata and its existing code signature, then replaces `build/IIVE-Player.app`. A failed validation leaves the previous delivery intact. `scripts/build-player.sh` now delegates to this path; it can no longer overwrite the modern app with the earlier Objective-C host.

`build/PersonalTeam/IIVE Player.app` is a compatibility symlink to the canonical delivery, not a separately copied version. Xcode's product remains in DerivedData for development. `build/player-delivery.json` records configuration, version, build number, time and external-library inventory. `scripts/run-player.sh` launches the modern bundle through LaunchServices.

This remains a **local development delivery**. It still requires native engine libraries and Homebrew dependencies outside the app. The dependency inventory makes these explicit; it does not claim portability, notarization or a public distribution signature. A later portable package must bundle/relocate those libraries and model assets, preserve third-party notices and re-sign modified binaries.

## 2. Bounded managed-stream recovery

For a seekable WebDAV/OneDrive queue item that has reached playback, MPVSession records the logical queue key, playback position, desired pause state, speed and selected audio/subtitle tracks in memory. No media URL, authentication header or checkpoint is persisted.

On a retryable load/runtime error, the `on_after_end_file` hook holds automatic advancement, waits 1 second (first retry) or 3 seconds (second retry), and restarts the same playlist entry. Its normal `on_load` resolver obtains a fresh URL. File-local options restore the checkpoint before decoding resumes. Queue contents are retained. User navigation or session shutdown cancels outstanding recovery; pause/track/speed commands during the wait update the pending restore options.

FFmpeg may report a failed read as EOF. With keep-open active, recovery also handles EOF when a read-error log was observed and the known duration is still clearly ahead of the last valid position (more than max(2 seconds, 0.5% duration)). It stops with `keep-playlist` before the same end-hook recovery. Ordinary EOF and seek/stop actions do not themselves trigger recovery.

At most two retries are allowed for the current item; there is no infinite retry loop. Recognized HTTP 401 and certificate failures are not retried. Resolver failures remain explicit errors. The transport panel distinguishes buffering from reconnecting. Logical media identity remains stable during the unloaded recovery interval so automatic enhancement quality does not silently upgrade again.

Limitations: this automatic refresh is for managed WebDAV/OneDrive queue entries, not arbitrary pasted URLs, live/nonseekable streams, or a source that never successfully started. A read stall with no reported error/EOF remains subject to the existing network timeout. External subtitle-file reconstruction and changed track numbering after a server replaces the media are not handled. Real WAN recovery, track restoration and presentation remain user checks.

## 3. Playback-first background work

Queue metadata remains row-driven, coalesced and limited to one remote probe at a time. Opening, buffering, reconnecting or a known remote forward cache below two seconds cancels/defers optional row metadata work. It resumes only after a two-second stable interval. Existing metadata stays displayed. Row task cancellation releases subscribers; unused probes are cancelled through the existing deadline/cancellation wrapper. Existing folder-browser request cancellation and stale-result tickets are retained.

## 4. Enhancement protection continuity

RIFE's staged policy, the global dropped-frame/A-V guard and GLSL verification now share an interruption gate. Buffering, reconnecting, pause, seek/scrub, model warm-up, unloaded media and window transitions suspend evaluation, followed by a two-second recovery grace. This closes the previous hole where the global guard could downgrade effects during network buffering even though the RIFE policy was suspended.

The existing inference-budget thresholds and native worker safety checks are unchanged. Manual mode still avoids automatic tier selection. `rife-performance-policy.evaluation_hold`, `network-reconnecting` and `network-retry-attempt` are available in diagnostics without exposing URLs.

## Basic verification

- `bash scripts/check-network-recovery.sh`: real libmpv (null video/audio outputs) confirms end-hook retry before auto-next, retained queue identity, start/pause/speed restoration, and stop-with-keep-playlist/reload. The fixture is a generated two-second local WAV; this is an API-contract test, not a WAN test.
- Swift policy smoke checks include interruption/grace behavior plus existing warm-up, staged fallback, hysteresis and manual protection behavior.
- Python/shell syntax and targeted whitespace checks passed.
- Final build/package result: `benchmarks/results/delivery-network-build-20261021.log`.
- No Computer Use, GUI playback, account access or full regression testing was performed.
