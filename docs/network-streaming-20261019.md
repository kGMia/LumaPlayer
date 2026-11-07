# Network playback and WebDAV — 2026-10-19

**Later update:** saved servers, Settings → Network, safe media redirect resolution and visible errors are now implemented. See [WebDAV follow-up](webdav-servers-20261019.md). This page records the original baseline; superseding behavior is described below.

## Use

Open **File → Open Network… (⌘N)**, or use the empty player's **Open Network…** button.

- Paste an HTTP/HTTPS media URL and select **Play URL**. Public HLS and RTSP/RTSPS URLs use mpv's existing demuxers/protocol support; those protocols have not been exercised in this change.
- For WebDAV, enter the **folder URL**, fill in optional Basic username/password, and select **Browse WebDAV**. Click a folder to navigate or a media file to play it. **Up** returns to its parent. `dav://` and `davs://` normalize to HTTP and HTTPS.
- Enable **Add to play queue** to append without replacing current playback. Network and local media can share the queue.
- Use the existing enhancement settings for SR and interpolation. Network buffering appears above the transport bar; Information shows buffered duration and seekability. Seeking depends on the stream/server; non-seekable streams disable timeline interaction.

The executable remains a workspace-dependent development app: `build/PersonalTeam/IIVE Player.app`. Quit the previous instance before opening the updated app. The checked-in Xcode project builds through `bash scripts/build-player-modern.sh`; do not regenerate the project.

## Enhancement compatibility

Network input enters the same libmpv decode → native interpolation → SR → render path as local files. There is no download-to-images intermediate step. All existing limits remain: SDR-only neural processing, supported surface/codec requirements, resolution/fps thresholds, automatic performance protection, and source-frame availability. Native EDR stays suspended. Network stalls cannot be solved by faster model inference.

A short no-window loopback check actually played an HTTP Basic authenticated MP4 (256×128, 24fps, SDR) through RIFE fast and native FSRCNNX. It produced **48 output frames at 512×256**, including **23 RIFE-generated intermediate frames**; neither filter fell back. This is an integration check, not a performance estimate for 1080p, WAN, or GUI playback. Full-resolution and real NAS testing is left to the user.

## Scope and credentials

- The WebDAV browser performs read-only `PROPFIND` at Depth 1, parses successful `DAV:` properties, and keeps only same-origin descendants. Responses are capped at 4 MiB and 5,000 entries. It does not create, rename, upload or delete remote files.
- Basic credentials are held in the sheet and per-file mpv queue options in memory. Choosing Save Server stores the connection in macOS Keychain. Secrets are not stored in UserDefaults, recent files, resume history or the normal diagnostics recording. Passwords are cleared when the sheet closes; queued protected entries retain the authorization needed for replay until removed/the session ends. Network URLs are also excluded from recent/resume persistence.
- URL-embedded usernames/passwords are rejected. Errors shown to the user avoid raw URLs/headers. mpv terminal logging is disabled in the app; normal diagnostic output contains an anonymized media identifier, not the network URL. Deliberately enabling an external IPC/debug client still grants that client access to playback state; it is not a secret vault.
- Authenticated playback currently accepts known direct MP4/MOV/MKV/WebM/AVI/TS and selected audio extensions. It forces the matching demuxer and blocks external file references. Authenticated redirects are now resolved before playback with an origin-bound credential policy; mpv itself still cannot follow further redirects. Authentication is scoped to that queue entry and resets for the next uncredentialed item. This depends on the pinned build's FFmpeg HTTP backend (`HAVE_LIBCURL=0`); re-check the redirect policy before changing network backends.
- Authenticated HLS/DASH manifests, browser login flows, Digest, OAuth and cookies are not implemented. Saved servers/passwords and direct-media redirects are supported by the follow-up. Public playback URLs are supported; arbitrary web pages and DRM extraction are not.
- HTTP support is deliberately enabled for user-entered NAS endpoints through App Transport Security configuration. The sheet warns that HTTP credentials/media are unencrypted; use HTTPS. HTTPS certificate verification remains on, with no self-signed-certificate bypass.
- SMB/NFS are not browsed here; mount them in Finder and open their local mounted paths.
- Network hover thumbnails, remote cover fetching and automatic same-directory queue scans are not implemented. This avoids additional unauthenticated requests and duplicate decoders. Dragging a seekable network timeline still updates the main playback picture through the existing scrub path. Server byte-range/seek support controls responsiveness.
- Read-ahead defaults: 64 MiB forward and 16 MiB backward demux cache. These limits are not the player's total memory usage.

## Basic validation

- Xcode Debug build with existing Personal Team signing.
- `bash scripts/check-network-media.sh`: production URL/options and XML parser checks, including origin filtering, namespace handling, rejected credentials-in-URL, authenticated-manifest rejection and entity-declaration rejection.
- `bash scripts/check-network-media.sh --integration`: temporary loopback HTTP/WebDAV server, actual PROPFIND and Basic auth, incorrect password response, redirect rejection, actual network → RIFE → FSRCNNX output, and absence of Authorization on the following public media request. Generates a one-second synthetic clip; no original media is changed and no GUI is opened.
- Raw logs/results: `benchmarks/results/network-smoke-20261019.log`, `network-stream-20261019.json`, `network-build-20261019.log`. Integration logging uses only fixed dummy credentials (`test` / `test-only`); do not adapt verbose logging to real account secrets.
- Not validated: real NAS implementations, WAN behavior, public HLS/RTSP servers, GUI effects, or full real-time throughput. No complete test suite was run.

## Implementation and next work

`PlayerSystem/NetworkMedia.swift` owns URL validation, per-file playback options and WebDAV listing; `NetworkMediaSheet.swift` owns the SwiftUI entry/browser. `MPVSession.loadNetworkURL` passes a structured `MPV_FORMAT_NODE_MAP` to loadfile, avoiding comma/quote parsing bugs in URLs and headers. File-only features stay local. Network buffering suspends app-side RIFE tier decisions.

The follow-up adds HTTP status errors, a cancelable preflight, server bookmarks and Keychain storage. Next priorities after real-server feedback: renewable signed queue URLs, retry and adaptive cache sizing. Authenticated manifests/redirects require an origin-aware request mechanism before relaxing current restrictions; never turn on unrestricted header forwarding.

Read implementation references: pinned mpv `DOCS/man/input.rst`, `DOCS/man/options.rst`, `demux/demux_lavf.c`, and FFmpeg HTTP protocol help. Public references: [mpv manual](https://mpv.io/manual/stable/) and [RFC 4918 PROPFIND](https://www.rfc-editor.org/rfc/rfc4918.html#section-9.1).
