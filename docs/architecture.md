> **0.4 update:** The active player is now the SwiftUI Xcode target. It adds VideoToolbox SR/FI,
> pooled NV12 output references, actual shader-pass monitoring and RIFE NV12 output for FSRCNNX.
> See [player-0.4.md](player-0.4.md) for the current routes and limitations. Earlier sections
> below describe the foundation and 0.3 integration.

# Architecture

## Stock IINA plugin

`config.ts` validates every persisted/webview setting and chooses SDR processing.
`ownership.ts` merges the current shader list, owns exact paths and the
`iive-motion` filter label, and restores temporarily changed decoder settings
only if they still equal its applied value. No GPU profile, scaling kernel,
tone-mapping, audio-sync option or on-disk mpv configuration is replaced.
`performance.ts` implements a latched overload ladder. `main.ts` connects these
modules to official main-entry IINA APIs; `ui/` is a separate WebKit process.

FSRCNNX/RAVU operate on the LUMA plane before mpv's final scale; CAS is an
upstream MIT shader adapted for pre-scaling with explicit SDR transfer variants.
A shader is considered active only when its final pass has execution samples.
After five seconds of unpaused rendering without that evidence it is removed
and blocked for the file. Unsupported output backends therefore fail closed.

The stock 0.2 plugin is shader-only. CPU minterpolate activation was removed
following measured and user-reported severe stalls. Legacy preferences migrate
to FI off. A startup release message asks an existing 0.1 watchdog to restore its
lease before the new lease takes over; the owned filter label is also removed.
Legacy ownership/decoder restoration code remains for cleanup, not activation.
The plugin does not select software decode. RIFE controls remain unavailable.

The first 5s after configuration/seek are ignored for overload decisions. Three
bad samples (≥3 drops/s or |A/V drift|>150ms) reduce SR to CAS, then turn SR off.
Each action imposes a 10s cooldown. No automatic promotion within a file; Retry
or the next file resets the ladder. Pause/seek reset measurement baselines.

`status.ts` derives global and per-feature indicators from actual state. It
separates GPU-confirmed execution from selected settings, identifies the exact
8/16 model, and distinguishes pause, bypass, fallback and failure. External
removal of an owned shader stops the Active indication. Sidebar telemetry older
than 5.5s becomes Unknown; ARIA labels and text accompany colored dots.
FSRCNNX 16 uses a distinct final-pass marker so old 8-channel statistics cannot
verify a model switch. The menu can display a current status OSD on request.

IINA has no JS unload event. `watchdog.lua` runs within the same mpv instance and
holds a 5s heartbeat lease. Loss of the JS plugin removes only owned paths and
label, then conditionally restores decode mode. Per-player mpv instances prevent
cross-window interference. The data cache and saved defaults are shared; changing
settings in one window does not forcibly reconfigure other already-open windows.
The tiny watchdog stays resident until player shutdown, without a live lease.

## Native stream prototype

```
AVAssetReader (video BGRA IOSurface + compressed audio)
  -> adjacent frame pair + rational PTS scheduler
  -> RifeStream on a serial Metal/MPSGraph context
  -> ordered CVPixelBuffers (≤4 inferred frames per input interval)
  -> AVAssetWriter H.264 MOV + original audio timestamps
```

Timeline uses `origin + tick/targetFPS`; t=(outputPTS-prevPTS)/(nextPTS-prevPTS).
24→60 therefore alternates t={0,.4,.8} and {.2,.6}, not repeated midpoint frames.
Exact source ticks reuse originals; scene cuts and duplicates hold the old frame;
EOF holds the last frame only to its declared duration. Long intervals (>4 output
ticks) bypass inference; gaps >1s and nonmonotonic PTS fail explicitly. The model
supports more formats than the file reader accepts: the file reader remains BGRA8/BT.709, while the streaming bridge also accepts tagged NV12.
Upstream padding/cropping can copy CPU memory; this is not end-to-end zero copy.

The reader advances only after outputs are consumed; encoder backpressure is
bounded by a 30s timeout. Audio runs on a distinct serial queue. GPU infer failure
aborts the prototype, while sustained slow processing switches to source cadence.
The offline tool is not an interactive player: native seek/pause/speed integration
and a stock IINA frame transport remain incomplete.

`RIFEBridge` exports both pair interpolation and a streaming C ABI. The actual
`native/mpv-filter/vf_iive_rife.c` implements mpv's internal filter API and is
registered at build time in a separate pinned checkout. It uses software decode,
pooled IOSurface NV12 input and GPU NHWC FP16 conversion for BT.709 SDR (BGRA input fallback for other supported SDR), Metal inference and NV12 mpv output. The BT.709 NV12 route now fuses blending/cropping/YUV packing on GPU; synthesized outputs are reference-wrapped NV12. Legacy BGRA inputs retain their CPU output conversion. The adapter is demand driven with a serial inference worker, a generation-tagged
single job and at most eight queued output frames. Software input copies remain; original NV12 outputs are reference wrapped. mpv pins are only accessed on the filter thread. Audio remains inside mpv; generated video PTS stay on
the media timeline. mpv reset clears the stream, and EOF drains its tail.

A separate CGL test host proves the adapter's outputs reach libmpv OpenGL
rendering. This is not stock-IINA frame injection. IINA's signed app/library is
untouched, and its plugin keeps RIFE unavailable. A visible AppKit host now runs this library with CoreAudio and basic playback
controls. Comprehensive interactive playback validation and stock IINA integration
remain work. See native/Player/README.md and realtime-rife-results.md.

For mpv 0.41, hwdec is a native string list rather than the scalar used in older
builds. Both the plugin and Lua lease preserve its exact original representation.
Verification deadlines exclude paused/seeking time. Native statistics use a
bounded 4096-pair rolling latency window and full-stream count/sum.

## Native super resolution and interpolation (2026-10-14)

Actual FSRCNNX 8/16 shader weights are strictly exported into seven merged MPSGraph stages; Metal handles NV12 luma input and 2× subpixel/chroma output. `iive-fsrcnnx` shares the bounded Apple-adapter worker but calls the distinct IIVEFSR Swift C ABI. RIFE runs first, then native SR. Each SR input still passes through its IOSurface layout conversion; hardware decoder and inter-filter surface sharing remain future work. See [native model delivery](native-models-20261014.md) for basic test evidence and limits.
