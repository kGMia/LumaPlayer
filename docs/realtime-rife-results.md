# Native real-time RIFE iteration 0.3 — 2026-10-13

## Delivered

A separate AppKit/libmpv window with real Metal RIFE video playback and CoreAudio;
play/pause, timeline/±5s seek, speed, 48/60 target, model tier, RIFE off and Retry.
The filter now has a serial worker, one submitted job, bounded output batches,
generation-based seek invalidation, and full-processing-time overload fallback.
The renderer has its own serial queue, separate from ordinary libmpv calls.
Source and audio files remain unchanged. Original IINA.app is untouched.

Current local executable: `build/IIVE-Player.app`.
Run: `scripts/run-player.sh "/absolute/path/video.mp4" 48 fast`.
Build: `scripts/build-player.sh`.

The stock IINA plugin remains 0.2.0; its RIFE controls remain unavailable. This
iteration delivers working separate native playback, not stock-IINA injection.
The app links local workspace/Homebrew libraries and is not a portable release.

## Focused measurements

Hardware: base Apple M5, 10 GPU cores, 24GB, macOS 27.2. Input: local synthetic
1280×720, 24fps, 12s MP4 fixture with mono AAC. RIFE v4.26 fast, software decode,
SDR BT.709/BT.1886, real CoreAudio driver (muted during tests), normal 1× clock.
These are short functional/realtime-cadence checks, not sustained thermal tests
or natural-film quality acceptance. No full matrix was run.

| Metric | 24→48 | 24→60 |
|---|---:|---:|
| Emitted video frames | 576 | 720 |
| AI-generated frames | 287 | 574 |
| mpv dropped frames | 0 | 0 |
| Mean render callbacks/s after first media second | 48.0007 | 59.9996 |
| Sampled full-processing latency P50 | 13.270ms | 23.995ms |
| Sampled full-processing latency P95 | 18.242ms | 28.084ms |
| Sampled absolute A/V drift P95 | 0.0091ms | 0.0042ms |
| Maximum sampled ready queue | 1 | 2 |
| Real audio device | CoreAudio | CoreAudio |
| Physical display FPS | N/A | N/A |

Processing latency includes input conversion, stream inference and output copies,
and is **per input job/interval**, not per displayed frame. 60fps commonly requires
two AI outputs per source interval, so its ~24ms interval time does not imply
failure against a 16.67ms output-frame period. Telemetry samples the latest job
four times per second; these percentiles are sampled, not every-job histograms.
Render callback rate is not physical presentation measurement. A/V numbers are
mpv software-clock estimates, not acoustic/display latency measurements.

Evidence:
- `benchmarks/results/realtime-48-20261013-143846.{json,jsonl,log}`
- `benchmarks/results/realtime-60-20261013-144013.{json,jsonl,log}`

## Interaction and overload result

`realtime-60-interactions-20261013-144547.{json,jsonl,log}`:
paused, resumed, sought to 8s then 2s, changed to 2×. Generation reached 2;
**one old in-flight job was discarded**. PTS remained increasing within each
emitted generation, and old generations did not appear after new ones.
2× processing exceeded the reserved budget, latched source-rate fallback,
continued to EOF with zero player drops, and retained `degraded-finished` status.
Sampled absolute A/V drift P95 was 3.807ms. Maximum sampled ready queue was 2.
Normal quit returned exit code 0. This does not cover every interaction combination.

The asynchronous null-output 1s tests also produced 48/60 outputs with 23/46 AI
frames and exact cadence. Evidence: `native-pipeline-48/60.{json,txt}`. They test
PTS transport, not display timing.

## Failures found and fixed

1. First visible test had no audio. Pinned mpv used ChannelMap with an
   AudioChannelLayout payload; those API types do not match. The build patch now
   uses the input AudioChannelLayout property. Real mono CoreAudio then initialized.
2. Querying audio devices initially crashed because the minimal no-Cocoa build
   omitted `utils-mac.c` CFString helpers. The build includes them; device queries
   and process teardown succeeded in both final tests. Initial crash logs/results
   are not counted as successful audio tests.
3. Explicitly attach/update the NSOpenGL drawable before renderer creation; the
   initial framebuffer error no longer appears in final baseline logs.
4. The first interaction harness incorrectly required an Active sample after 1s
   even when overload legitimately fell back. It now includes source-rate playback
   for A/V checks. The failed result remains preserved (`144102`).
5. EOF initially erased the fallback indicator; fixed to retain degraded status.

CoreAudio patch basis: local Xcode SDK AudioUnitProperties.h and Apple's public
[AudioChannelLayout documentation](https://developer.apple.com/documentation/audiotoolbox/kaudiounitproperty_audiochannellayout).
The deterministic patches are in `scripts/prepare-mpv.py`.

The original visible window/control tree was inspected through macOS accessibility.
A final visual reinspection was blocked because the Mac was locked; no final
screenshot or natural-video visual acceptance is claimed.

## Remaining

- Stock-IINA integration requires a maintained native build/upstream interface;
  its JavaScript plugin cannot inject decoded video frames.
- Only fast 720p is measured here. 1080p, balanced/hq, SR combination and sustained
  thermal performance remain unverified; controls do not imply those are realtime.
- CPU BGRA conversion/copies and upstream padding/cropping remain. No zero-copy claim.
- Cold start can delay initial playback. A GPU call already running cannot be
  cancelled; seek discards its result. Shutdown waits for the worker to finish.
- The guard measures adapter processing, with 10% reserved budget; it does not
  directly measure total decode/render load. Add deadline-aware output/host drop
  monitoring before calling the player production-ready.
- HDR/10-bit handling and HDR presentation in this SDR host are not supported.
- Fullscreen shortcuts, subtitle UI, persistent player settings, multiwindow GPU
  arbitration, signed/portable packaging and extensive error testing are unfinished.

Next: bound cold-start behavior and reduce pixel copies, add host-level drop/drift
fallback, then measure natural 1080p fast48. Keep stock IINA unchanged meanwhile.

User follow-up: 48fps/fast is usable, balanced is nearly unusable on the tested media
(resolution/codec not supplied). See [next-direction evaluation](mac-interpolation-direction.md).
This feedback does not extend the earlier synthetic 720p measurements to other media.
