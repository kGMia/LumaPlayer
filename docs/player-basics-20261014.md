# Native settings, live information and playback basics — 2026-10-14

For the separate IIVE Player (macOS 27, Xcode 27, arm64). The existing IINA plugin and IINA.app are unchanged.

## Live video information

Show or hide the overlay from any of these entry points:

- Playback strip → **Information** toggle.
- **View → Video Information** (`⌘I`).
- **Settings → General → Show Live Video Information**.
- Quick enhancement popover or the optional inspector.

The preference persists between launches. The overlay now includes video codec/profile and video packet bitrate alongside source and output resolution/cadence. The inspector additionally shows declared video bitrate, audio codec and audio packet bitrate.

`video-bitrate` and `audio-bitrate` come directly from mpv. They estimate compressed packet bits per second over timestamp intervals, often updating at keyframes. They are neither total file bitrate nor network throughput. File-declared bitrate is shown separately; missing/zero/invalid values display **N/A**. Output FPS remains an estimate from frame timestamps, not measured physical display FPS.

## Separate native Settings window

Use **IIVE Player → Settings…** (`⌘,`), the toolbar gear, or **Open Settings…** in the floating quick panel. The window uses SwiftUI's system `Settings` scene and `SettingsLink`, with three tabs:

- **General:** live information, auto-hiding controls, resume positions, clear local history, shortcut reference.
- **Enhancement:** master enable, SR backend, FI backend, RIFE tier/cadence, performance fallback and actual stage status.
- **Playback:** repeat mode, audio/subtitle selection, external subtitle loading, audio/subtitle offsets and subtitle scaling.

General/enhancement preferences and repeat mode persist. Timing offsets, subtitle size and track choices operate on the current mpv session; they are not saved as global defaults. Positive delay presents that track later. Subtitle scaling depends on the subtitle format.

Enhancement changes now propagate through the model instead of relying on the main view being visible. Settings, the quick panel and inspector therefore share one configuration. The inspector starts collapsed to leave more room for the picture.

## Playback functions

| Operation | Entry point |
| --- | --- |
| Open one or multiple files | `⌘O`, native multiselect panel; multiple-file drop |
| Add files to queue | `⇧⌘O`, queue's Add Files button |
| Show queue | `⇧⌘P`, toolbar list button, floating More menu |
| Play queued item | Click its name in Play Queue |
| Remove queued item | Minus button; current item protected |
| Previous / next video | `⌘←` / `⌘→`, Playback menu or More menu |
| Chapters | Playback / More → Chapters, using embedded timestamps |
| Repeat | Off / Current Video / Play Queue |
| Frame step forward | `.` or Playback / More menu; pauses after stepping |
| Mute / unmute | `M` or speaker button; preserves volume |
| Save screenshot | `⌥⌘S`, Playback / More → Save Screenshot… |
| Reveal file | Playback → Show in Finder |
| Stop | Playback → Stop |

Screenshot saving uses a native `NSSavePanel` and mpv's rendered `window` screenshot; it includes video rendering/scaling and mpv subtitles, but not SwiftUI controls. The chosen PNG path is passed to mpv. An existing destination requires the save panel's normal overwrite confirmation. Original media is never changed.

The queue is session-local, not a persisted library. At the last item, playback retains the last frame; when a next item exists, mpv advances naturally. Chapters are unavailable when the file contains none. Remote URLs, media library indexing and playlist import/export are outside this update.

Closing the player releases its session even if Settings or Play Queue remains open. **Window → Player**, or opening/adding a file, can reopen the video window. Closing settings does not terminate active playback. These lifecycle changes compile but have not received full GUI regression testing.

## Basic validation only

- Xcode Debug build: successful, arm64 / macOS 27. Both new Swift files are registered in the checked-in project and optional project generator; existing project customizations preserved.
- A real 12-second 720p24 fixture played with enhancements off in the newly built player. This run checks controls, not model throughput.
- `scripts/smoke-player-controls.py --socket <dedicated test socket>` passed. Recorded H.264 and **7,672,827 bit/s** video packet bitrate. A forward step moved PTS **2.000000 → 2.041667**. Mute, audio/subtitle delay, subtitle size, repeat properties, queue append/next/previous/remove and saving a real rendered PNG all passed.
- Evidence: `../benchmarks/results/player-controls-20261014-141335.json`, associated PNG, and `settings-ui-check.jsonl` snapshots.
- Native UI capture returned ScreenCaptureKit error **-3811**. Final Settings/Queue layout, menu interaction and info-toggle appearance have **not** been visually verified in this update. IPC checks establish backend behavior, not UI interaction correctness. Full model/performance testing was intentionally omitted.

Build and run:

```sh
scripts/build-player-modern.sh
open 'build/Xcode/Build/Products/Debug/IIVE Player.app'
```

Or open `IIVEPlayer.xcodeproj`, select **IIVE Player → My Mac**, and Run. The app still needs the workspace and local Homebrew libraries; it is not a portable signed distribution.

API evidence: the installed macOS 27 SwiftUI interface (`SettingsLink` / `Settings`) and pinned mpv `DOCS/man/input.rst` (`video-bitrate`, `track-list/N/demux-bitrate`, `chapter-list`, `playlist-*`, `frame-step`, `screenshot-to-file`), plus `DOCS/man/options.rst` (`keep-open`, repeat and subtitle options).
