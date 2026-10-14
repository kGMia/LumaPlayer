# Third-party code and model provenance

Original project code: GPL-3.0-or-later (LICENSE). All distributed dependency
licenses retain their original terms. Revisions/hashes: docs/dependencies.lock.json.

| Component | Source/version | License | Distribution |
|---|---|---|---|
| FSRCNNX x2 8-0-4-1 | igv/FSRCNN-TensorFlow release 1.1 | **Shader header LGPL-3.0-or-later**, training repo GPL-3.0 | shader source bundled |
| RAVU Lite r3 | bjin/mpv-prescalers, pinned commit | LGPL-3.0-or-later | shader source bundled |
| CAS | agyild gist bbb4e58298b2f86aa24da3032a0d2ee6, CAS.glsl revision 1f96a8c50fde6924067a875e03868dea6a0a11dd | AMD MIT | header retained; runtime modifies DESC, WHEN, strength and transfer macros |
| RifeMetal | cinemore/rife-metal 1fef4869a44fca32848102b9f6a774a20eb50db6 | Apache-2.0 | locally modified source, tests, bundled weights in vendor/rife-metal |
| RIFE v4.26 weights | hzwer/Practical-RIFE via RifeMetal .rmw conversion | MIT per upstream THIRD-PARTY.md | bundled native resource; not plugin |
| IINA | iina/iina 1.4.4 / 1.5.0 | GPL-3.0 | reference and testing; application not redistributed |
| mpv | mpv-player/mpv | GPL-2.0-or-later default; optional LGPL build | pinned source downloaded for isolated local native-filter build; custom mpv binary not in release package |
| FFmpeg | system 8.1.1 / IINA build | system build enables GPL and version3 | external tools only |
| Video Upscaler | Fhlisherman/iina-video-upscaler | MIT | read for reference; no source copied |
| TypeScript / esbuild / IINA definitions | npm lock | Apache-2.0 / MIT / MIT | development only |
| swift-argument-parser | official Apple package, SwiftPM lock | Apache-2.0 | RifeMetal CLI dependency |

Apache-2.0 and MIT code may be combined into GPLv3 works while retaining notices.
LGPL shader source is supplied in editable form with both LGPL and GPL texts;
users can replace/rebuild it. FSRCNN training code is not bundled. Native backend
is a separate build; no third-party application code signatures are modified.
Model-license attribution follows the pinned RifeMetal notice; the checkpoint
has not been independently retrained or assigned a new license. A commercial
redistributor should review upstream model provenance and all transitive licenses.

Native adapter build-only dependencies (Homebrew core, 2026-10-13): meson 1.12.1
(Apache-2.0), ninja 1.13.2 (Apache-2.0), pkgconf 3.0.8 (ISC), libplacebo 7.360.1
(LGPL-2.1-or-later), libass 0.17.5 (ISC), FFmpeg 8.1.1 (local GPLv3-enabled build).
They are external, not vendored or redistributed. Homebrew installed/upgraded
transitive build dependencies; the adapter recipe uses the local prefix.

Evaluation only (not bundled or executed): Real-ESRGAN code BSD-3-Clause and
SwinIR code Apache-2.0, pinned in docs/dependencies.lock.json. Sources, specific
model distinctions and weight-provenance follow-up are recorded in
super-resolution-evaluation.md. No weights from these candidates are shipped.

## Player 0.4 integration

- SwiftUI/AppKit/VideoToolbox: public macOS 27 SDK frameworks, system supplied; no Apple system-model weights redistributed.
- RifeMetal local change: explicit MPSGraph level-1 compilation descriptor and optional `IIVE_RIFE_DISABLE_AUTO_LAYOUT=1` diagnostic (macOS 27 only). Automatic layout optimization remains the default. Existing Apache-2.0 notices retained.
- FSRCNNX bundle copies add an `IIVE FSRCNNX` prefix to pass descriptions for runtime verification; math/weights/license notices unchanged.
- IINA window/sidebar source was used as a functional reference; the SwiftUI player UI is an independent GPL-3.0-or-later implementation.

Local RifeMetal changes (2026-10-14): streaming NV12 texture binding, BT.709-to-NHWC FP16 conversion, GPU input padding/downsampling, and opt-in GPU checks. Existing upstream licensing and model notices remain applicable; no new model or weights added. See docs/agent-handoff-20261014.md.

## Native model update (2026-10-14)

FSRCNNX 8/16 JSON resources derive from the existing igv LGPL-3.0-or-later shaders (Copyright 2017–2021 igv). Each resource includes the source filename and SHA-256, license and copyright. `scripts/export-fsrcnnx.py` preserves trained parameters and reconstructs the original operators; Swift/Metal integration code is GPL-3.0-or-later. Original shaders and LGPL/GPL texts remain in plugin/shaders and plugin/licenses. No new model was trained or fetched.

The FSRCNNX SwiftPM Metal build plugin is copied from cinemore/rife-metal under Apache-2.0; original license remains at vendor/rife-metal/LICENSE. Additional local RifeMetal changes fuse mask interpolation/blending/cropping into native NV12 output. No accelerator utilization or throughput is implied by these code changes.

## LittleCMS 2.19

Native mpv ICC color management now links LittleCMS 2 from Homebrew (`lcms2` / `little-cms2`). Source: https://github.com/mm2/Little-CMS . License: MIT; the complete notice is included in `LittleCMS-LICENSE` and copied into the development app resources.
