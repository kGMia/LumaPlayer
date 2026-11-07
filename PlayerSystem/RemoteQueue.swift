// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum RemoteMediaOrigin: Equatable, Sendable {
    case webDAV(NetworkServerCredentials)
    case oneDrive(OneDriveLocation)

    func resolve(_ item: WebDAVItem) async throws -> NetworkMediaRequest {
        switch self {
        case .webDAV(let credentials):
            return try await NetworkPlaybackResolver.prepare(item.url, username: credentials.username, password: credentials.password, fileName: item.name)
        case .oneDrive(let location): return try await OneDriveClient.resolve(item, location: location)
        }
    }
}

struct RemoteQueueEntry: Sendable {
    let key: String
    let item: WebDAVItem
    let origin: RemoteMediaOrigin
    var playbackIdentity: String? {
        switch origin {
        case .webDAV(let credentials):
            guard let server = try? NetworkMediaRequest.parse(credentials.address, webDAV: true),
                  WebDAVDirectory.sameOrigin(item.url, server) else { return nil }
            return RemotePlaybackIdentity.webDAV(url: item.url, server: server, username: credentials.username)
        case .oneDrive(let location):
            return RemotePlaybackIdentity.oneDrive(account: location.account, drive: location.drive, item: item.url.lastPathComponent)
        }
    }
}

struct RemoteQueueRequest {
    let item: WebDAVItem
    let siblings: [WebDAVItem]
    let origin: RemoteMediaOrigin
    let append: Bool
    let explicitItems: [WebDAVItem]?
    var playNext = false
}

extension PlayerModel {
    func playNextRemoteBatch(_ items: [WebDAVItem], origin: RemoteMediaOrigin) {
        let media = RemoteMediaBatch.media(items)
        guard let first = media.first else { return }
        guard let session else {
            pendingRemote = RemoteQueueRequest(item: first, siblings: [], origin: origin, append: true, explicitItems: media, playNext: true)
            folderQueueStatus = String(localized: "Preparing the player queue…"); return
        }
        cancelFolderScan()
        var keys: [String] = []
        var identities: [String: String] = [:], urls: [URL: String] = [:]
        for entry in remoteEntries.values {
            if let identity = entry.playbackIdentity { identities[identity] = entry.key }
            if entry.origin == origin { urls[entry.item.url] = entry.key }
        }
        // Prefer a live queued key over an older retained resolution entry.
        for row in queue {
            guard let entry = remoteEntries[row.filename] else { continue }
            if let identity = entry.playbackIdentity { identities[identity] = entry.key }
            if entry.origin == origin { urls[entry.item.url] = entry.key }
        }
        if let entry = remoteEntries[path] {
            if let identity = entry.playbackIdentity { identities[identity] = entry.key }
            if entry.origin == origin { urls[entry.item.url] = entry.key }
        }
        for item in media {
            let candidate = RemoteQueueEntry(key: "", item: item, origin: origin)
            // Include pending entries as well as visible rows: repeated clicks
            // before a snapshot arrives must still resolve to the same lazy key.
            let identity = candidate.playbackIdentity
            if let existing = identity.flatMap({ identities[$0] }) ?? urls[item.url] {
                remoteEntries[existing] = RemoteQueueEntry(key: existing, item: item, origin: origin)
                keys.append(existing); continue
            }
            guard remoteEntries.count < 5000 else { break }
            let key = "iive-media://" + UUID().uuidString
            remoteEntries[key] = RemoteQueueEntry(key: key, item: item, origin: origin)
            if let identity { identities[identity] = key }
            urls[item.url] = key
            keys.append(key)
        }
        guard !keys.isEmpty else { folderQueueStatus = String(localized: "The remote queue has reached its 5,000-item limit."); return }
        session.enqueueRemoteNext(keys)
        folderQueueStatus = String(localized: "Requested Play Next for \(keys.count) items · selected order preserved; queued items are moved, current media stays playing.")
    }
    func appendRemoteBatch(_ items: [WebDAVItem], origin: RemoteMediaOrigin) {
        let media = RemoteMediaBatch.media(items)
        guard let first = media.first else { folderQueueStatus = String(localized: "Select supported media files to add."); return }
        openRemote(first, siblings: [], origin: origin, append: true, explicitItems: media)
    }
    func openWebDAV(_ item: WebDAVItem, siblings: [WebDAVItem], credentials: NetworkServerCredentials, append: Bool, explicitItems: [WebDAVItem]? = nil) {
        openRemote(item, siblings: siblings, origin: .webDAV(credentials), append: append, explicitItems: explicitItems)
    }
    func openRemote(_ item: WebDAVItem, siblings: [WebDAVItem], origin: RemoteMediaOrigin, append: Bool, explicitItems: [WebDAVItem]? = nil) {
        clearPendingMediaOpen()
        guard let session else {
            pendingRemote = RemoteQueueRequest(item: item, siblings: siblings, origin: origin, append: append, explicitItems: explicitItems)
            folderQueueStatus = String(localized: "Preparing the player queue…"); return
        }
        cancelFolderScan()
        if !append {
            prepareRemoteReplacement()
            remoteResolution?.cancel(); remoteEntries.removeAll()
            Task { await remoteMetadata.clear() }
        }
        let queued = Set(queue.map(\.filename))
        var queuedSources = Set(remoteEntries.values.filter { queued.contains($0.key) && $0.origin == origin }.map { $0.item.url })
        var ordered: [WebDAVItem]
        if let explicitItems {
            // Explicit multi-selection neither expands the folder nor re-sorts it.
            ordered = RemoteMediaBatch.media(explicitItems)
        } else {
            ordered = autoQueueFolder ? siblings.filter { !$0.directory && !$0.name.hasPrefix(".") && $0.url.deletingLastPathComponent().standardized.path == item.url.deletingLastPathComponent().standardized.path && NetworkMediaRequest.directFormats.keys.contains(($0.name as NSString).pathExtension.lowercased()) } : []
            if !ordered.contains(where: { $0.url == item.url }) { ordered.append(item) }
            ordered.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        let selected = ordered.firstIndex(where: { $0.url == item.url }) ?? 0
        var keys: [String] = []
        for candidate in ordered {
            // Deduplicate by source identity and account, never by expiring CDN URL.
            if queuedSources.contains(candidate.url) { continue }
            guard remoteEntries.count < 5000 else { break }
            queuedSources.insert(candidate.url)
            let key = "iive-media://" + UUID().uuidString
            remoteEntries[key] = RemoteQueueEntry(key: key, item: candidate, origin: origin)
            keys.append(key)
        }
        guard !keys.isEmpty else { folderQueueStatus = remoteEntries.count >= 5000 ? "The remote queue has reached its 5,000-item limit." : "These files are already in the play queue."; return }
        let selectedIndex = keys.firstIndex(where: { remoteEntries[$0]?.item.url == item.url }) ?? min(selected, keys.count-1)
        error = ""
        if explicitItems == nil { applyDecoder() }
        session.loadRemoteQueue(keys, selected: selectedIndex, append: append)
        folderQueueStatus = String(localized: "Added \(keys.count) remote media files. Download links refresh when playback starts.")
        if explicitItems != nil, ordered.count > keys.count { folderQueueStatus += " Skipped \(ordered.count - keys.count) already queued or over-limit items." }
    }
    func resolveRemote(_ key: String, hook: UInt64, session currentSession: MPVSession) {
        savePosition()
        prioritizePlaybackIO()
        remoteResolution?.cancel()
        let memoryGeneration = playbackMemoryGeneration
        guard let entry = remoteEntries[key] else {
            currentSession.finishNetworkHook(hook, url: nil, options: [:], error: "Remote entry is no longer available. Reopen it from its network browser."); return
        }
        remoteResolution = Task { [weak self, weak currentSession] in
            guard let currentSession else { return }
            do {
                let request = try await entry.origin.resolve(entry.item)
                guard !Task.isCancelled, let self, self.session === currentSession else { return }
                var options = self.networkCachePolicy.applying(to: request.options, url: request.url)
                if self.playbackMemoryGeneration == memoryGeneration {
                    self.remotePlaybackContext = nil
                    if let identity = entry.playbackIdentity, let version = request.contentVersion {
                        let revision = version.digest
                        self.remotePlaybackContext = (key, identity, revision)
                        self.networkResumeStatus = "This media supports saved network progress."
                        if self.resumePlayback && self.rememberNetworkProgress,
                           let position = self.remotePlaybackMemory.position(for: identity, revision: revision) {
                            options["start"] = String(position)
                        }
                    } else {
                        self.networkResumeStatus = "Cross-session resume unavailable: this media needs a stable file address, size and server version marker."
                    }
                }
                currentSession.finishNetworkHook(hook, url: request.url.absoluteString,
                    options: options, error: nil)
            } catch {
                guard !Task.isCancelled, self?.session === currentSession else { return }
                currentSession.finishNetworkHook(hook, url: nil, options: [:], error: NetworkMediaError.message(for: error))
            }
        }
    }
    func scanCurrentMediaFolder() {
        if path.hasPrefix("/") { enqueueFolder(around: URL(fileURLWithPath: path)); return }
        guard let entry = remoteEntries[path] else { return }
        cancelFolderScan()
        let ticket = folderScanID
        let currentSession = session
        folderQueueStatus = String(localized: "Scanning remote folder…")
        folderTask = Task { [weak self] in
            do {
                let items: [WebDAVItem]
                switch entry.origin {
                case .webDAV(let credentials):
                    items = try await WebDAVDirectory.read(entry.item.url.deletingLastPathComponent(), username: credentials.username, password: credentials.password)
                case .oneDrive(let location): items = try await OneDriveClient.siblings(location)
                }
                guard !Task.isCancelled, let self, self.folderScanID == ticket,
                      self.session === currentSession, self.path == entry.key else { return }
                self.openRemote(entry.item, siblings: items, origin: entry.origin, append: true)
            } catch {
                guard !Task.isCancelled, let self, self.folderScanID == ticket else { return }
                self.folderQueueStatus = NetworkMediaError.message(for: error)
            }
        }
    }
}

/// FFmpeg state has one reader at a time. cancel() touches only the native atomic
/// cancellation flag, so it must remain callable while a blocking read owns lock.
private final class RemoteProbeRead: @unchecked Sendable {
    private let probe = RemoteMediaProbe()
    private let lock = NSLock()
    func cancel() { probe.cancel() }
    func read(_ request: NetworkMediaRequest, size: Int64?, cover: Bool) -> QueueMetadata {
        lock.withLock {
            let raw = probe.readURL(request.url.absoluteString, options: request.options, cover: cover)
            return QueueMetadata(duration: (raw["duration"] as? NSNumber)?.doubleValue, size: size, cover: raw["cover"] as? Data, subtitleCount: (raw["subtitleCount"] as? NSNumber)?.intValue)
        }
    }
}

extension RemoteQueueMetadataCache {
    func read(_ entry: RemoteQueueEntry, cover: Bool, allowLoad: Bool = true, priorityRevision: UInt64? = nil, priority: MediaReadPriority = .visible) async -> QueueMetadata {
        await read(key: entry.key, size: entry.item.size, cover: cover, allowLoad: allowLoad, priorityRevision: priorityRevision, priority: priority) {
            var seed: QueueMetadata?
            if case .oneDrive(let location) = entry.origin {
                seed = await mediaReadWithDeadline(seconds: 12, cancel: {}) {
                    try? await OneDriveClient.metadata(entry.item, location: location, cover: cover)
                }
                // Don't follow an API/authentication failure with more requests.
                guard let value = seed, !Task.isCancelled else { return nil }
                if value.duration != nil && (!cover || value.cover != nil) { return value }
                // Graph doesn't index duration/thumbnails for every supported
                // container. A bounded direct-media probe can fill those gaps.
            }
            let request: NetworkMediaRequest? = await mediaReadWithDeadline(seconds: 12, cancel: {}) {
                try? await entry.origin.resolve(entry.item)
            }
            guard let request, !Task.isCancelled else { return seed }
            let probe = RemoteProbeRead()
            // The native reader has its own deadline/interrupt callback. Keep the
            // lane until it really exits, even when its last UI subscriber leaves.
            let needsCover = cover && seed?.cover == nil
            let result = await withTaskCancellationHandler {
                await Task.detached(priority: .utility) {
                    probe.read(request, size: entry.item.size, cover: needsCover)
                }.value
            } onCancel: { probe.cancel() }
            return QueueMetadata(duration: seed?.duration ?? result.duration,
                size: seed?.size ?? result.size, cover: seed?.cover ?? result.cover)
        }
    }
}
