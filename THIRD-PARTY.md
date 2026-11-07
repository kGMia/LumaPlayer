# Third-party code and model provenance

Original project code: GPL-3.0-or-later (LICENSE). All distributed dependency
licenses retain their original terms. Revisions/hashes: docs/dependencies.lock.json.

FSRCNNX Core ML research export (2026-10-25) reuses the existing LGPL-3.0-or-later
shader-derived 8/16 weights; it adds no newly trained weights. Conversion pins
the native JSON checksums and writes model manifests. PyTorch 2.7.0 (BSD-style)
and coremltools 9.0 (BSD-3-Clause) are local conversion tools, not bundled player
dependencies. Native adapter code remains GPL-3.0-or-later; see
`docs/fsrcnnx-coreml-20261025.md` for scope and results.

| Component | Source/version | License | Distribution |
|---|---|---|---|
| FSRCNNX x2 8-0-4-1 | igv/FSRCNN-TensorFlow release 1.1 | **Shader header LGPL-3.0-or-later**, training repo GPL-3.0 | shader source bundled |
| RAVU Lite r3 | bjin/mpv-prescalers, pinned commit | LGPL-3.0-or-later | shader source bundled |
| CAS | agyild gist bbb4e58298b2f86aa24da3032a0d2ee6, CAS.glsl revision 1f96a8c50fde6924067a875e03868dea6a0a11dd | AMD MIT | header retained; runtime modifies DESC, WHEN, strength and transfer macros |
| RifeMetal | cinemore/rife-metal 1fef4869a44fca32848102b9f6a774a20eb50db6 | Apache-2.0 | locally modified source, tests, bundled weights in vendor/rife-metal |
| RIFE v4.26 weights | hzwer/Practical-RIFE via RifeMetal .rmw conversion | MIT per upstream THIRD-PARTY.md | bundled native resource; not plugin |
| IINA | iina/iina 1.4.4 / 1.5.0 | GPL-3.0 | reference and testing; application not redistributed |
| mpv | mpv-player/mpv | GPL-2.0-or-later default; optional LGPL build | pinned source downloaded for isolated local native-filter build; custom mpv binary not in release package |
| FFmpeg | system 8.1.1 / IINA build | system build enables GPL and version3 | external tool and native libmpv runtime dependency; optional local SDR thumbnail process, not bundled |
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

2026-10-16 local RifeMetal changes: immutable fp16 timestep tensor cache (up to eight entries), ordered multi-timestep submissions with a final batch wait, retained output-plane lifetimes and error draining. The upstream Apache-2.0 license and notices remain unchanged. See `docs/phase5-6-closeout-20261016.md` for limited validation and unverified performance claims from the handoff.

## LittleCMS 2.19

Native mpv ICC color management now links LittleCMS 2 from Homebrew (`lcms2` / `little-cms2`). Source: https://github.com/mm2/Little-CMS . License: MIT; the complete notice is included in `LittleCMS-LICENSE` and copied into the development app resources.

## Timeline preview fallback (2026-10-15)

The player optionally invokes the existing local FFmpeg 8.1.1 executable for SDR thumbnails when AVFoundation cannot decode a local file. Upstream: https://ffmpeg.org/ ; local GPL/version3 configuration and licenses above apply. No executable was downloaded or added to the app bundle. Arguments and timestamp handling were checked against the installed FFmpeg manual; runtime thumbnail accuracy remains unverified in this iteration.


## Microsoft Authentication Library (MSAL)

- Source: https://github.com/AzureAD/microsoft-authentication-library-for-objc
- Version: 2.16.0, revision `8dfe5bf41fe10e6d2afed62a72c4232adbef20f4`, pinned in Xcode `Package.resolved`.
- License: MIT; complete notice in `MSAL-LICENSE`, also copied into application Resources.
- Official Swift Package binary URL: https://github.com/AzureAD/microsoft-authentication-library-for-objc/releases/download/2.16.0/MSAL.zip
- Upstream SHA-256: `3bef53dae500878c2f07fd7493d54063f4fdcb057dfdb3c239256289a349edb8`; independently checked before header inspection, also verified by SwiftPM.
- Used for OneDrive public-client login, refresh and private application Keychain caching. No client secret is embedded.

## Standalone local player bundle (2026-10-21)

The player packaging script now copies the actual arm64 runtime dependency closure, the installed FFmpeg preview executable, and the RIFE/FSRCNNX SwiftPM resource bundles into the app. Earlier statements above that dependencies are external describe prior development deliveries and the separate IINA plugin. `Contents/Resources/RuntimeDependencies.json` records exact installed versions and source binary hashes; `RuntimeLicenses/` retains installed upstream notices, available Homebrew source recipes/SBOMs, RifeMetal/model notices and shader license texts. Original binaries are not changed; packaged copies have relocated load commands and new development signatures.

This is a personally signed local build, not a notarized public release. Corresponding source distribution and reproducible dependency builds must be completed before publishing a GPL/LGPL binary release; notices alone are not a substitute for those obligations.

RIFE 4.25 Lite is available only through the opt-in experimental conversion script. Source and weights come from the [official Practical-RIFE model link](https://drive.google.com/file/d/1zlKblGuKNatulJNFf5jdB-emp9AqGK05/view); upstream explicitly places these model links under MIT. `scripts/prepare-rife-lite.py` pins the archive SHA-256, uses `torch.load(weights_only=True)` and records source/output hashes in `build/models/rife-v4.25-lite.json`. The MIT notice is copied alongside the generated artifact. No Lite weight is bundled in the default player. Local changes add schema validation, model-dependent alignment and official stage-mask replacement semantics for both 4.26 and Lite.

## SPAN Core ML diagnostic prototype (2026-10-25)

Audited [official SPAN](https://github.com/hongyuanyu/SPAN) at `c77a5917759f09e66fbc7124220c5afc5ee221e5`; Apache-2.0 source and retained attribution/license in `vendor/span/`. The official README links `span.zip`; only its `spanx2_ch48.pth` is used, checksum pinned in `scripts/prepare-span.py`. No separate weight license is present in that archive; weights remain experimental local artifacts and are not bundled in the player. Core ML conversion uses Apple coremltools 9.0 (BSD-3-Clause, build dependency only), PyTorch 2.12.1 and NumPy; fixture preparation uses Pillow. coremltools warns that this PyTorch version is newer than its tested range. Export manifests record versions and hashes. Numerical parity failures remain explicit and require a diagnostic override; this is not a production model release.

### TMDB online metadata (optional, API v3)

Source: https://developer.themoviedb.org/ and https://www.themoviedb.org/about/logos-attribution (reviewed 2026-11-08).
Uses user-supplied API Read Access Token. TMDB data and the official unmodified logo are subject to TMDB API/branding terms, not this repository's source-code license. Logo asset: `Assets.xcassets/TMDBLogo.imageset/tmdb.svg`, downloaded from the official attribution page. Non-commercial API use requires attribution; commercial licensing is separate. Settings include a Credits section with the official notice and logo.
