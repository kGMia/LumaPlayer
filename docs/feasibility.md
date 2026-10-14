> **0.4 update (2026-10-13):** A separate macOS 27 SwiftUI/Xcode player now integrates
> RIFE + FSRCNNX and public Apple low-latency SR/FI. This does not change stock IINA's
> frame-injection limits. See [player-0.4.md](player-0.4.md) for measured Apple scale
> support, current rendering limits and accelerator evidence.

# Feasibility record — 2026-10-12

Scope: delivered preview and short smoke tests; unfinished integration is explicitly listed below.

Environment: MacBook Air Mac17,3, base Apple M5, 10 GPU cores, 24 GB RAM,
macOS 27.2 (26B5101f). Initially installed IINA 1.4.4 (168); user updated to 1.5.0 on 2026-10-13. Official stable release
API reports 1.5.0. Xcode 27.0 (27A266a) exists but xcode-select uses CLT;
build scripts select Xcode per process, never change the system selection.
Swift CLT 6.4, Node 26.0.0, FFmpeg 8.1.1. No standalone mpv command.

## Sources inspected

- https://docs.iina.io/interfaces/IINA.API.MPV — getNative/set/command.
- https://docs.iina.io/interfaces/IINA.API.SidebarView — loadFile/messages.
- https://docs.iina.io/pages/webviews.html — separate WebKit context.
- IINA `JavascriptAPIMpv.swift`, `JavascriptAPI.swift`, `JavascriptAPIEvent.swift`,
  `JavascriptPluginInstance.swift`, `JavascriptAPISidebarView.swift`,
  `JavascriptAPIPreferences.swift`, `MPVController.swift`, `iina-plugin/main.swift`.
- mpv `libmpv/render.h`, `video/filter/vf_vapoursynth.c`, `filters/user_filters.c`,
  `DOCS/man/input.rst`, `DOCS/man/options.rst`, `meson.build`.
- Video Upscaler `src/main.ts`, `Info.json`, package and MIT license.
  Its clearing of the complete shader list and overwriting GPU profiles are not reused.
- RifeMetal `Package.swift`, CompileMetalShaders plugin, RifeConfiguration,
  RifeInterpolator, RifeStream, PixelBufferConvert, IFNetGraph, weight loading.
- FSRCNN-TensorFlow source and release 1.1 shader, RAVU fragment shader,
  Practical-RIFE license and model provenance.

## Architecture choice

Stock IINA main-entry plugin -> mpv shader list and labeled lavfi filter.
IINA's render API is OpenGL (`vo=libmpv`); GLSL fragment shaders are the compatible
path, not Metal shader source or OpenGL compute shaders. Execution must be
confirmed from `vo-passes` after rendering, not merely successful option assignment.

There is no JS CVPixelBuffer API. libmpv render API delivers rendered output to a
client; it is not a decoded-video-frame input API. mpv user filters are registered
at build time. A separately compiled dylib cannot be injected as a new vf filter
through an IINA JavaScript command. VapourSynth requires libmpv build support and
an installed runtime. We probe the shipped build rather than assuming availability.

RIFE is disabled in the stock plugin until a real transport is validated. Native
prototype uses AVAssetReader -> BGRA IOSurface -> RifeStream -> PTS scheduler ->
AVAssetWriter. No PNG transport. A compiled native C ABI is supplied for a separately built
player/filter adapter; does not patch, replace or re-sign IINA.app.

RifeMetal supports BGRA8/RGBA8, not NV12/P010/HDR. It accepts arbitrary t in (0,1),
and exposes fast (1/4), balanced (1/2), hq (1) internal motion inference scales.
Bundled model is RIFE v4.26 `.rmw`. Shared textures avoid a full-frame CPU roundtrip
inside supported inference paths, but upstream padding/cropping contains CPU
copies. Do not claim end-to-end zero copy. Sequential push/reset is mandatory.

IINA has no JavaScript plugin-unload callback in inspected source. To restore
owned effects when the plugin is disabled in preferences, a small mpv Lua lease
watchdog cleans only this plugin's shader paths and vf label after heartbeat loss.

## Verified outcome and remaining blocks

- Installed 1.4.4: mpv 0.38.0 / FFmpeg 7.0.1. Latest 1.5.0: mpv 0.41.0 /
  FFmpeg 9.0.1. The release API gives v1.5.0 (published 2026-10-03 UTC).
  Both were inspected with a compiled probe linked against each app's own dylibs.
  Both `option-info/vf` choice lists omit VapourSynth; adding it returns -12.
  Probe evidence: benchmarks/results/mpv-installed.txt and mpv-latest.txt.
- 1.5.0 was mounted read-only and launched separately. Its original signed app
  was not patched. Public CLI/JSON IPC were used for actual playback telemetry.
- FSRCNNX 8 executed all 14 passes in actual IINA video playback at a 2560×1440
  viewport. `current-vo=libmpv`; input hardware format initially videotoolbox/nv12.
- Minterpolate initially failed the plugin's FPS check on direct hardware decode.
  Software-decoded input yielded 48fps filter output, with drops. The experimental
  option now owns a temporary hwdec=no change and conditionally restores it.
- RifeMetal builds on Xcode 27 after downloading Apple's official Metal Toolchain.
  CLI, stream core and C ABI dylib compile. Real one-second 24→48/60 MOV output
  passes frame count/duration checks. Actual IINA RIFE frame injection is not done.
- There is no tested stock-app path A or B. Path C requires a separately maintained
  custom libmpv / player build, with the supplied native adapter and additional interactive validation.
  The adapter now compiles and feeds real intermediate frames into libmpv OpenGL;
  this separate host is not a finished stock-IINA integration. The requested live RIFE+SR mode therefore remains unavailable.
- Metadata preservation is deliberately limited: shaders bypass mpv-reported HDR
  / wide gamut; native prototype rejects sources without explicit BT.709 metadata.
  Shader color/quality validation and native 10-bit HDR are still incomplete.

The official IINA APIs expose no trustworthy presentation counter in this plugin
context. `estimated-vf-fps` is a filter estimate only. Sidebar presentation FPS,
AI latency in stock playback, and GPU utilization consequently display N/A.

## License decision

Project source is GPL-3.0-or-later. IINA GPLv3, mpv default GPLv2+, FSRCNN training
GPLv3, shader-specific LGPLv3+, RAVU LGPLv3+, CAS MIT, RifeMetal Apache-2.0 and RIFE
MIT-attributed weights were examined. The bundled shader headers control their
terms; do not confuse them with the training repository license. Apache-2.0 can
be combined under GPLv3; all original notices are retained. See THIRD-PARTY.md
and the vendored full licenses. No IINA/libmpv/FFmpeg binaries are redistributed.

## 2026-10-13 update — installed IINA 1.5.0

The user updated IINA to 1.5.0 (mpv 0.41.0). The installed plugin was backed up
and upgraded; the temporary development link was removed. Real playback again
verified FSRCNNX. A newly found hwdec scalar→list API change is fixed and covered
by a focused regression test. The actual motion path produced 48fps, then its
performance guard removed the filter and restored `["auto"]` after overload.

A separately built mpv now includes `vf_iive_rife.c`, using the real Swift stream
bridge. 24 source frames yielded 48/60 output frames (23/46 synthesized) with
strictly increasing, correctly spaced PTS. A CGL/libmpv render-API host performed
45 nonblack readbacks from the 48-frame stream; 3 frames were dropped in that
short cold-start test. Thus native frame transport is implemented and compiled;
stock IINA integration and stable realtime operation are still not established.
The build is intentionally isolated under build/mpv; no IINA binary was modified.

## Preview 0.2.0 decision

CPU minterpolate is retired from the stock plugin following severe-stall feedback
and earlier local evidence. Historical 0.1 measurements above remain unchanged.
The production activation path is removed; only backward cleanup and explicitly
invoked diagnostic scripts retain knowledge of that filter. RIFE remains a
separate native integration project. See realtime-rife-plan.md for its gates.
