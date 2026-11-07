# Luma Player

The current Xcode/SwiftUI player is documented in [docs/player-0.4.md](../../docs/player-0.4.md).
Open the root `LumaPlayer.xcodeproj`; run the **Luma Player** scheme on My Mac (macOS 27, arm64).
Sources under `Modern/` are the active app; `VideoView.m` is the shared libmpv rendering adapter.

The notes below describe the preserved 0.3 comparison host, **not** the current Xcode UI.

---

# IIVE Experimental Player (native iteration 0.3)

A visible macOS playback host for the project's real RIFE Metal mpv filter.
This is a **separate local app**, not the IINA plugin and not a replacement for
IINA.app. The existing plugin remains 0.2.0 with RIFE unavailable in stock IINA.

## Run

On the current development machine, open `build/Luma Player.app`, then **Open…**,
or from the project root:

```sh
scripts/run-player.sh "/absolute/path/movie.mp4" 48 fast
# or 60 fast; omit all arguments to open an empty player
```

Controls: RIFE on/off; target 48/60; fast/balanced/hq; pause/resume; ±5s; timeline;
0.5/1/1.5/2× speed; Retry RIFE; Open to switch files. Playback includes CoreAudio.
Volume defaults to 50%; development tests used mpv mute while still running the
real audio clock. No source media or IINA preferences are changed.

Status reports generated AI frames, emitted frames, queue length, latest full
processing time, render callbacks, mpv drops and A/V drift. Render callbacks are
**not physical display FPS**. Unknown data is N/A. `degraded` means source-rate
playback; Retry, seek or loading a new file resets the filter session. Initial
model/graph setup can delay the first frame; no background warm-up promise.

Only unrotated, software-decoded SDR BT.709 with BT.1886/sRGB transfer below target
FPS is interpolated. HDR, hardware pixel formats, unknown colors and unsupported
inputs are bypassed. The independent OpenGL host is SDR-only: HDR passthrough to
this host is not an HDR presentation guarantee. Use IINA for HDR playback.
The model choices exist, but only fast 720p24→48/60 have current playback evidence.

## Build

```sh
# Official Homebrew dependencies; full Xcode + Metal Toolchain also required.
brew install meson ninja pkgconf ffmpeg libass libplacebo
scripts/build-player.sh
```

The build script first rebuilds the Swift backend and pinned custom mpv, then
compiles this AppKit/Objective-C renderer. `--host-only` skips native backend
rebuild for UI-only edits. Source modules are `main.m` (controls/telemetry) and
`VideoView.m` (dedicated serial OpenGL render queue). Rendering never shares the
thread that invokes ordinary mpv commands/properties.

This development `.app` uses absolute workspace rpaths and Homebrew libraries.
It is neither portable nor notarized; do not move it out of this workspace or
publish it as a standalone distributable. No IINA app signing, dylib replacement
or update channel is modified.

## Focused verification

```sh
python3 benchmarks/realtime_player.py benchmarks/fixtures/720p24.mp4 --fps 48
python3 benchmarks/realtime_player.py benchmarks/fixtures/720p24.mp4 --fps 60
python3 benchmarks/realtime_player.py benchmarks/fixtures/720p24.mp4 --fps 60 --interact
```

The input fixture is local test media (excluded from source archives). Any SDR
BT.709 short video below target FPS can be supplied, but the helper expects EOF
within 50s. It creates a dedicated window, unique IPC socket, immutable result
files, and closes only its own process. The interaction check pauses, seeks twice,
then runs 2× speed. Errors remain in the timestamped logs.

Current results and remaining limitations: `docs/realtime-rife-results.md`.
Copyright/license: original player code GPL-3.0-or-later; shared dependencies and
RIFE weights retain the root THIRD-PARTY notices.
