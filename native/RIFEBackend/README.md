# Native RIFE prototype

Build from the repository root with `scripts/build-native.sh`. Xcode and Apple's
Metal Toolchain are required. Upstream RifeMetal source and MIT-attributed RIFE
v4.26 weights are vendored under `vendor/rife-metal`; no network weight download
at runtime. The SwiftPM dependency lock pins Apple's Argument Parser.

```
native/RIFEBackend/.build/release/iive-rife bench 1280 720 fast 20
native/RIFEBackend/.build/release/iive-rife process input.mov output.mov 48 fast
native/RIFEBackend/.build/release/iive-rife process input.mov output60.mov 60 balanced --no-fallback
```

Only new output paths are accepted. Requires explicit SDR BT.709 metadata and
unrotated video. AVFoundation-supported inputs only; not arbitrary MKV containers.
Output is lossy H.264 MOV plus passthrough of the first audio track, retaining its
PTS. Subtitles, chapters, extra audio tracks and Dolby Vision metadata are not
copied. This is a video-stream prototype, not a production transcoder.

The default throughput guard switches permanently to original source cadence
following three over-budget pairs after warmup; it never calls repeated frames
RIFE. `--no-fallback` is for measuring fixed-tier processing. Scene cuts/duplicates
hold the previous frame across the interval, and reset the feature cache. A sparse
pixel difference is only a heuristic; flashes and complex edits need validation.
No interpolation is done past the final frame; the final interval holds it.

`EnhancerCore.FrameProcessor` is synchronous and bounded. Calls must be serialized.
An embedding host must call `reset()` before seek/reconfiguration, stop feeding
while paused, and flush via `finish(end:)` at EOF. Speed changes belong to the host
presentation clock; do not multiply media PTS. Nonmonotonic PTS/gaps >1s are rejected.

## Compilable native integration boundary

`libIIVERIFE.dylib` and `include/IIVERIFE.h` export a real C-callable interpolation
API. It takes borrowed BGRA8 CVPixelBuffers and returns an owned CVPixelBuffer.
This permits a separately built host or video-filter adapter to call the Metal
model without launching a CLI. The dynamic library must be distributed beside
its SwiftPM resource bundles. It does **not** register a filter in stock mpv.

The streaming C ABI additionally exports create/push/pop/finish/reset/destroy.
The actual `native/mpv-filter/vf_iive_rife.c` adapter now registers these calls in
a separately compiled mpv. It preserves media PTS, leaves audio in mpv, and was
verified through libmpv's OpenGL render API. See ../mpv-filter/README.md.
Stock IINA still lacks a loadable-vf ABI or VapourSynth entry; its RIFE option is
unavailable. No IINA.app was replaced or re-signed.

Latency samples retain only the latest 4096 pairs, with total count/sum for the
full-stream mean. JSON names the rolling percentile window explicitly.

The stock plugin deliberately disables RIFE. Opening the resulting MOV in IINA
is ordinary playback of a processed file, not realtime RIFE integration.
