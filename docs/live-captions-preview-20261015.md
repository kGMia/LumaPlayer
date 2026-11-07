# Preview, live captions and pipeline update — 2026-10-15

## Use in IIVE Player

Open `build/PersonalTeam/IIVE Player.app`, or build the **IIVE Player** scheme in `IIVEPlayer.xcodeproj` with Xcode 27.

In **Settings → Playback → Audio & Subtitles**, or the enhancement inspector's **Audio & Subtitles** section:

1. **Subtitles · Bottom** selects the primary subtitle track or **Live Captions · Apple Speech**.
2. **Second Subtitles · Top** independently selects another track or live captions. One native track cannot occupy both slots; live recognition occupies one slot at a time.
3. **Load Subtitles…** and **Load Second Subtitles…** load and select an external file into the corresponding slot without replacing the other slot.
4. Choose **Speech Language** to match the spoken audio. Live recognition is transcription, not translation. For bilingual output, select an existing translated subtitle track in the other slot.
5. If the language model is missing, press **Download Apple Speech Model**. This explicitly starts the system-managed download from Apple. Unsupported languages/hardware and installation failures are reported; no placeholder transcript is shown.
6. **Restart Live Captions** retries after an error. Choose **Off** or a regular track in the active live-caption slot to stop recognition.

The transport bar's playback menu also contains a **Subtitles** submenu with both slot selectors. Native second subtitles use mpv's `secondary-sid` and its default top placement. Bitmap subtitles may retain their authored position; this limitation is stated in the UI. Settings include a separate native second-subtitle delay.

## Preview changes

- Empty thumbnail rectangles have been removed. Before any real image is ready, the bubble contains the cursor time/chapter only.
- A small, bounded warm-up starts before the first hover: current position followed by up to twelve coarse positions, at least two seconds apart. Interactive requests take precedence; there is only one logical decode in flight.
- Completed image presentation now runs independently of the canceled hover request. During pointer movement, images can update even if the request that decoded them is no longer current.
- The last image stays visible until a replacement is available. Nearest cached images are available immediately, including coarse warm-up frames; their actual time is labeled `Preview ≈` so a held/approximate frame is not presented as an exact seek preview.
- Each player model owns its preview service; windows no longer invalidate each other's cache.

First image generation still costs decoding time. This change removes the empty-image presentation and cancellation starvation, not the physical decoding latency. AVFoundation-incompatible files can still show only time/chapter; a separate fallback decoder is not part of this update. Actual visual responsiveness has not been measured.

## Speech data path

`af_iive_captions.c` is a native filter in this project's pinned mpv build. It passes each playback audio frame through unchanged and uses libswresample only on a side branch to produce mono Float32 PCM at 16 kHz. It neither records a microphone nor captures other applications' audio. The tap is prepended before playback speed processing and is installed only when live captions are ready.

The side queue holds at most two seconds. mpv's client queue reads it every 250 ms using `af-metadata/iive-captions`; a validated `af-command ... ack serial:count` consumes the returned samples. Reads are pure because mpv may query metadata more than once while converting property types. PCM is transferred as base64 through this existing string metadata interface, decoded before delivery to Swift, and excluded from normal telemetry/log snapshots. This has bounded serialization overhead; it is not a zero-copy audio bridge.

`PlayerSystem/LiveCaptions.swift` uses Apple `SpeechAnalyzer`, `SpeechTranscriber`, `AssetInventory`, and macOS 27 `AnalyzerInputConverter`. Model preparation finishes before enabling the tap. Conversion/analysis run off the UI actor at utility priority. Analysis uses the system resource limits and short-term model retention; this does not establish measured ANE or Neural Accelerator utilization.

There are bounded audio and analyzer-input streams. A seek, source discontinuity, changed audio track or file starts a new recognition epoch. Queue overflow resets discontinuous input or stops a lagging analyzer with a visible error. EOF flushes the converter and finalizes analysis. Disabling captions and closing the player cancel tasks, remove the audio tap, and finish the analyzer; the system manages downloaded assets and model retention.

Recognized phrase timestamps map back to media PTS, with the player's audio-delay setting applied to presentation. Pause holds the display; late partial results have a limited readability window. Captions are drawn in SwiftUI in both the normal/fullscreen player and mini player. Recognition is inherently delayed and may be inaccurate; no real-media latency or accuracy result is claimed.

Apple documents that the speech-recognition authorization flow for server-backed `SFSpeechRecognizer` does not apply to `SpeechAnalyzer` transcriber modules. This implementation uses only the latter and does not add microphone capture permissions. See [Apple's authorization documentation](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition), [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer), and [AnalyzerInputConverter](https://developer.apple.com/documentation/speech/analyzerinputconverter). Buffer ownership and EOF flushing follow [convert(_:at:)](https://developer.apple.com/documentation/speech/analyzerinputconverter/convert(_:at:)). APIs were also checked against the installed Xcode 27 Speech Swift interface.

Native subtitle selection was checked against the pinned mpv source (`player/command.c`, `DOCS/man/options.rst`, `DOCS/man/input.rst`) and [mpv's manual](https://mpv.io/manual/stable/#options-secondary-sid). UI selection uses `track-list/main-selection` to distinguish the primary and secondary tracks, rather than incorrectly treating both selected tracks as the primary one.

## Video pipeline changes

- RIFE keeps one sparse luma/chroma or RGB signature for the previous source frame. Consecutive pairs no longer lock and sample the same GPU-backed input twice. Sampling locations, normalization, scene-cut and duplicate thresholds remain the same; this is still a heuristic detector.
- FSRCNNX caches at most one retained immutable input surface and its output. When interpolation emits a hold of that exact input surface, the output is reused with the new mpv frame timestamps/attributes. Different pixels, chroma interpretation, copied input, resets and incompatible formats do not qualify. No approximate visual-similarity reuse was added.
- **Reused SR outputs** in the inspector reports the actual counter. One extra input/output pair can remain retained; this is a bounded memory tradeoff, not an unbounded frame queue.

These optimizations require real-video comparison to quantify their benefit. No claim is made that balanced RIFE is now realtime, or that the new paths improve a measured FPS figure.

## Basic checks performed

- Xcode arm64 Debug build succeeded, final code build: 8.790 seconds, no errors. Full native mpv filter and Swift Speech/UI source compiled. Only the existing AppIntents metadata warning remains.
- `tests/caption_tap_smoke.py`: two seconds of synthetic stereo 48 kHz audio, null video and null audio outputs. Received exactly **32,000 mono 16 kHz samples in 16 packets**, contiguous PTS, no dropped tap buffers, and EOF. No speech model was run.
- The short check caught a real metadata-read side effect; explicit acknowledgment fixed it. Initial sandbox execution could not bind its local IPC socket; the final successful run used permission to create that local socket.
- No Computer Use, GUI inspection, real-media playback/quality validation, ASR model download, ASR accuracy benchmark, or full test suite was performed.
- Logs: `benchmarks/results/captions-preview-build-20261015.log`, `captions-preview-backends-20261015.log`, and `caption-tap-smoke-20261015.json`.

## Remaining user checks

Check rapid hover and first-hover appearance, live captions with the intended language model, track changes and seeking, long pauses, EOF, and both subtitle slots in fullscreen/mini mode. In particular, verify live-caption latency/placement with the SR/FI combination you actually use. The app remains a workspace/Homebrew-dependent development build, not a relocatable distribution package.
