// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation
import Darwin

/// Directory-entry notifications only; no polling, media decoding or network I/O.
@MainActor @Observable final class BrowserDirectoryWatcher {
    private(set) var revision = 0
    @ObservationIgnored private var sources: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var paths: [URL] = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var debounce: Task<Void, Never>?
    private static let queue = DispatchQueue(label: "com.august.lumaplayer.folder-events", qos: .utility)

    func watch(_ directories: [URL]) {
        var seen = Set<URL>()
        let root = directories.first?.resolvingSymlinksInPath().standardizedFileURL.path ?? ""
        let wanted = Array(directories.map(\.standardizedFileURL).filter {
            let path = $0.resolvingSymlinksInPath().path
            return $0.isFileURL && (path == root || path.hasPrefix(root == "/" ? "/" : root + "/")) && seen.insert($0).inserted
        }.prefix(64))
        guard wanted != paths else { return }
        stop()
        paths = wanted
        let token = generation
        for url in wanted {
            let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .revoke], queue: Self.queue)
            source.setEventHandler { @Sendable [weak self] in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.schedule()
                }
            }
            source.setCancelHandler { @Sendable in close(descriptor) }
            sources.append(source)
            source.resume()
        }
    }
    private func schedule() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self else { return }
            self.revision &+= 1
        }
    }
    func stop() {
        generation = UUID()
        debounce?.cancel(); debounce = nil
        sources.forEach { $0.cancel() }
        sources.removeAll()
        paths.removeAll()
    }
    isolated deinit { stop() }
}
