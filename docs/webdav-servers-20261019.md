# WebDAV playback fixes and saved servers — 2026-10-19

## User-visible changes

- **Settings → Network** provides a dedicated server list with **Open / Edit** and **Remove**.
- In **Open Network… (⌘N)**, enter the folder URL, username/password and optional name, then choose **Save Server**. Use **Save Changes** after edits. The last selected server is restored on reopening; choose **New** for a separate connection. Saving is explicit, not automatic on every edit.
- Complete addresses (including private query parameters), usernames and passwords go into the macOS login Keychain. Preferences contain only UUID, display name, hostname and selected UUID. Removing a saved server removes its Keychain record. Existing playback queue entries retain their in-memory credentials until discarded.
- Clicking a file now shows **Connecting to media…** while checking authenticated access and resolving redirects. HTTP failures and HTML/JSON login-page responses are shown in the dialog instead of silently dismissing it.
- The main playback surface displays playback errors without requiring the sidebar. Idle filter refresh no longer clears a failed-open error.
- **Play URL** explicitly starts the new entry, including when previous playback ended paused at EOF. Per-entry options do not change the currently playing entry when appending.

## What was found

The earlier authenticated-file implementation deliberately set FFmpeg `max_redirects=0`. That worked with a direct local WebDAV server but rejected download redirects used by some cloud-backed WebDAV services. Directory listing does not prove that file GETs use the same endpoint. The user reported that their cloud service browses successfully and plays in IINA, but shows a blank result here; no specific provider, server response or private credentials were collected. We have fixed the known redirect incompatibility, not claimed to reproduce their actual server.

A focused integration run also reproduced pause inheritance after EOF: a newly loaded stream stayed paused rather than reaching EOF. Setting per-file `pause=no` resolves that case.

The earlier receive-side history update could still persist network URLs despite the explicit open path excluding them. Both branches now restrict recent history to local paths, and existing non-local recent entries are filtered when the model initializes. Saved network connections belong in the Keychain-backed server store.

## Redirect handling

For an authenticated direct file, the resolver performs a streaming GET with `Range: bytes=0-0`; it cancels after reading response headers, including if the server ignores Range. Each hop uses an ephemeral URLSession with no shared cookies or credential store and automatic redirects disabled. At most eight requests are allowed, with loop detection.

- Same-origin redirects retain Basic authentication.
- After leaving the origin, the entire remaining redirect chain and mpv request contain no Basic header, even if the chain returns to the original origin.
- HTTPS-to-HTTP downgrades, URL-embedded credentials, unsupported schemes and excessive redirects are rejected.
- The final direct URL goes to mpv. Forced direct-file demuxing, blocked external references and disabled mpv redirects remain in place. An original file/display-name extension supplies the demuxer when a CDN URL has no extension.
- Signed CDN URLs are currently resolved once per queued entry. If one expires before playback, reopen the file in WebDAV to obtain a fresh URL. Single-use links, cookie/browser login flows and authenticated adaptive-streaming manifests still need a dedicated integration. Credentials are never forwarded to another host as a workaround.

The decoded video continues through the existing SR/RIFE pipeline. HDR/SDR, model and performance restrictions are unchanged; EDR remains disabled.

## Basic verification

- Production URL/DAV parser checks pass.
- A local server reproduced same-origin redirect → another-origin signed URL with no extension. Resolved playback passed through RIFE fast and FSRCNNX, with the existing 256×128/24 → 512×256/48 short check. The different-origin server received no Authorization header; the next ordinary file also received none. Raw mpv redirects remain blocked.
- A temporary, randomly named real Keychain record passed save/read/update/delete and saved-server reload. Preferences contained neither the password nor URL query. The test disallowed authentication UI and did not read any preexisting Keychain accounts.
- Xcode Debug build and development signing checked; no GUI or full benchmark run. The actual cloud WebDAV service and the app's Keychain permission dialog remain for the user to verify.

Repeat checks:

```sh
bash scripts/check-network-media.sh --integration
bash scripts/check-network-servers.sh
bash scripts/build-player-modern.sh
```

Results: `benchmarks/results/network-redirect-smoke-20261019.log`, `network-redirect-20261019.json`, `network-keychain-smoke-20261019.log`, `network-servers-build-20261019.log`.

## User verification and follow-up

Exit the old app, launch `build/PersonalTeam/IIVE Player.app`, save the server, browse and select a video. Reopen Open Network to confirm restore, and check Settings → Network for editing/removal. If playback still fails, report the new error text and whether it fails during “Connecting” or after the dialog closes; do not share passwords or signed URLs. Next work should target the observed provider behavior, then renewable queue URLs and cancelable retry rather than broadening credential forwarding.
