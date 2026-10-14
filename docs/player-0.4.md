# IIVE Player 0.4 — macOS 27 / Xcode 27

Settings and controls: [Native settings, codec/bitrate information and playback basics](player-basics-20261014.md).

Latest update: [M5 surface sharing, Liquid Glass controls and live video information (2026-10-14)](m5-glass-20261014.md).

This is the next iteration of the **separate player**, not an update or modification to IINA.app. The IINA plugin remains 0.2.0. The native UI is SwiftUI + AppKit; decoding, subtitles, audio and timing use the project's pinned libmpv build.

## Open in Xcode

Open `IIVEPlayer.xcodeproj`, select the shared **IIVE Player** scheme and **My Mac**, then Run. Debug and Release both target **macOS 27.0, arm64**. The local target now uses Apple Development automatic signing with the user-selected Personal Team; a paid team is not required for this local development build. The native source files are directly editable in Xcode. A build phase compiles the Swift/Metal RIFE package, native FSRCNNX MPSGraph package, Apple VideoToolbox adapter and patched mpv; another bundles the licensed GLSL shaders and app icon. FSRCNNX uses newly exported trained weights as SwiftPM resources; old experimental binary weights remain excluded. Native engines currently use release optimization even in a Debug app build.

Command-line equivalent:

```sh
scripts/build-player-modern.sh           # Debug
scripts/build-player-modern.sh Release   # optimized app
open 'build/Xcode/Build/Products/Debug/IIVE Player.app'
```

Use a full Xcode 27 installation with the Metal Toolchain component installed. Scripts set `DEVELOPER_DIR` locally; they do not change `xcode-select`. Prerequisites remain `meson ninja pkgconf ffmpeg libass libplacebo` from Homebrew. First builds need the upstream dependencies already pinned by the existing build scripts. The checked-in project has no XcodeGen dependency. `scripts/create-xcode-project.py` is a reproducible generator, **not** invoked during builds; rerunning it overwrites project customizations.

The app remains a **development build bound to this workspace and Homebrew dylibs**. It is not a portable/notarized distribution. Keep the repository in place; rebuild after moving it. The old Objective-C 0.3 host and its script remain available for regression comparisons.

## Daily controls

- Open (`⌘O`), file drop, recent files; remember up to 12 paths and playback positions locally.
- Play/pause (`Space`), ±5 seconds (`←` / `→`), timeline scrubbing, 0.5–2× speed, volume, full screen.
- Select embedded audio/subtitle tracks or load an external subtitle file (`⇧⌘S`). libass is part of the mpv build.
- Inspector: independently select super resolution and interpolation, target FPS and RIFE tier; master enhancement switch and performance fallback.
- Configuration and volume persist. Retry resets the latched fallback. Seeking/file changes reset temporal state; results from older generations are discarded.

A single playback window is provided in 0.4. Multiple simultaneous windows, playlists, picture-in-picture, complete keybinding customization and network streaming UI remain future work.

## Actual processing routes

| Selection | Pipeline | Limits |
|---|---|---|
| FSRCNNX Metal Fast / Quality | Swift/MPSGraph FP16, seven merged trained stages, Metal NV12 output | Fixed 2×, BT.709/BT.1886 SDR, even dimensions, viewport >1.3×; actual native filter metadata confirms activity. |
| FSRCNNX GLSL Shader | bundled 8/16 GLSL weights, mpv GPU luma hooks | Working route. Only when fitted viewport >1.3× in both dimensions. Final aggregation pass must be observed. |
| Apple Low-Latency SR | public `VTLowLatencySuperResolutionScalerConfiguration` / `VTFrameProcessor` | Runtime dimensions and scale query; SDR BT.709/BT.1886, NV12. |
| RIFE Metal | v4.26, FP16 Metal + MPSGraph, GPU NV12 input and fused NV12 output | 48/60 targets; fast recommended on base M5. Balanced/HQ remain heavy experiments. |
| Apple 2× FI | public `VTLowLatencyFrameInterpolationConfiguration` | Actual midpoint PTS: 24→48, 23.976→47.952, 30→60. Not a 24→60 converter. |

All FI occurs **before SR**. RIFE now returns NV12 to mpv so that the FSRCNNX LUMA hooks actually run; the former BGRA output could skip them. RIFE's added color conversion is included in its processing budget. Shader ownership and native filter labels are managed without clearing unrelated filters/shaders.

Apple's backend uses a persistent `VTFrameProcessor`, reusable IOSurface NV12 pools, direct swscale conversion into a pooled input, and reference-counted output buffers that survive until mpv releases them. There is no extra NV12 output memcpy. This is **not full end-to-end zero-copy**: software decode/conversion and the current OpenGL upload remain. Output crop coordinates are scaled together with the SR buffer; original aspect ratio and color metadata are retained. Unsupported formats, rotated media, HDR and errors bypass enhancement with visible state.

Each filter has one worker, one in-flight job and a bounded output batch. Five consecutive jobs exceeding 1.25× the source interval after startup latch native fallback in the mpv adapters. The host also monitors sustained dropped frames / A/V drift after a settling period; it disables enhancement until Retry or another file. Model switches temporarily pause and re-seek at the current PTS, warming on the worker before resuming. UI updates and libmpv client calls are on separate queues; the render queue never calls ordinary mpv APIs. This permits public advanced render control and actual `vo-passes` inspection without blocking SwiftUI.

Cold start still takes time. A 20-second warm-up timeout releases the temporary pause; it does not cancel an already-running system model call. Processing failure and subsequent native fallback remain visible. It is not a promise of uninterrupted model switching.

### Measured Apple SR capabilities on this base M5

See `benchmarks/results/apple-vt-capabilities-27.json`:

| Source | Supported scales |
|---|---|
| 640×360 | 1.5×, 2× |
| 960×540 | 1.5×, 2× |
| 1280×720 | 1.5× (1920×1080) |
| 1920×1080 | none |

Do not equate a non-nil configuration object with successful support. 720p→1080p is a useful Apple route; 1080p→4K currently requires FSRCNNX. Apple's low-latency SR is designed partly for compressed conferencing video; it has not been proven superior for film grain, facial detail or cinematic footage in this project.

## Neural Accelerator work and evidence

**M5 GPU Neural Accelerators and the separate Apple Neural Engine (ANE) are different.** There is no honest global “use Neural Accelerator” switch for these models.

- **RIFE Metal**: FP16 tensors, compiled graph stages, cached frame features, bounded buffers and fused warp/blend kernels. The new BT.709 NV12 stream route writes NHWC FP16 input directly on Metal, including padding and internal scaling. On the BT.709 NV12 route, a fused GPU kernel packs the blended frames directly into cropped NV12 output, removing synthesized BGRA buffers and their CPU conversion. Software decode and the SR input layout copy still remain. `vf-metadata/iive-rife/input_path` and `output_path` report the actual conversion routes; active UI shows the actual route. No speedup percentage or accelerator utilization was measured in this iteration.
- **Apple SR / FI**: VideoToolbox sessions and NV12 pools. No public selection of ANE versus GPU Neural Accelerator. The adapter now accepts BT.709/BT.1886 SDR and explicitly normalizes to limited-range BT.709 with centered chroma and matching CoreVideo attachments. Other primaries/transfers bypass this adapter; broader color support needs validation.
- **FSRCNNX Metal**: now implements the actual 8/16-channel trained shader models. Strict export preserves biases, PReLU, residuals, matrix ordering and pixel shuffle. Seven merged FP16 convolution stages execute in MPSGraph, with reusable buffers and NV12 pools. The native mpv filter is connected to the UI. GLSL 8/16 remain selectable. GPU tensor-unit utilization is not measured.

The historical October 13 optimization report overstated integration and performance. See [the historical correction](agent-handoff-20261014.md) and [the subsequently completed native implementation](native-models-20261014.md). MPSGraph use is not a measurement of GPU tensor-unit occupancy or ANE execution.

## Native rendering and color limits

The interface is modern SwiftUI with native toolbar, inspector and system controls. Video presentation still uses libmpv's public **OpenGL render API** inside an AppKit NSOpenGLView. Metal/MPSGraph/VideoToolbox run the enhancement; the final renderer has **not** been rewritten in Metal. OpenGL is deprecated on macOS but remains available on this machine. A native Metal presentation replacement needs a compatible libplacebo/Metal or Vulkan-MoltenVK integration and equivalent subtitle, color, timing and shader coverage.

This host is currently **SDR-focused**. Bypassing enhancements on HDR prevents AI from processing it as SDR; it does not certify HDR presentation in this OpenGL host. Use IINA for HDR-critical viewing pending end-to-end tone mapping/EDR verification.

## Focused verification

```sh
python3 benchmarks/modern_player.py --fi rife --sr fsrcnnx8
python3 benchmarks/modern_player.py --fi apple --sr apple
```

These require an active GUI session. In this automated environment, process-only launches sometimes deferred SwiftUI window creation until the app was activated using the UI tool; those timeouts are retained in results. Bring the test app to the foreground if no window appears. This is not a headless test.

These use the existing 12-second 720p24 synthetic fixture, real application window, CoreAudio clock (muted), real GPU effects and timestamped IPC/telemetry. They verify active filter states, shader passes, full SR crop and normal exit. They do not certify subjective movie quality, acoustic lip sync or sustained performance. Physical display FPS and accelerator utilization remain unavailable. Historical failed attempts are retained rather than replaced with fabricated passes.

## References and open-source provenance

- Apple SDK headers read locally: `VTFrameProcessor*.h`, `MPSGraph.h`, mpv `render.h`, `vo_libmpv.c`, `gpu/libmpv_gpu.c`, `mp_image.c`.
- [Apple: ML video effects](https://developer.apple.com/videos/play/wwdc2025/300/) — intended workloads and real-time APIs.
- [Apple: M5 GPU Neural Accelerators](https://developer.apple.com/videos/play/tech-talks/111432/) — tensor APIs, framework paths and profiling.
- [Apple: Low-Latency SR configuration](https://developer.apple.com/documentation/videotoolbox/vtlowlatencysuperresolutionscalerconfiguration) — runtime dimensions/scales.
- [IINA](https://github.com/iina/iina), GPL-3.0: reviewed `MainWindowController.swift`, sidebar organization and playback control patterns; independent SwiftUI implementation here, no copied nib assets. Existing pinned mpv, RifeMetal and shader notices remain in `THIRD-PARTY.md`.

Apple frameworks/system model implementations are provided by macOS; their weights are not redistributed or represented as open-source project weights. Our integration code is GPL-3.0-or-later.
