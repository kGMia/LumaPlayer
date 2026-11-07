// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers
import MediaPlayer

struct QueueItem: Identifiable, Equatable {
    let id: Int64
    let title: String
    let filename: String
    let current: Bool
}
struct MediaChapter: Identifiable, Equatable {
    let id: Int
    let title: String
    let time: Double
}

extension PlayerModel {
    var canPrevious: Bool { queueIndex > 0 }
    var canNext: Bool { queueIndex >= 0 && queueIndex + 1 < queue.count }
    var isAtBeginning: Bool {
        guard loaded, mediaSeekable else { return true }
        let pos = timeline.presentationPosition
        if PreviousMediaPolicy.isNearBeginning(position: pos, duration: duration) { return true }
        let now = ProcessInfo.processInfo.systemUptime
        if lastRestartedPath == path, now - lastRestartedToStartAt < 2.5, pos < 2.5 {
            return true
        }
        return false
    }
    func chapterTitle(at seconds: Double) -> String? {
        guard !chapters.isEmpty, seconds.isFinite, seconds >= 0 else { return nil }
        return chapters.last(where: { $0.time <= seconds + 0.05 })?.title
    }
    func previousOrRestart() {
        if loaded, !isAtBeginning {
            lastRestartedToStartAt = ProcessInfo.processInfo.systemUptime
            lastRestartedPath = path
            seek(0)
            osd.show("Beginning of Video", symbol: "backward.end.fill")
        } else if canPrevious {
            lastRestartedToStartAt = 0
            lastRestartedPath = ""
            previousFile()
            osd.show("Previous Video", symbol: "backward.end.fill")
        } else if loaded, mediaSeekable, timeline.presentationPosition > 0.05 {
            seek(0)
            osd.show("Beginning of Video", symbol: "backward.end.fill")
        }
    }
    func previousFile() { guard canPrevious else { return }; lastRestartedToStartAt = 0; lastRestartedPath = ""; cancelFolderScan(); savePosition(); command(["playlist-prev", "weak"]) }
    func nextFile() { guard canNext else { return }; lastRestartedToStartAt = 0; lastRestartedPath = ""; cancelFolderScan(); savePosition(); command(["playlist-next", "weak"]); osd.show("Next Video", symbol: "forward.end.fill") }
    func playQueueItem(_ id: Int64) {
        guard queue.contains(where: { $0.id == id }) else { return }
        systemHDRPlayback.close(restoring: false)
        beginMediaSwitch()
        cancelFolderScan(); savePosition(); session?.playPlaylistID(id)
    }
    func canPlayNextQueueItem(_ id: Int64) -> Bool {
        guard let targetIdx = queue.firstIndex(where: { $0.id == id }) else { return false }
        if queue[targetIdx].current { return false }
        if let currentIdx = queue.firstIndex(where: \.current) {
            return targetIdx != currentIdx + 1
        }
        return targetIdx != 0
    }
    func playNextQueueItem(_ id: Int64) {
        guard canPlayNextQueueItem(id) else { return }
        var order = queue.map(\.id)
        guard let sourceIdx = order.firstIndex(of: id) else { return }
        order.remove(at: sourceIdx)
        let currentID = queue.first(where: \.current)?.id
        let insertIdx: Int
        if let currentID, let curIdx = order.firstIndex(of: currentID) {
            insertIdx = min(order.count, curIdx + 1)
        } else {
            insertIdx = 0
        }
        order.insert(id, at: insertIdx)
        customQueueOrder = order
        if queueSort != "custom" {
            queueSort = "custom"
        } else {
            synchronizeQueueOrder()
        }
    }
    func removeQueueItem(_ id: Int64) {
        cancelFolderScan()
        session?.removePlaylistID(id)
    }
    func deleteQueueFile(_ item: QueueItem) {
        cancelFolderScan()
        guard item.filename.hasPrefix("/") else {
            error = "Only local files can be moved to Trash."
            return
        }
        let fileURL = URL(fileURLWithPath: item.filename).standardizedFileURL
        // Commit queue/history changes only after the filesystem operation succeeds.
        do {
            try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
        } catch {
            self.error = "Failed to move \"\(fileURL.lastPathComponent)\" to Trash: \(error.localizedDescription)"
            return
        }
        removeQueueItem(item.id)
        playbackMemory.remove(item.filename)
        playbackMemory.remove(fileURL.path)
        var updatedRecent = recent
        updatedRecent.removeAll { URL(fileURLWithPath: $0).standardizedFileURL == fileURL }
        if recent != updatedRecent {
            recent = updatedRecent
            UserDefaults.standard.set(recent, forKey: "recent")
        }
        if var saved = UserDefaults.standard.dictionary(forKey: "positions") {
            saved.removeValue(forKey: item.filename)
            saved.removeValue(forKey: fileURL.path)
            UserDefaults.standard.set(saved, forKey: "positions")
        }
    }
    func toggleMute() {
        if systemHDRActive { systemHDRPlayback.toggleMute(); return }
        let nextMuted = !muted
        command(["cycle", "mute"])
        osd.show(nextMuted ? "Muted" : "Unmuted · \(Int(volume.rounded()))%", symbol: nextMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
    }
    func stepFrame(backward: Bool = false) {
        guard loaded, hasMotionVideo else { return }
        // mpv pauses at the destination itself. A separate pause would reset
        // in-flight forward steps when a shortcut repeats before presentation.
        command([backward ? "frame-back-step" : "frame-step"])
        osd.show(backward ? "Previous Frame" : "Next Frame", symbol: backward ? "backward.frame.fill" : "forward.frame.fill")
    }
    func skip(_ direction: Double, long: Bool = false) {
        guard loaded else { return }
        let delta = direction * (long ? longSeekSeconds : seekSeconds)
        seek(delta, relative: true)
        osd.showSkip(delta: delta)
    }
    func changeVolume(_ direction: Double) {
        setVolume(min(100, max(0, volume + direction * volumeStep)), showOSD: true)
    }
    func handleDoubleClick() {
        if miniPlayer { toggleMiniPlayer(); return }
        switch doubleClickAction {
        case "pause": togglePause()
        case "none": break
        default: toggleFullScreen()
        }
    }
    func stop() { cancelFolderScan(); savePosition(); command(["stop"]) }
    func applyRepeat() {
        command(["set", "loop-file", repeatMode == "file" ? "inf" : "no"])
        command(["set", "loop-playlist", repeatMode == "queue" ? "inf" : "no"])
    }
    func clearRecent() {
        recent = []; UserDefaults.standard.removeObject(forKey: "recent")
        UserDefaults.standard.removeObject(forKey: "positions")
        clearPlaybackMemory()
    }
    func showInFinder(path targetPath: String? = nil) {
        let resolved = targetPath ?? path
        guard resolved.hasPrefix("/") else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: resolved)])
    }
    func saveScreenshot() { frameActions.save() }
    func saveScreenshotAs() { frameActions.saveAs() }

    func stepSubtitleDelay(later: Bool, secondary: Bool = false) {
        guard !systemHDRActive else { showSystemPlaybackLimitation(); return }
        guard loaded else { return }
        let key = secondary ? "secondary-sub-delay" : "sub-delay"
        let current = number(key) ?? 0.0
        let next = min(60.0, max(-60.0, ((current + (later ? 0.1 : -0.1)) * 10.0).rounded() / 10.0))
        command(["set", key, String(format: "%.1f", next)])
        telemetry.flush()
        let formatted = String(format: "%+.1f s", next)
        if secondary {
            osd.show("Second Subtitle Delay · \(formatted)", symbol: "captions.bubble")
        } else {
            osd.show("Subtitle Delay · \(formatted)", symbol: "captions.bubble.fill")
        }
    }

    var hasActiveSubtitleText: Bool {
        guard !systemHDRActive else { return false }
        let primaryText = (liveCaptionPlacement == "bottom" ? liveCaptions.text : (snapshot["sub-text"] as? String ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
        let secondaryText = (liveCaptionPlacement == "top" ? liveCaptions.text : (snapshot["secondary-sub-text"] as? String ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
        return !primaryText.isEmpty || !secondaryText.isEmpty
    }

    func copyCurrentSubtitle() {
        guard !systemHDRActive else { showSystemPlaybackLimitation(); return }
        let primaryText = (liveCaptionPlacement == "bottom" ? liveCaptions.text : (snapshot["sub-text"] as? String ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
        let secondaryText = (liveCaptionPlacement == "top" ? liveCaptions.text : (snapshot["secondary-sub-text"] as? String ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = [primaryText, secondaryText].filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            osd.show("No active subtitle to copy", symbol: "doc.on.clipboard")
            return
        }
        let combined = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(combined, forType: .string)
        osd.show("Subtitle Copied", symbol: "doc.on.clipboard.fill")
    }
}


/// Low-frequency macOS Control Center / Now Playing and hardware media key integration.
/// Updates `MPNowPlayingInfoCenter` only on track/state/rate/seek transitions (never on 4 Hz time ticks).
@MainActor final class PlayerNowPlayingController {
    private weak var model: PlayerModel?
    private var registered = false
    private var lastSignature = ""
    private var videoArtworkPath = ""
    private var videoArtworkRevision = 0
    private var videoArtwork: MPMediaItemArtwork?
    private var videoArtworkTask: Task<Void, Never>?

    nonisolated private static func makeArtwork(cgImage: CGImage) -> MPMediaItemArtwork {
        let size = NSSize(width: max(1, cgImage.width), height: max(1, cgImage.height))
        return MPMediaItemArtwork(boundsSize: size) { _ in
            NSImage(cgImage: cgImage, size: size)
        }
    }

    func bind(to model: PlayerModel) {
        self.model = model
        guard !registered else { return }
        registered = true
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let model = self?.model, model.loaded || !model.path.isEmpty else { return .noActionableNowPlayingItem }
                if model.systemHDRActive { model.systemHDRPlayback.setPaused(false) }
                else if model.paused { model.togglePause() }
                return .success
            }
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let model = self?.model, model.loaded || !model.path.isEmpty else { return .noActionableNowPlayingItem }
                if model.systemHDRActive { model.systemHDRPlayback.setPaused(true) }
                else if !model.paused { model.togglePause() }
                return .success
            }
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let model = self?.model, model.loaded || !model.path.isEmpty else { return .noActionableNowPlayingItem }
                model.togglePause()
                return .success
            }
        }

        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let model = self?.model, model.canNext else { return .commandFailed }
                model.nextFile()
                return .success
            }
        }

        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let model = self?.model, model.canPrevious || model.loaded else { return .commandFailed }
                model.previousOrRestart()
                return .success
            }
        }

        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: model.seekSeconds)]
        center.skipForwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let model = self?.model, model.loaded else { return .noActionableNowPlayingItem }
                model.skip(1)
                return .success
            }
        }

        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: model.seekSeconds)]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let model = self?.model, model.loaded else { return .noActionableNowPlayingItem }
                model.skip(-1)
                return .success
            }
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let targetTime = posEvent.positionTime
            return MainActor.assumeIsolated {
                guard let model = self?.model, model.loaded else { return .noActionableNowPlayingItem }
                model.seek(targetTime)
                return .success
            }
        }
    }

    private func ensureVideoArtwork(for model: PlayerModel) {
        guard model.loaded, !model.audioOnly, model.hasMotionVideo, model.path.hasPrefix("/") else {
            if !videoArtworkPath.isEmpty {
                videoArtworkTask?.cancel()
                videoArtworkTask = nil
                videoArtworkPath = ""
                videoArtwork = nil
            }
            return
        }
        let targetPath = model.path
        guard videoArtworkPath != targetPath else { return }
        videoArtworkTask?.cancel()
        videoArtworkPath = targetPath
        videoArtwork = nil
        let sampleTime = model.duration > 4 ? min(12.0, max(1.0, model.duration * 0.08)) : 0.5
        let previews = model.timelinePreviews
        videoArtworkTask = Task { @MainActor [weak self, weak model] in
            guard let thumb = await previews.thumbnail(for: targetPath, at: sampleTime, allowSDRFallback: true, interactive: false),
                  !Task.isCancelled,
                  let self, let model, self.videoArtworkPath == targetPath else { return }
            self.videoArtwork = Self.makeArtwork(cgImage: thumb.image)
            self.videoArtworkRevision &+= 1
            self.sync(from: model)
        }
    }

    func sync(from model: PlayerModel, forcePosition: Double? = nil) {
        let infoCenter = MPNowPlayingInfoCenter.default()
        guard model.loaded, !model.path.isEmpty else {
            if !lastSignature.isEmpty {
                clear()
            }
            return
        }
        let effectivePaused = model.systemHDRActive ? model.systemHDRPlayback.isPaused : model.paused
        let effectiveRate = model.systemHDRActive ? model.systemHDRPlayback.playbackRate : (model.paused ? 0 : model.speed)
        let effectivePosition = model.systemHDRActive ? model.systemHDRPlayback.currentPosition : (forcePosition ?? model.position)
        ensureVideoArtwork(for: model)
        let durBucket = Int(model.duration.rounded())
        let sig = "\(model.path)|\(model.title)|\(model.audioOnly)|\(model.audioArtist)|\(model.audioAlbum)|\(model.audioArtwork.revision)|\(videoArtworkRevision)|\(effectivePaused)|\(effectiveRate)|\(model.systemHDRActive ? Int(effectivePosition) : 0)|\(durBucket)|\(model.canNext)|\(model.canPrevious)|\(Int(model.seekSeconds))"
        guard forcePosition != nil || sig != lastSignature else { return }
        lastSignature = sig

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.nextTrackCommand.isEnabled = model.canNext
        commandCenter.previousTrackCommand.isEnabled = model.canPrevious || model.loaded
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: model.seekSeconds)]
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: model.seekSeconds)]

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: model.title,
            MPNowPlayingInfoPropertyMediaType: (model.audioOnly ? MPNowPlayingInfoMediaType.audio : .video).rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, effectivePosition),
            MPNowPlayingInfoPropertyPlaybackRate: effectiveRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if model.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = model.duration
        }
        if model.audioOnly {
            if !model.audioArtist.isEmpty { info[MPMediaItemPropertyArtist] = model.audioArtist }
            if !model.audioAlbum.isEmpty { info[MPMediaItemPropertyAlbumTitle] = model.audioAlbum }
            if let image = model.audioArtwork.image,
               let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                info[MPMediaItemPropertyArtwork] = Self.makeArtwork(cgImage: cgImage)
            }
        } else if let artwork = videoArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = effectivePaused ? .paused : .playing
    }

    func clear() {
        lastSignature = ""
        videoArtworkTask?.cancel()
        videoArtworkTask = nil
        videoArtworkPath = ""
        videoArtwork = nil
        let infoCenter = MPNowPlayingInfoCenter.default()
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
    }
}
