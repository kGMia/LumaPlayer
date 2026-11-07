# WebDAV queue and OneDrive assessment — 2026-10-20

## Implemented

- Opening a file from the WebDAV browser now registers its original filename, size and account separately from its temporary download URL. The queue stores an opaque, session-local ID; credentials and signed URLs are not written into queue filenames or recent history.
- Enable **Add Media from the Same Folder** in Settings → General, the queue menu, or the WebDAV browser. Supported direct media in that directory are added in natural filename order, with the selected file playing first. Subdirectories and hidden entries are excluded. **Scan Current Folder** refreshes the remote directory and adds missing entries.
- Queue rows show original titles immediately. Choose **Display → Cover, Title, Duration & Size** for thumbnails and file sizes. Duration/thumbnail reads use the native FFmpeg probe; mpv is not seeked and video files are not downloaded to disk. Failed or unavailable information remains N/A / a placeholder.
- Each item resolves a fresh download URL inside libmpv's `on_load` hook, including automatic next-item playback. This avoids keeping expired CDN URLs in long queues. The hook is released on cancellation, replacement, shutdown or a 45-second timeout.
- Thumbnail requests are scheduled through one background lane, coalesced per item and canceled when no readers remain. Cache limits: 128 records / 8 MiB compressed images; normal result TTL 5 minutes and missing-duration TTL 30 seconds. Native reads have a 6-second interrupt budget and an approximately 8 MiB read budget, with a 12-second outer deadline. Canceled network I/O may briefly finish unwinding after the lane advances.
- Folder deduplication uses a source-URL set instead of repeatedly scanning the complete registry for each item. Registry entries no longer retain entire directory listings.

## Validation and limits

`bash scripts/check-remote-queue.sh` exercises a one-second generated MP4 over authenticated loopback HTTP. Passed native duration/JPEG thumbnail extraction, cancellation, original title, stable queue identity, selection from the middle of a directory, fresh hooks and automatic advancement to the next file. This checks actual libav/libmpv behavior; it is not a throughput benchmark or GUI test.

The Xcode Debug build passed. Logs: `benchmarks/results/remote-queue-build-20261020.log` and `benchmarks/results/remote-queue-smoke-20261020.log`. The generated development apps retain the project's existing Homebrew/workspace dependencies.

Reopen files through the WebDAV browser after updating: old queue entries containing bare CDN URLs do not contain enough information to recover their directory or original name. Servers remain saved in Keychain; the play queue is session-only. Remote creation-date sorting is not implemented. Some large, poorly indexed, slow or non-range-capable files will exceed the metadata budget. HDR thumbnails are deliberately skipped until a correct thumbnail tone-mapping path is added. Plain URLs entered outside the WebDAV listing do not receive directory metadata. Refresh is currently per playback start, not seamless mid-stream URL renewal.

RIFE / SR still run after decoding through the existing playback filters, subject to their existing format and performance guards. WAN bandwidth and server behavior are additional constraints. No real account, GUI playback or full regression tests were used for this change.

## OneDrive: feasible, not yet integrated

Microsoft Graph v1.0 supplies [directory listing](https://learn.microsoft.com/en-us/graph/api/driveitem-list-children?view=graph-rest-1.0), with delegated `Files.Read` available for personal and work/school accounts. Pagination must follow `@odata.nextLink`.

Graph also supplies [thumbnail sets](https://learn.microsoft.com/en-us/graph/api/driveitem-list-thumbnails?view=graph-rest-1.0). Prefer these to downloading video packets solely for queue covers; not all items have thumbnails.

The [content API](https://learn.microsoft.com/en-us/graph/api/driveitem-get-content?view=graph-rest-1.0) provides a temporary preauthenticated download URL. Fetch it when an item starts; do not store it as the durable identity, and do not forward the Graph bearer token to that URL. Apply HTTP Range to the actual download URL. Expiration and reconnects require explicit handling.

Recommended implementation sequence:

1. Register a public-client Microsoft application, configure account types and redirect URI, then use [MSAL for macOS](https://learn.microsoft.com/en-us/entra/msal/objc/install-and-configure-msal) with [authorization code + PKCE](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow). Keep tokens in Keychain; embed no client secret. Confirm callback and Keychain entitlements against the existing Personal Team build.
2. Introduce a shared remote-provider interface for directory listing, metadata and playback-URL resolution. Adapt the implemented WebDAV queue first, then add Graph using account/drive/item IDs as stable identity.
3. Add a OneDrive account entry under Network settings, paginated SwiftUI browsing, service thumbnails and the current lazy playback hook. Start with read-only ordinary files, then address shared items and account-specific policy constraints.
4. Handle token refresh, HTTP 429 backoff and download-URL expiration. Preserve position when reopening an expired URL; distinguish network recovery from enhancement fallback.

Architectural assessment: downloaded media bytes can use the same libmpv decoding and enhancement pipeline, so OneDrive does not intrinsically prevent RIFE/SR. This is a design conclusion, not an account-level integration or real-time performance result. Next useful optimization for both providers is playback-aware metadata throttling and controlled reconnect/resume.

### 2026-10-27 · Remote Play Next

WebDAV/OneDrive browser menus and footer now offer Play Next for one or multiple selected media, in visible listing order. Existing entries move instead of duplicating; current playback/pause remain intact. Idle queues place the batch first without requesting playback. Links still resolve lazily. The resulting order switches to Custom; a revision guard rejects stale sorting requests that would undo insertion. A no-network libmpv check covers selection order, movement from before the current item, duplicate/current exclusion, repeated requests and idle reordering (`tests/RemotePlayNextSmoke.m`, `benchmarks/results/remote-play-next-20261027.log`). GUI/account behavior remains for user verification.

### 2026-10-27 · 浏览限流恢复
WebDAV 目录与 OneDrive 浏览请求在 HTTP 429/503 后遵守 Retry-After（秒数或 HTTP 日期），最长自动等待 120 秒、每个请求最多重试两次。SwiftUI 倒计时提供 Retry Now / Cancel，关闭窗口或切换操作取消旧等待。后台 metadata/播放链接解析仍仅允许一次 ≤5 秒短重试；不持久化重试状态或请求地址。定向策略/倒计时检查见 `retry-browser-20261027.log` 与 `retry-metadata-policy-20261027.log`；未连接真实账户验证。

### 2026-10-28 · 完整目录加载
OneDrive 增加 Load Remaining Items；逐页发布和缓存，取消/错误保留已完成页，可续读，兼容限流倒计时。搜索和排序始终注明是否只覆盖部分目录。统一分页合并按 ID 去重；5,000 项/100 页上限或循环链接不再伪装为完整目录，缓存也保留限制状态。`onedrive-pages-20261028.log` 定向检查通过；未连接真实网盘或进行 GUI 验证。个人签名构建当前因 Xcode “No Accounts”/缺少描述文件受阻，上一版发布应用保持不变。
不签名编译检查通过（`onedrive-pages-compile-20261028.log`），产物隔离在 `build/UnsignedValidation`，未替换已有签名交付包。
