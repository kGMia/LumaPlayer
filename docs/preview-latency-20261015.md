# Timeline preview and native pipeline optimization — 2026-10-15

## Timeline previews

The old hover path canceled image generation on each time bucket change. Rapid pointer movement could repeatedly interrupt decoding before any usable frame completed. It also cleared the entire cache when full and cleared the displayed thumbnail while waiting.

The new implementation:

- Keeps one logical image request in flight; canceled UI subscribers let its result populate the cache. Only interested subscribers proceed to their latest target.
- Uses a 96-entry LRU cache and immediately displays a cached frame within three seconds of the requested time.
- Coalesces pointer changes for 35 ms after checking the cache. Request spacing adapts to timeline width and media duration.
- Keeps a nearby displayed image during replacement, rather than flashing an empty placeholder.
- Allows ±1.5 seconds of decoder tolerance and labels the image with its actual timestamp (`Preview ≈`). The cursor timestamp and seek target remain independent and exact.
- Bounds each request's caller wait to three seconds. File changes cancel work and invalidate results from the old generation.

First-use latency still depends on the source format, keyframe spacing, storage, and AVFoundation. Formats playable by mpv are not necessarily supported by AVFoundation thumbnail generation. No mpv fallback decoder or full-video thumbnail precomputation was added. No measured latency improvement is claimed yet.

## Playlist artwork

Artwork and duration reads now share two logical work slots, with subscriber-aware cancellation, a six-second deadline, and a 128-entry LRU cache. Timeline requests use a separate lane. A row disappearing cancels its read when no other subscriber needs it. Entirely empty or timed-out reads are not cached as successful results.

Deadlines bound the caller's wait and request OS cancellation. They cannot guarantee that an OS media operation immediately releases all resources; late results are ignored safely.

## FSRCNNX fused chroma processing

For VideoToolbox-backed IOSurface NV12 frames with limited range, BT.709 matrix/primaries, BT.1886 transfer, left chroma placement, and progressive scan, FSRCNNX now accepts the original surface directly. Its existing output chroma kernel applies the left-to-center chroma offset while scaling.

This removes the separate chroma-normalization intermediate and its GPU submission/wait for this eligible path. Diagnostics identify it as `fused-metal-chroma`. Source attachments are not rewritten; output attachments identify centered chroma. Source and destination texture usage is restricted to read and write respectively.

Full-range, P010, HDR, unsupported color descriptions, RIFE, and Apple interpolation retain their existing conversion and compatibility paths. This is not an ANE implementation. Combining the two chroma sampling stages is not bit-identical to sequential filtering; visual quality and end-to-end performance still require user playback checks.

## Basic validation

- Xcode Debug build succeeded, 2026-10-15; final incremental build reported 8.341 seconds and no errors.
- `bash scripts/test-media-deadlines.sh` passed: successful completion, deadline and late result, parent cancellation, canceled queue-slot waiter.
- The small concurrency check compiles the actual helper source. It does not decode video or exercise a GPU.
- No GUI, Computer Use, playback, full test suite, or performance benchmark was run.
- Build logs: `benchmarks/results/preview-latency-build-20261015.log` and `preview-latency-backends-20261015.log`.
- Delivery app: `build/PersonalTeam/IIVE Player.app`.

## Suggested user checks and next work

Check slow and fast timeline movement on long-GOP files, repeated hover over cached regions, and switching files during a pending preview. Compare the preview timestamp with the cursor timestamp. Check playlist responsiveness with many items and cancel by closing the list.

For GPU work, compare FSRCNNX output and input/model/output timing on eligible left-chroma material before pursuing asynchronous multi-frame scheduling. Future thumbnail work can add a bounded mpv/FFmpeg fallback for AVFoundation-incompatible formats and opportunistic nearby-frame prefetch only after measuring decoder contention with playback.
