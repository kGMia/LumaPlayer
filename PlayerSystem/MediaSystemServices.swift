// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Observation
import CoreSpotlight
import UniformTypeIdentifiers
import IOKit.pwr_mgt
import CoreAudio

/// Prevents macOS display dimming / screensaver during active video playback and
/// prevents system idle sleep during active audio-only playback via IOKit power assertions.
@MainActor final class PlayerSleepAssertionManager {
    static let shared = PlayerSleepAssertionManager()
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var activeType: String = ""

    func update(loaded: Bool, paused: Bool, hasMotionVideo: Bool, audioOnly: Bool, title: String) {
        let desiredType: String
        if loaded && !paused {
            if hasMotionVideo && !audioOnly {
                desiredType = kIOPMAssertionTypePreventUserIdleDisplaySleep as String
            } else {
                desiredType = kIOPMAssertionTypePreventUserIdleSystemSleep as String
            }
        } else {
            desiredType = ""
        }

        guard desiredType != activeType else { return }
        releaseAssertion()
        guard !desiredType.isEmpty else { return }

        let reason = (title.isEmpty ? "Luma Player Playback" : "Playing \(title)") as CFString
        var newID = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithName(
            desiredType as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &newID
        )
        if status == kIOReturnSuccess {
            assertionID = newID
            activeType = desiredType
        }
    }

    func releaseAssertion() {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        activeType = ""
    }
}

/// Monitors macOS CoreAudio default output hardware changes (e.g. headphone / AirPods / DAC disconnect)
/// and automatically pauses active playback so audio does not unexpectedly play from built-in speakers.
@MainActor final class PlayerAudioRouteMonitor {
    static let shared = PlayerAudioRouteMonitor()
    private var listening = false
    private var currentDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    nonisolated private static func readDefaultOutputDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : kAudioObjectUnknown
    }

    func start(onRouteChanged: @escaping @MainActor () -> Void) {
        guard !listening else { return }
        currentDeviceID = Self.readDefaultOutputDevice()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            let nextID = Self.readDefaultOutputDevice()
            Task { @MainActor [weak self] in
                guard let self, self.listening else { return }
                let previousID = self.currentDeviceID
                // CoreAudio may report unknown between device removal and fallback.
                // Retain the last real device so the fallback still pauses playback.
                guard nextID != kAudioObjectUnknown else { return }
                self.currentDeviceID = nextID
                if previousID != kAudioObjectUnknown, nextID != kAudioObjectUnknown, previousID != nextID {
                    onRouteChanged()
                }
            }
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        ) == noErr {
            listenerBlock = block
            listening = true
        }
    }

    func stop() {
        guard listening, let block = listenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        listenerBlock = nil
        listening = false
    }
}

/// Publishes the active playback session via NSUserActivity for macOS Handoff, Siri context, and system Recents.
@MainActor final class PlayerUserActivityController {
    static let shared = PlayerUserActivityController()
    nonisolated static let playbackActivityType = "com.august.lumaplayer.playback"
    private var activity: NSUserActivity?
    private var activePath = ""

    func update(path: String, title: String, loaded: Bool) {
        guard loaded, !path.isEmpty else {
            clear()
            return
        }
        if activePath == path, let existing = activity {
            if existing.title != title { existing.title = title }
            return
        }
        activePath = path
        activity?.invalidate()
        let next = NSUserActivity(activityType: Self.playbackActivityType)
        next.title = title.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : title
        next.isEligibleForSearch = false
        if let components = URLComponents(string: path),
           ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
           components.user == nil, components.password == nil,
           components.query == nil, components.fragment == nil,
           let webURL = components.url {
            next.isEligibleForHandoff = true
            next.webpageURL = webURL
        } else if path.hasPrefix("/") {
            next.isEligibleForHandoff = false
            let url = URL(fileURLWithPath: path)
            let attrs = CSSearchableItemAttributeSet(contentType: UTType(filenameExtension: url.pathExtension) ?? .movie)
            attrs.title = next.title
            attrs.contentURL = url
            next.contentAttributeSet = attrs
        }
        next.becomeCurrent()
        activity = next
    }

    func clear() {
        activePath = ""
        activity?.invalidate()
        activity = nil
    }
}

@MainActor @Observable final class PlayerEnergyPolicy {
    static let shared = PlayerEnergyPolicy()
    private(set) var constrained = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    func start() {
        guard observers.isEmpty else { return }
        for name in [ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.update() }
            })
        }
        update()
    }
    private func update() {
        let info = ProcessInfo.processInfo
        constrained = info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
        let value = constrained
        Task { await QueueReadSlots.shared.setConstrained(value) }
    }
    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }
}

/// Only the explicitly bookmarked default folder is eligible for system search.
@MainActor @Observable final class PlayerSpotlightLibrary {
    static let shared = PlayerSpotlightLibrary()
    nonisolated static let domain = "com.august.lumaplayer.library"
    private(set) var busy = false
    private(set) var count = 0
    private(set) var error = ""
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    var enabled: Bool { UserDefaults.standard.bool(forKey: "library.spotlightEnabled") }
    func start() {
        guard observers.isEmpty else { return }
        for name in [Notification.Name.mediaNFODidChange, .defaultBrowserFolderDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    if self.enabled || name == .defaultBrowserFolderDidChange { self.refresh() }
                }
            })
        }
        refresh()
    }
    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "library.spotlightEnabled")
        refresh()
    }
    func refresh() {
        let previous = task
        previous?.cancel()
        let id = UUID()
        generation = id
        let bookmark = enabled ? UserDefaults.standard.data(forKey: "browser.defaultFolderBookmark") : nil
        let wantsIndex = enabled
        busy = true; error = ""
        task = Task.detached(priority: .utility) {
            // Serialize destructive clears with any already submitted indexing batch.
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try await Task.sleep(for: .milliseconds(350))
                let index = CSSearchableIndex(name: "LumaLibrary")
                try await index.deleteSearchableItems(withDomainIdentifiers: [Self.domain])
                try Task.checkCancellation()
                var total = 0
                if wantsIndex {
                    guard let bookmark else { throw CocoaError(.fileReadNoPermission) }
                    total = try await Self.rebuild(bookmark: bookmark, index: index)
                }
                await self.complete(id, count: total, error: "")
            } catch is CancellationError {
                // A successor owns the next clear/rebuild and status.
            } catch {
                // Don't leave a partially indexed or newly inaccessible library exposed.
                try? await CSSearchableIndex(name: "LumaLibrary").deleteSearchableItems(withDomainIdentifiers: [Self.domain])
                await self.complete(id, count: 0, error: error.localizedDescription)
            }
        }
    }
    private func complete(_ id: UUID, count: Int, error: String) {
        guard id == generation else { return }
        busy = false; self.count = count; self.error = error
    }
    nonisolated static func contains(_ url: URL, in root: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return url.isFileURL && path.hasPrefix(base == "/" ? "/" : base + "/") && path != base
    }
    nonisolated private static func rebuild(bookmark: Data, index: CSSearchableIndex) async throws -> Int {
        var stale = false
        let root = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                           relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw CocoaError(.fileReadNoPermission) }
        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.isReadableFile(atPath: root.path) else { throw CocoaError(.fileReadNoPermission) }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { throw CocoaError(.fileReadUnknown) }
        var total = 0
        var movieSidecars: [URL: Bool] = [:]
        var ended = false
        while !ended && total < 10000 {
            guard await QueueReadSlots.shared.acquire(priority: .background) else { throw CancellationError() }
            do {
                defer { await withTaskCancellationShield { await QueueReadSlots.shared.release() } }
                try Task.checkCancellation()
                var batch: [CSSearchableItem] = []
                // Bound directory work as well as media count, yielding to visible reads.
                for _ in 0..<128 {
                    try Task.checkCancellation()
                    guard let url = iterator.nextObject() as? URL else { ended = true; break }
                    let values = try url.resourceValues(forKeys: keys)
                    guard values.isSymbolicLink != true else { iterator.skipDescendants(); continue }
                    guard values.isRegularFile == true, FolderMedia.extensions.contains(url.pathExtension.lowercased()),
                          contains(url, in: root), total + batch.count < 10000 else { continue }
                    let attributes = CSSearchableItemAttributeSet(contentType: UTType(filenameExtension: url.pathExtension) ?? .movie)
                    let nfoURL = url.deletingPathExtension().appendingPathExtension("nfo")
                    var metadata = contains(nfoURL, in: root) ? MediaNFOCache.indexedLocalMetadata(nfoURL) : nil
                    if metadata == nil {
                        let folder = url.deletingLastPathComponent()
                        let movie = folder.appendingPathComponent("movie.nfo")
                        if contains(movie, in: root), FileManager.default.fileExists(atPath: movie.path) {
                            if movieSidecars[folder] == nil {
                                let children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                                movieSidecars[folder] = children.filter { FolderMedia.extensions.contains($0.pathExtension.lowercased()) }.count <= 2
                            }
                            if movieSidecars[folder] == true { metadata = MediaNFOCache.indexedLocalMetadata(movie) }
                        }
                    }
                    let title = metadata?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    attributes.title = title.isEmpty ? url.deletingPathExtension().lastPathComponent : title
                    attributes.displayName = attributes.title
                    attributes.contentURL = url
                    attributes.contentModificationDate = values.contentModificationDate
                    attributes.contentDescription = metadata?.plot
                    attributes.keywords = (metadata?.actors ?? []) + (metadata?.directors ?? []) + (metadata?.tags ?? []) + (metadata?.genres ?? [])
                    let item = CSSearchableItem(uniqueIdentifier: url.absoluteString, domainIdentifier: domain, attributeSet: attributes)
                    item.expirationDate = Date().addingTimeInterval(30 * 86400)
                    batch.append(item)
                }
                if !batch.isEmpty { try await index.indexSearchableItems(batch); total += batch.count }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return total
    }

    func open(_ activity: NSUserActivity, model: PlayerModel) {
        guard enabled, let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let url = URL(string: identifier), url.isFileURL else { return }
        do {
            guard let root = try model.fileDialogs.restoreDefaultBrowserFolder(),
                  Self.contains(url, in: root), FolderMedia.extensions.contains(url.pathExtension.lowercased()),
                  FileManager.default.isReadableFile(atPath: url.path) else { throw CocoaError(.fileReadNoSuchFile) }
            if model.miniPlayer { model.toggleMiniPlayer() }
            model.open(url)
        } catch {
            self.error = error.localizedDescription
            model.osd.show("Media is unavailable. Check the default folder in Settings.", symbol: "exclamationmark.triangle")
            Task { try? await CSSearchableIndex(name: "LumaLibrary").deleteSearchableItems(withIdentifiers: [identifier]) }
        }
    }
    func stop() {
        task?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }
}
