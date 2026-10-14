# Measurements — M5 smoke tests, 2026-10-12

User explicitly requested that full testing was unnecessary. Only short functional
smokes and targeted logic tests were run. No long-form realtime guarantee follows.
Machine: base M5 MacBook Air, 10 GPU cores, 24 GB; macOS 27.2. IINA 1.5.0 was
run separately from its official mounted disk image; installed IINA 1.4.4 was
left intact. No power/thermal isolation was applied. Input is generated testsrc2
or moving gradients, **not** a natural-video quality evaluation.

| Test | Actual result | Evidence / limitation |
|---|---|---|
| Plugin build | TypeScript check + bundle + .iinaplgz success | npm run pack |
| Targeted logic | 7 JS tests + 3 Swift PTS tests pass | results/plugin-tests.txt, native-tests.txt |
| FSRCNNX 8, 1280×720/24 → 2560×1440 | 14 shader passes executed; sum of per-pass rolling averages 11.564ms | iina-fsrcnnx-passes.json, iina-sr-summary.json; this sum is not wall latency |
| FSRCNNX playback UI | Source 24fps; displayed drop counter 0 at snapshot | manual AX inspection; no long-duration claim |
| CPU minterpolate 24→48 | Filtered estimate 48fps, A/V drift snapshot 0s, drop counter 127 | iina-motion-*.json; counter is cumulative within playback, not a timed delta; software decode required |
| RIFE fast 720p model stream, 6 measured midframes after 3 warmup pushes | mean 6.409ms, P50 4.970ms, P95 11.963ms; 154.87 generated frames/s; peak RSS 140,181,504 bytes | rife-720p-fast.json; excludes codec, model setup and display; tiny sample |
| RIFE fast 720p, 1s 24→48 video | 48 frames, 23 synthesized; total 0.539s, 89.03 output frames/s; pair mean 8.049ms / P95 10.140ms | rife-stream-48-final.json; FFprobe: 48/1 fps, video/audio both 1.000s |
| RIFE fast 720p, 1s 24→60 video | 60 frames, 46 synthesized; total 14.630s, 4.10 output frames/s; pair mean 18.967ms / P95 29.354ms | rife-stream-60.json; concurrent experimental player load and setup included; FFprobe: 60/1 fps, both tracks 1.000s |

48/60 output totals include original frames and held tail frames; throughput is
not inference FPS. The 60fps smoke proves scheduling/output, **fails** a realtime
wall-time target, and cannot be compared directly with the warm model benchmark.
Do not extrapolate either tiny run to sustained films or thermally constrained M5.
`rife-stream-48.json` is the initial superseded run: excluded setup and found an
encoder-timebase rounding issue. Use `rife-stream-48-final.json` for the fixed run.

Measured presentation FPS, GPU/CPU utilization and player memory were not reliably
instrumented. They remain null/N/A. Native peak RSS is getrusage.ru_maxrss (bytes
on Darwin), not instantaneous GPU allocation. Offline output has no intentional
frame dropping; this says nothing about displayed frames.

## Not run

720p→1080p exact viewport, 1080p→4K, sustained 4K, 30/60fps source matrix,
RAVU / CAS individual render acceptance; FSRCNNX 16 natural-video quality acceptance, balanced/hq RIFE, multiwindow
stress, all seek/pause/speed/EOF combinations, natural-video artifact scoring,
HDR colorimetry, long-form A/V sync and thermal tests. RIFE+SR in stock IINA is
unsupported, so no invented combined measurements are included.

## Reproduce

`benchmarks/run.py --smoke` runs a small real model benchmark. `--full` runs
720/1080/2160 input grids, 24/30/60 source rates, 48/60 targets where upconversion
is appropriate, all RIFE tiers, CPU motion, and decode→model→encode. Each subprocess
has a timeout; failed/timeout entries retain status and stderr. Expect significant
runtime and disk use. It does not silently skip failures as successes.

`benchmarks/player.py` exercises Off, FSRCNNX, motion48/60 and SR+motion48/60 in a
**dedicated** player IPC instance with plugin effects disabled. Use one fixture
and desired viewport at a time; compare `source` and `viewport` in results to
ensure upscaling conditions are met. Collects actual GPU pass histories, filtered
FPS, drops and A/V drift, and restores its option snapshots. This script is
provided but the full matrix was not run in this session.

## Follow-up smoke — 2026-10-13, user-updated IINA 1.5.0

Only focused checks were added; no full matrix was run.

| Check | Actual result | Evidence |
|---|---|---|
| TypeScript build and regression | 8 tests passed, including mpv 0.41 native hwdec-list restore | plugin-tests-updated.txt |
| Updated installed IINA SR | FSRCNNX verified on 1280×720 → 2560×1440 playback | iina-updated-sr.json; final GPU passes have execution samples |
| Updated installed motion | labeled minterpolate active, hwdec=[no], estimated output 48fps; snapshot A/V drift 3.761489s, drops 62 | iina-updated-motion-active.json; unsuitable for default realtime use |
| Automatic motion fallback | filter removed after overload, hwdec=[auto] restored | iina-updated-motion.json |
| Manual FI off | no owned filter, hwdec=[auto], 24fps estimate, drift 0.000008s snapshot | iina-updated-motion-restored.json |
| Separate native mpv 24→48 | 48 outputs, 23 synthesized, strictly increasing PTS with 1/48 spacing | mpv-rife-48.log and summary JSON |
| Separate native mpv 24→60 | 60 outputs, 46 synthesized, strictly increasing PTS with 1/60 spacing | mpv-rife-60.log and summary JSON |
| Separate libmpv OpenGL render | 45 render calls with nonblack pixel readbacks; 48 generated-chain outputs, 3 player drops | mpv-rife-render-48.txt; offscreen, not physical display FPS |
| Native release directory | packaged binary/resources execute on Apple M5; two measured warm pushes, mean 9.523ms, P95 10.255ms | native-package-smoke.json; packaging smoke, not sustained benchmark |

The custom mpv filter compiles against the pinned mpv checkout, Homebrew FFmpeg
8.1.1 / libplacebo 7.360.1 / libass 0.17.5. CoreAudio compilation emits upstream
SDK deprecation warnings. The adapter itself compiled without diagnostics.
The OpenGL smoke uses the public render API used by IINA, but does not replace or
run inside IINA. Rendering dropped frames during the short cold-start run. No
new stable-realtime claim, GPU utilization number, or natural-video score follows.
CPU minterpolate was disabled after testing; SR and performance guard remain on.

Reproduce the isolated native transport checks with `scripts/build-mpv.sh` then
`python3 benchmarks/native_player.py benchmarks/fixtures/tagged-720p24.mov --render`.
These scripts do not modify IINA.app. See native/mpv-filter/README.md for scope.


## Preview 0.2 focused status/model smoke — 2026-10-13

The production plugin no longer activates CPU minterpolate. Historical motion
commands in the benchmark tools remain opt-in diagnostics, not supported plugin modes.
No complete benchmark matrix or new native model benchmark was run for this release.
The focused JS checks passed (13 tests), including legacy motion preference migration,
status verification, paused states, model identity and fallback/error distinction.

| Check | Observation | Raw evidence in benchmarks/results/ |
|---|---|---|
| No scaling needed | 1280×720 input and output; SR Bypassed, FI Off | status-v020-initial.json |
| Change model while paused | Selected FSRCNNX 16 reports Verifying, requests resume; does not reuse FSRCNNX 8 verification | status-v020-model16-verifying.json |
| Play FSRCNNX 16 | 1280×720/24 input → 2560×1440; status Active; final `IIVE FSRCNNX16 aggregation (luma)` pass count 256; snapshot drops 0, A/V drift 0.000014s | status-v020-model16-active.json |
| Pause | Overall and SR report Paused; performance monitoring paused | status-v020-paused.json |
| Restore Follow Quality Preset / Balanced | FSRCNNX 8 confirmed Active again; no video filter; hwdec=[auto] | status-v020-model8-restored.json |

The Sidebar was inspected in the real IINA window: PREVIEW 0.2, colored/text
status cards, disabled interpolation controls, removal notice and model selector
were present. Switching to FSRCNNX 16 and back used the Sidebar itself. Only the
dedicated fixture player was closed after the check. The installed plugin was
upgraded with a timestamped backup; IINA.app was not modified.

GPU-pass count is bounded mpv history, not a display-frame count. These snapshots
prove execution and status behavior, not sustained throughput, natural-video visual
superiority, HDR support or 1080p→4K performance. Measured presentation FPS remains
N/A. Stale heartbeat and fallback logic are implemented; no extra end-to-end fault
injection campaign was performed in this release.

## Native iteration 0.3

The asynchronous filter and visible AppKit player now have focused 720p fast48/60
CoreAudio measurements and pause/seek/speed fallback evidence. See
[real-time results](realtime-rife-results.md) for scoped measurements and failed
initial attempts. Historical synchronous/offscreen results above remain historical.
