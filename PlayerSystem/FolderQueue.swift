// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum FolderMedia {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus", "wma", "alac", "m4b", "mka", "oga", "aifc", "caf", "ape", "wv", "dsf", "dff", "ac3", "dts"]
    static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "idx", "sup", "smi", "sami", "ttml", "dfxp", "lrc"]
    // Container recognition is not a guarantee that every stream can be decoded.
    static let extensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm", "avi", "mpg", "mpeg", "ts", "mts", "m2ts", "vob", "ogv", "wmv", "flv", "3gp", "mxf", "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus", "wma", "alac", "m4b", "mka", "oga", "aifc", "caf", "ape", "wv", "dsf", "dff", "ac3", "dts"]

    static func isSubtitle(_ url: URL) -> Bool {
        subtitleExtensions.contains(url.pathExtension.lowercased())
    }

    static func files(in directory: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        try Task.checkCancellation()
        let entries = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var media: [URL] = []
        for url in entries {
            try Task.checkCancellation()
            guard extensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            media.append(url)
        }
        return media.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func files(around selected: URL) throws -> [URL] {
        try files(in: selected.deletingLastPathComponent())
    }

    static func expandDroppedURLs(_ urls: [URL]) -> (media: [URL], subtitles: [URL], expandedFolders: Int) {
        let dirKeys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        var media: [URL] = []
        var subtitles: [URL] = []
        var seenMedia: Set<String> = []
        var seenSubs: Set<String> = []
        var expandedFolders = 0

        for url in urls where url.isFileURL {
            let std = url.standardizedFileURL
            if let values = try? std.resourceValues(forKeys: dirKeys),
               values.isDirectory == true, values.isPackage != true, values.isSymbolicLink != true {
                expandedFolders += 1
                if let children = try? files(in: std) {
                    for child in children {
                        let path = child.standardizedFileURL.path
                        if seenMedia.insert(path).inserted { media.append(child) }
                    }
                }
            } else if isSubtitle(std) {
                if seenSubs.insert(std.path).inserted { subtitles.append(std) }
            } else {
                if seenMedia.insert(std.path).inserted { media.append(std) }
            }
        }
        return (media, subtitles, expandedFolders)
    }

    /// Discovers external subtitle files in the same folder (or a `Subs` / `Subtitles` subfolder)
    /// whose filename matches the video stem, and classifies candidates for primary/secondary bilingual pairing.
    static func matchingSubtitles(for videoURL: URL) -> (primary: URL?, secondary: URL?, all: [URL]) {
        guard videoURL.isFileURL else { return (nil, nil, []) }
        let stdVideo = videoURL.standardizedFileURL
        let stem = stdVideo.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty else { return (nil, nil, []) }
        let lowerStem = stem.lowercased()
        let baseDir = stdVideo.deletingLastPathComponent()
        var searchDirs: [URL] = [baseDir]
        for subDirName in ["Subs", "Subtitles", "subs", "subtitles"] {
            let candidate = baseDir.appendingPathComponent(subDirName, isDirectory: true)
            if (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                searchDirs.append(candidate)
            }
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        var matches: [URL] = []
        var seen: Set<String> = []
        for dir in searchDirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for entry in entries {
                let ext = entry.pathExtension.lowercased()
                guard subtitleExtensions.contains(ext), ext != "idx",
                      let values = try? entry.resourceValues(forKeys: keys),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let subStem = entry.deletingPathExtension().lastPathComponent
                let lowerSubStem = subStem.lowercased()
                let isMatch: Bool
                if lowerSubStem == lowerStem {
                    isMatch = true
                } else if lowerSubStem.hasPrefix(lowerStem) {
                    let remainder = lowerSubStem.dropFirst(lowerStem.count)
                    if let first = remainder.first, [".", "_", "-", " ", "["].contains(first) {
                        isMatch = true
                    } else {
                        isMatch = false
                    }
                } else {
                    isMatch = false
                }
                if isMatch {
                    let path = entry.standardizedFileURL.path
                    if seen.insert(path).inserted { matches.append(entry.standardizedFileURL) }
                }
            }
        }
        matches.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !matches.isEmpty else { return (nil, nil, []) }

        func languageScore(_ url: URL) -> (isPrimaryLang: Bool, isSecondaryLang: Bool, isExact: Bool) {
            let subStem = url.deletingPathExtension().lastPathComponent.lowercased()
            if subStem == lowerStem { return (false, false, true) }
            let suffix = String(subStem.dropFirst(lowerStem.count))
            let primaryTokens = ["zh", "cht", "chs", "tc", "sc", "hant", "hans", "chi", "zho", "tw", "hk", "cn", "繁", "简", "中", "双语", "雙語", "bilingual"]
            let secondaryTokens = ["en", "eng", "english", "ja", "jpn", "jp", "ko", "kor", "kr", "fr", "de", "es"]
            let isPrimary = primaryTokens.contains { suffix.contains($0) }
            let isSecondary = secondaryTokens.contains { suffix.contains($0) }
            return (isPrimary, isSecondary, false)
        }

        let primaryCandidate = matches.first(where: { languageScore($0).isPrimaryLang })
            ?? matches.first(where: { languageScore($0).isExact })
            ?? matches.first
        let secondaryCandidate = matches.first(where: { $0 != primaryCandidate && languageScore($0).isSecondaryLang })
        return (primaryCandidate, secondaryCandidate, matches)
    }
}

#if !FOLDER_MEDIA_TEST
extension PlayerModel {
    func cancelFolderScan() {
        folderTask?.cancel(); folderTask = nil
        folderScanID += 1
        folderQueueStatus = ""
    }
    func openFromBrowser(_ url: URL, siblingURLs: [URL]) {
        guard url.isFileURL else {
            open(url)
            return
        }
        let media = siblingURLs.filter(\.isFileURL)
        guard autoQueueFolder, media.count > 1 else {
            browserQueuePathOrder.removeAll()
            open(url)
            return
        }
        browserQueuePathOrder = media.map { $0.standardizedFileURL.path }
        open(url, scanFolder: false)
        enqueueFiles(media, around: url)
    }
    func enqueueFiles(_ files: [URL], around url: URL) {
        guard url.isFileURL else { return }
        folderTask?.cancel()
        folderScanID += 1
        let ticket = folderScanID
        let currentSession = session
        let paths = files.filter(\.isFileURL).map(\.path)
        guard !paths.isEmpty else { return }
        folderQueueStatus = String(localized: "Scanning folder…")
        folderTask = Task { [weak self] in
            guard !Task.isCancelled, let self, self.autoQueueFolder,
                  self.session === currentSession, self.folderScanID == ticket else { return }
            let count = await currentSession?.appendUniqueFiles(paths, around: url.path) ?? -1
            guard !Task.isCancelled, self.folderScanID == ticket, self.session === currentSession else { return }
            self.folderQueueStatus = count >= 0 ? String(localized: "Added \(count) files from this folder.") : String(localized: "Folder scan skipped because playback changed.")
        }
    }
    func enqueueFolder(around url: URL) {
        guard url.isFileURL else { return }
        folderTask?.cancel()
        folderScanID += 1
        let ticket = folderScanID
        let currentSession = session
        folderQueueStatus = String(localized: "Scanning folder…")
        folderTask = Task { [weak self] in
            do {
                let scan = Task.detached(priority: .utility) { try FolderMedia.files(around: url) }
                let files = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
                guard !Task.isCancelled, let self, self.autoQueueFolder,
                      self.session === currentSession, self.folderScanID == ticket else { return }
                let count = await currentSession?.appendUniqueFiles(files.map(\.path), around: url.path) ?? -1
                guard !Task.isCancelled, self.folderScanID == ticket, self.session === currentSession else { return }
                self.folderQueueStatus = count >= 0 ? "Added \(count) files from this folder." : "Folder scan skipped because playback changed."
            } catch {
                guard !Task.isCancelled, let self, self.folderScanID == ticket else { return }
                self.folderQueueStatus = String(localized: "Cannot read this folder: \(error.localizedDescription)")
            }
        }
    }
}

#endif
