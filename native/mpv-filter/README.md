# Experimental native mpv filter

`vf_iive_rife.c` is an actual, compile-time registered mpv filter. It sends decoded
frames through the Swift streaming C ABI and returns generated `mp_image` frames
with media PTS to mpv's output chain. It does not encode/redecode video or use PNGs.
Audio stays in mpv's normal audio pipeline. Interpolation is before GPU scaling.

Build a **separate** player/libmpv; never copy its dylib into IINA.app:

```sh
brew install meson ninja pkgconf ffmpeg libass libplacebo
scripts/build-mpv.sh
build/mpv/mpv --no-config --vo=null --ao=null --hwdec=no \
  --vf=iive-rife=fps=48:tier=fast input.mov
python3 benchmarks/native_player.py benchmarks/fixtures/tagged-720p24.mov --render
```

The script pins mpv revision `88eb9f2e73945d8bc9c133a2f67babaa9af34680`, patches
only `.research/mpv-native`, and builds in `build/mpv`. The narrow mpv build enables
libmpv OpenGL and a CLI with null output. `scripts/build-player.sh` adds a
separate visible AppKit host (see ../Player/README.md). `build/render-smoke` supplies a real offscreen CGL framebuffer through
the public libmpv render API. This proves filter→render transport without claiming
that the stock IINA app is using that library. The source and build recipe are
distributed; the custom mpv binary is workspace-local, not a portable release.

Options: `fps=48|60`, `tier=fast|balanced|hq`, `fallback=yes|no` (default yes).
Requires software-decoded SDR BT.709, BT.1886/sRGB transfer, no rotation, dimensions
≤4096 and source FPS below target. Unsupported frames pass through unchanged with
a warning. The adapter converts to BGRA8 with swscale, copies into an IOSurface
CVPixelBuffer, invokes Metal, and copies the result into BGRA `mp_image`. These
copies and RGB conversion are a deliberate prototype limitation, not zero-copy.
The Swift model additionally has upstream CPU padding/cropping paths.

The filter now uses one serial pthread worker for conversion, stream inference and
output copies. Only the mpv thread touches pins. One submitted input job and a
fixed batch of at most eight output frames enforce backpressure; no unbounded
frame queue is allocated. The worker holds the adjacent source context and the
Swift stream's bounded interval, in addition to model tensors/caches.

Seek increments a generation, clears queued outputs, and resets the stream on the
worker. In-flight old-generation results are discarded before returning to mpv.
Pause stops downstream requests. EOF drains only the final declared duration.
Scene cuts and duplicates use the existing hold policy and do not increase the
AI-generated counter. Unsupported source intervals above 100ms reset temporal
context rather than constructing an oversized output batch.

Full conversion+model+copy time is compared against the source interval divided
by playback speed, with 10% reserved headroom. After three warm-up pairs, three
consecutive misses latch a return to source frames. Errors also fall back to
source frames instead of breaking playback. The latch clears on a new seek/session
or explicit filter replacement, not on a successful subsequent frame; EOF retains
the degraded flag. Audio and media PTS are never retimed by this filter.

`vf-metadata/iive-rife` exposes state, generated/emitted counts, generation,
stale-job count, queue/inflight counts, processing time, mean/peak, and fallback.
Label the filter `@iive-rife`. Hosts changing speed must send
`vf-command iive-rife speed <value>`; the provided host follows UI and IPC speed
changes. Generic mpv hosts that omit this command have a 1× processing budget.

The pinned mpv revision needed two reproducible fixes for this minimal build:
include `osdep/utils-mac.c` without Cocoa (otherwise device enumeration calls an
unresolved CFString helper); send `AudioChannelLayout` through the public
`kAudioUnitProperty_AudioChannelLayout` input property, not the incompatible
ChannelMap/SInt32-array property. Both patches live in `scripts/prepare-mpv.py`.

Verified: actual visible playback, CoreAudio, 720p fast 24→48/60, and a short
pause/seek/speed/fallback check. This is not a long-form quality/thermal test.
Stock IINA cannot dynamically load this filter. HDR processing, zero-copy and a
portable signed app remain unfinished.

Original adapter GPL-3.0-or-later; mpv default GPL-2.0-or-later; combined work uses
GPLv3 with Apache-2.0 RifeMetal and retained weight notices. External dependencies
remain separately installed. See the project's THIRD-PARTY.md.

## Native model update (2026-10-14)

`iive-fsrcnnx=tier=fast|quality:fallback=yes` now runs actual trained FSRCNNX 8/16 through Swift/MPSGraph, using the shared bounded worker in `vf_iive_apple.c`. RIFE BT.709 NV12 input now receives GPU NV12 output without synthesized BGRA conversion. Combine RIFE first, then native SR. See [implementation and minimal checks](../../docs/native-models-20261014.md). This supersedes the older conversion description above; full end-to-end zero-copy is still incomplete.
