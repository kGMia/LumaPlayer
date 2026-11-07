# Luma HDR Prototype — stage 3

Independent Metal/PQ grayscale and silent PQ/HLG HDR video prototype. **This is not a production HDR player and is not linked into Luma Player.** The old OpenGL/IOSurface EDR bridge remains disabled.

Build: `bash scripts/build-hdr-prototype.sh`

Run manually: open `build/Luma HDR Prototype.app`.

- Click **Open Video** in the toolbar, use **⌘O**, or press **O** to choose a local PQ or HLG HDR movie (AVFoundation-supported containers such as MP4/MOV). The experimental Metal path advances frames using source PTS and a monotonic host clock, without audio. The separate System Playback path uses AVKit with audio.
- Press **R** to return to the test pattern. Space pauses/resumes playback (or the pattern marker); left/right seek by 5 seconds; Space at EOF replays from the start; Esc closes the window.
- Accepted input: explicitly tagged PQ or HLG + BT.2020 primaries + BT.2020 non-constant-luminance matrix, video-range P010, progressive, square pixels, no clean-aperture crop or track rotation, left/center chroma siting. Missing tags, unsupported input are rejected; detected Dolby Vision configuration is routed to system playback, retaining the previous image. This is not a generic Dolby Vision compatibility guarantee.
- AVFoundation owns decoding; the app binds the retained CVPixelBuffer planes to R16Unorm/RG16Unorm Metal textures, without CPU pixel mapping. The frame and CVMetalTexture wrappers stay alive until GPU completion. One texture cache is reused by each stream. This does not claim the decoder itself performs no internal copy.
- Video conversion: high-ten-bit normalization → video-range expansion → BT.2020 NCL YCbCr to encoded RGB → PQ EOTF or HLG inverse OETF + OOTF → linear BT.2020 to linear sRGB → EDR reference-white scaling. Output is letterboxed. Gamut/highlight clipping is intentional for this stage, not production-quality tone mapping.
- Top half: full-range PQ ramp. Bottom half, left to right: source levels 0, 100, 203, 400, 1000, 4000 nits.
- Reference white is explicitly 100 source nits → EDR 1.0. These labels are source signal values, **not measured display luminance**.
- Current (not potential) display EDR headroom is sampled each tick. Output deliberately clips at that value, with no hidden tone curve. Bright patches may therefore look identical. This isolates transfer math; it is not the final tone mapper.
- Window title shows current headroom, completed GPU submissions and skipped submissions. Neither count measures on-screen frame rate or presentation latency.

## Synchronization contract

Drawable acquisition and encoding run on a dedicated serial queue. A two-token gate is acquired **before** dispatch, released on failure or GPU completion. No OpenGL context, `waitUntilCompleted`, synchronous drain, or UI-thread drawable acquisition is used. Resize/pause/occlusion/close invalidate queued work through generation numbers. Already-committed frames cannot be retracted; resize is not a claim of atomically replacing the visible frame. Closing stops submissions without waiting for the GPU. Paused resize or headroom changes request redraw.

The decoder is serial and pull-based: at most three ready frames, one decode request, one selected frame and two GPU submissions. Pause freezes the clock; seek rebuilds the reader time range and invalidates old callbacks. Hidden/minimized windows freeze the playback clock. Late due frames may be skipped. The 120 Hz prototype timer is not a display-link/VSync scheduler and no frame-rate or latency guarantee is claimed. Already committed GPU frames cannot be retracted on seek.

## Checks and limits

- `bash scripts/check-hdr-math.sh`: shared C/Metal scalar math, known PQ reference points, monotonicity, round trip, clipping; no GPU/window.
- `build/Luma\ HDR\ Prototype.app/Contents/MacOS/LumaHDRPrototype --check-shader`: runtime library and render pipeline compilation only, no window. Exit 77 means GPU unavailable, not a pass.
- Build script ad-hoc signs the independent test app; it does not replace or re-sign the main player.
- Runtime shader compilation avoids requiring Xcode's optional offline Metal toolchain.
- Verified on 2026-11-06: CPU transfer/range/matrix tests, runtime Metal pipeline compilation, synthetic tagged HEVC/PQ decode and actual offscreen RGBA16F conversion; tagged SDR rejection. The tiny testsrc fixture is only for transport/format validation, not a color-fidelity reference.
- `bash scripts/check-hdr-frame.sh` reproduces those no-window checks (requires ffmpeg with libx265/libx264 and GPU access). `--check-frame /path/to/local.mp4` reads one frame and converts it offscreen; it never opens a window.
- Not yet validated: visible presentation, measured brightness, cross-screen behavior, reference-image color fidelity, real-world HDR files, visible continuous-playback cadence, audio sync or enhancement interoperability.

Stage 3 basic checks cover ordered decoding through EOF, forward seek, replay, pause/resume clock arithmetic, and the previous offscreen Metal conversion. Next: validate visible playback/pause/seek with real HDR clips, replace timer polling with display-synchronized scheduling, and design audio-clock synchronization before libmpv integration. Do not remove the existing SDR fallback.

References: [Apple EDR](https://developer.apple.com/documentation/metal/performing-your-own-tone-mapping), [PQ/reference white](https://developer.apple.com/videos/play/wwdc2021/10161/), [ITU PQ EOTF](https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.2124-0-201901-I%21%21PDF-E.pdf).

Opening errors are shown in a native alert and remain in the title instead of being replaced by EOF status. The picker permits unregistered extensions, but that does not add AVFoundation container support; MKV is generally unsupported here. The main Luma Player remains unchanged.

## HLG support (2026-11-06)

Frames tagged `ITU_R_2020 / ITU_R_2100_HLG / ITU_R_2020` now use a separate HLG branch, not the PQ EOTF. The HLG test reference is a 1000-nit virtual display with zero black and system gamma 1.2; inverse OETF is followed by a luminance-dependent OOTF before gamut conversion. Neutral 75% HLG maps to approximately 203 reference nits (now approximately EDR 1.0 with 203-nit HLG diffuse-white normalization). Actual display output is still clipped to current headroom; it is not calibrated luminance or a final adaptive tone mapper. The window title identifies HLG and this assumption.

CPU reference/monotonicity tests, 48-frame synthetic HLG decode/EOF/seek and GPU offscreen conversion pass, alongside PQ/SDR regression checks. Real-user HLG file display and color accuracy remain unverified. Reference equations: https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.2100-2-201807-S%21%21PDF-E.pdf

## HLG brightness correction and system Dolby Vision route

HLG now uses **203 source nits → EDR 1.0**, instead of the previous 100-nit normalization that made 75% HLG white approximately EDR 2.03. PQ/test-pattern normalization is unchanged. This is a chosen diffuse-white policy, not calibrated screen luminance. GPU/CPU regression checks passed; perceived brightness remains user-validated.

Click **System Playback** to open the original file directly in `AVPlayerView`/`AVPlayer`. Detected `dvh1`/`dvhe` or `dvcC`/`dvvC` configurations automatically use this route; manual System Playback also works when detection is incomplete. AVKit owns decode, HDR metadata, tone mapping, audio clock and native controls. No custom enhancement or Metal color conversion runs in this route. **HDR eligible** is a system eligibility indicator, not proof that Dolby Vision is active for the selected file. Unsupported profile/container errors are surfaced. Dolby Vision profiles, real-file playback and on-screen behavior have not been verified here.

**Test Pattern** stops native playback and returns to the custom renderer. The formal Luma Player app remains unchanged. Reference: https://developer.apple.com/documentation/technotes/tn3145-hdr-video-metadata

## Default HLG route after brightness feedback

The user confirmed Dolby Vision playback through AVKit, but custom HLG remained visibly too bright after diffuse-white normalization. Therefore **Open Video now routes decoded HLG to AVKit by default**; it does not claim the custom HLG tone mapping has been corrected. A `HLG source · System AVKit` title confirms the route, not calibrated HDR output. System playback includes audio and bypasses all custom color shaders/enhancement. Actual HLG appearance through AVKit still needs user verification.

`File → Experimental Metal Preview…` deliberately retains the diagnostic HLG branch, with an explicit brightness warning. `System Playback` can directly open the file without first attempting P010 decoding. PQ remains on the experimental Metal path unless system playback is chosen. Existing Dolby Vision routing is unchanged.
