// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum FolderMedia {
    // Container recognition is not a guarantee that every stream can be decoded.
    static let extensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm", "avi", "mpg", "mpeg", "ts", "mts", "m2ts", "vob", "ogv", "wmv", "flv", "3gp", "mxf", "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus", "wma", "alac"]
    static func files(around selected: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        return try FileManager.default.contentsOfDirectory(at: selected.deletingLastPathComponent(),
            includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants])
            .filter { url in
                guard extensions.contains(url.pathExtension.lowercased()),
                      let values = try? url.resourceValues(forKeys: keys) else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true
            }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

#if !FOLDER_MEDIA_TEST
extension PlayerModel {
    func cancelFolderScan() {
        folderTask?.cancel(); folderTask = nil
        folderScanID += 1
        folderQueueStatus = ""
    }
    func enqueueFolder(around url: URL) {
        folderTask?.cancel()
        folderScanID += 1
        let ticket = folderScanID
        let currentSession = session
        folderQueueStatus = "Scanning folder…"
        folderTask = Task { [weak self] in
            do {
                let files = try await Task.detached(priority: .utility) { try FolderMedia.files(around: url) }.value
                guard !Task.isCancelled, let self, self.autoQueueFolder,
                      self.session === currentSession, self.folderScanID == ticket else { return }
                let count = await currentSession?.appendUniqueFiles(files.map(\.path), around: url.path) ?? -1
                guard !Task.isCancelled, self.folderScanID == ticket, self.session === currentSession else { return }
                self.folderQueueStatus = count >= 0 ? "Added \(count) files from this folder." : "Folder scan skipped because playback changed."
            } catch {
                guard !Task.isCancelled, let self, self.folderScanID == ticket else { return }
                self.folderQueueStatus = "Cannot read this folder: \(error.localizedDescription)"
            }
        }
    }
}

#endif
