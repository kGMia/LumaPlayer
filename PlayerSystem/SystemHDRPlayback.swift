// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

struct SystemPlaybackReturn {
    let position: Double
    let paused: Bool
    let speed: Double
    let error: String?
    let tracks: [String: TrackHandoffChoice]
}

/// Inline native playback. mpv retains the queue while its transport is paused.
@MainActor final class SystemHDRPlayback: NSObject, ObservableObject {
    @Published private(set) var status = String(localized: "Preparing system playback…")
    private(set) var player: AVPlayer?
    var onEnd: (() -> Void)?
    private var ended = false
    private var wantsPaused = true
    private var seekGeneration = 0
    private var seekTarget: Double?
    private var openedAt = Date()
    private var monitor: Task<Void, Never>?
    private var startupTimeout: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var selectionReady = false
    private var memoryStamp: PlaybackFileStamp?
    private var rememberSelections = false
    private var captureGenerator: AVAssetImageGenerator?
    private var captureToken: UUID?
    private var completion: ((SystemPlaybackReturn, Bool) -> Void)?
    private var scopedURL: URL?
    private var scoped = false
    private var running = false
    private var started = false
    private var initialPosition = 0.0
    private var lastSpeed = 1.0
    private var failure: String?

    func open(url: URL, position: Double, paused: Bool, speed: Double, volume: Double,
              muted: Bool, audioLanguages: String, subtitleLanguages: String, automaticSubtitles: Bool, rememberSelections: Bool, initialTracks: [String: TrackHandoffChoice], completion: @escaping (SystemPlaybackReturn, Bool) -> Void) {
        if running { return }
        running = true; started = false; failure = nil; ended = false; openedAt = Date()
        wantsPaused = paused; seekTarget = nil; seekGeneration += 1
        initialPosition = position.isFinite ? max(0, position) : 0
        lastSpeed = speed.isFinite ? min(8, max(0.1, speed)) : 1
        self.completion = completion
        scopedURL = url; scoped = url.startAccessingSecurityScopedResource()
        let player = AVPlayer(url: url)
        self.player = player
        self.rememberSelections = rememberSelections
        memoryStamp = nil
        for (characteristic, languages) in [(AVMediaCharacteristic.audible, audioLanguages), (.legible, subtitleLanguages)] {
            let preferred = languages.split(separator: ",").map(String.init)
            if !preferred.isEmpty {
                player.setMediaSelectionCriteria(AVPlayerMediaSelectionCriteria(
                    preferredLanguages: preferred, preferredMediaCharacteristics: nil), forMediaCharacteristic: characteristic)
            }
        }
        selectionReady = false; audioGroup = nil; subtitleGroup = nil
        selectionTask = Task { [weak self, weak player] in
            guard let player, let item = player.currentItem else { return }
            do {
                let stamp = await Task.detached(priority: .utility) { PlaybackFileStamp.read(url.path) }.value
                let audio = try await item.asset.loadMediaSelectionGroup(for: .audible)
                let subtitles = try await item.asset.loadMediaSelectionGroup(for: .legible)
                guard let self, !Task.isCancelled, self.player === player else { return }
                self.memoryStamp = stamp
                self.audioGroup = audio; self.subtitleGroup = subtitles
                self.selectionReady = true
                if let audio { item.selectMediaOptionAutomatically(in: audio) }
                if let subtitles {
                    if automaticSubtitles { item.selectMediaOptionAutomatically(in: subtitles) }
                    else if subtitles.allowsEmptySelection { item.select(nil, in: subtitles) }
                }
                // Carry an unambiguous current selection across before applying
                // explicitly remembered native choices.
                for (type, group) in [("aid", audio), ("sid", subtitles)] {
                    guard let choice = initialTracks[type], let group else { continue }
                    let candidates = group.options.enumerated().map { (String($0.offset), Self.choice($0.element)) }
                    if let id = TrackHandoffChoice.match(choice, among: candidates) {
                        if id == "no" { if group.allowsEmptySelection { item.select(nil, in: group) } }
                        else if let index = Int(id) { item.select(group.options[index], in: group) }
                    }
                }
                if rememberSelections, let stamp {
                    let saved = SystemTrackMemory.selections(for: url.path, stamp: stamp)
                    for (type, group) in [("aid", audio), ("sid", subtitles)] {
                        guard let data = saved[type], let group else { continue }
                        if data.isEmpty {
                            if group.allowsEmptySelection { item.select(nil, in: group) }
                        } else if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                                  let option = group.mediaSelectionOption(withPropertyList: plist) {
                            item.select(option, in: group)
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.selectionReady = true
            }
        }
        player.volume = Float(min(1, max(0, volume / 100)))
        player.isMuted = muted
        status = String(localized: "Preparing system playback…")
        startupTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, self.running, !self.started else { return }
            self.failure = String(localized: "System playback timed out; restored mpv.")
            self.close()
        }
        monitor = Task { [weak self, weak player] in
            guard let player else { return }
            while !Task.isCancelled {
                guard let self, self.running else { return }
                if let item = player.currentItem {
                    if item.status == .failed {
                        self.failure = item.error?.localizedDescription ?? String(localized: "System playback failed.")
                        self.status = self.failure!
                        self.close(); return
                    } else if item.status == .readyToPlay && !self.started {
                        let duration = item.duration.seconds
                        let target = duration.isFinite && duration > 0 ? min(self.initialPosition, max(0, duration - 0.001)) : self.initialPosition
                        let finished = await player.seek(to: CMTime(seconds: target, preferredTimescale: 60_000),
                                                         toleranceBefore: .zero, toleranceAfter: .zero)
                        guard !Task.isCancelled, self.running else { return }
                        guard finished else {
                            self.failure = String(localized: "System playback could not restore the playback position.")
                            self.close(); return
                        }
                        self.started = true
                        self.startupTimeout?.cancel(); self.startupTimeout = nil
                        if finished && !self.wantsPaused { player.playImmediately(atRate: Float(self.lastSpeed)) }
                    }
                    if self.started && self.failure == nil {
                        let nextStatus = AVPlayer.eligibleForHDRPlayback
                            ? String(localized: "System AVKit · HDR eligible")
                            : String(localized: "System AVKit · Display-dependent output")
                        if self.status != nextStatus { self.status = nextStatus }
                        if player.rate > 0 { self.lastSpeed = Double(player.rate) }
                    }
                }
                if !self.started && Date().timeIntervalSince(self.openedAt) > 20 {
                    self.failure = String(localized: "System playback timed out; restored mpv.")
                    self.close(); return
                }
                if self.started, !self.ended, !self.wantsPaused, self.seekTarget == nil,
                   let item = player.currentItem, item.duration.seconds.isFinite,
                   item.duration.seconds > 0, player.rate == 0,
                   player.currentTime().seconds >= item.duration.seconds - 0.05 {
                    self.ended = true; self.wantsPaused = true
                    self.onEnd?()
                }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    var isPaused: Bool { wantsPaused }
    var requestedRate: Double { lastSpeed }
    var isSeeking: Bool { seekTarget != nil }
    var isPreparing: Bool { !started }
    var currentPosition: Double {
        let value = player?.currentTime().seconds ?? .nan
        return seekTarget ?? (started && value.isFinite ? value : initialPosition)
    }
    var playbackRate: Double { isPaused ? 0 : Double(player?.rate ?? 0) }
    func setPaused(_ paused: Bool) {
        wantsPaused = paused
        guard started, let player else { return }
        if paused { player.pause() } else { player.playImmediately(atRate: Float(lastSpeed)) }
    }
    func togglePause() { setPaused(!wantsPaused) }
    func setSpeed(_ value: Double) {
        guard value.isFinite else { return }
        lastSpeed = min(8, max(0.1, value))
        if started && !wantsPaused { player?.playImmediately(atRate: Float(lastSpeed)) }
    }
    func step(backward: Bool) {
        setPaused(true)
        player?.currentItem?.step(byCount: backward ? -1 : 1)
    }
    func seek(_ seconds: Double, relative: Bool) {
        guard let player, started, seconds.isFinite else { return }
        let current = currentPosition
        var target = max(0, relative && current.isFinite ? current + seconds : seconds)
        if let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
            target = min(target, duration)
        }
        ended = false; seekGeneration += 1
        let generation = seekGeneration
        seekTarget = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.seekGeneration == generation else { return }
                self.seekTarget = nil
            }
        }
    }
    /// IDs belong only to this AVPlayerItem; never pass them to mpv.
    var selectionTracks: [[String: Any]] {
        guard let item = player?.currentItem else { return [] }
        return [("audio", audioGroup), ("sub", subtitleGroup)].flatMap { type, group -> [[String: Any]] in
            guard let group else { return [] }
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            return group.options.enumerated().map { index, option in
                ["id": -(index + 1000), "type": type, "title": option.displayName,
                 "selected": option === selected, "main-selection": 0]
            }
        }
    }

    func selectTrack(_ type: String, id: String) -> String? {
        guard selectionReady, let item = player?.currentItem else {
            return String(localized: "System media tracks are still loading.")
        }
        guard let group = type == "aid" ? audioGroup : subtitleGroup else {
            return id == "no" ? nil : String(localized: "This track is unavailable in system playback.")
        }
        if id == "auto" { item.selectMediaOptionAutomatically(in: group); return nil }
        if id == "no" {
            guard group.allowsEmptySelection else {
                return String(localized: "This media group requires a selected track.")
            }
            item.select(nil, in: group); remember(nil, type: type); return nil
        }
        guard let numericID = Int(id), numericID <= -1000,
              group.options.indices.contains(-numericID - 1000) else {
            return String(localized: "This track is unavailable in system playback.")
        }
        let option = group.options[-numericID - 1000]
        item.select(option, in: group)
        remember(option, type: type)
        return nil
    }
    private static func choice(_ option: AVMediaSelectionOption) -> TrackHandoffChoice {
        TrackHandoffChoice(language: option.extendedLanguageTag ?? option.locale?.identifier ?? "", title: option.displayName)
    }
    private var handoffTracks: [String: TrackHandoffChoice] {
        guard selectionReady, let item = player?.currentItem else { return [:] }
        var result: [String: TrackHandoffChoice] = [:]
        for (type, group) in [("aid", audioGroup), ("sid", subtitleGroup)] {
            guard let group else { continue }
            result[type] = item.currentMediaSelection.selectedMediaOption(in: group).map(Self.choice) ?? .off
        }
        return result
    }
    private func remember(_ option: AVMediaSelectionOption?, type: String) {
        guard rememberSelections, let stamp = memoryStamp, let url = scopedURL else { return }
        let data: Data
        if let option {
            guard let encoded = try? PropertyListSerialization.data(fromPropertyList: option.propertyList(), format: .binary, options: 0) else { return }
            data = encoded
        } else { data = Data() }
        SystemTrackMemory.save(data, type: type, path: url.path, stamp: stamp)
    }

    /// Export a source frame at the requested playhead, not the parked mpv FBO.
    /// PNG is explicitly SDR and does not contain AVKit's subtitle composition.
    func capture(to url: URL, preservingHDR: Bool = false, maximumPixelSize: Int? = nil) async throws {
        guard captureGenerator == nil else { throw NSError(domain: "LumaCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "A frame capture is already in progress.")]) }
        guard let item = player?.currentItem, started else { throw CancellationError() }
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.dynamicRangePolicy = preservingHDR ? .matchSource : .forceSDR
        if let maximumPixelSize { generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize) }
        let token = UUID()
        captureToken = token; captureGenerator = generator
        let timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.cancelCapture(token)
        }
        defer {
            timeout.cancel()
            if captureToken == token { captureGenerator = nil; captureToken = nil }
        }
        try Task.checkCancellation()
        let position = currentPosition
        let image: CGImage = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: position, preferredTimescale: 60_000))]) { _, image, _, status, error in
                    if status == .succeeded, let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancelCapture(token) }
        }
        guard !Task.isCancelled, player?.currentItem === item else { throw CancellationError() }
        let data = try await Task.detached(priority: .utility) {
            func invalidHDR() -> NSError {
                NSError(domain: "LumaCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "HDR preservation could not be verified for this frame. Use Save Image for SDR PNG.")])
            }
            func headroom(_ image: CGImage) -> Float {
                let metadata = image.contentHeadroom
                return metadata.isFinite && metadata > 0 ? metadata : image.calculatedContentHeadroom
            }
            if preservingHDR, headroom(image) <= 1 { throw invalidHDR() }
            let bytes = NSMutableData()
            let type = preservingHDR ? UTType.heic : UTType.png
            guard let destination = CGImageDestinationCreateWithData(bytes, type.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
            let properties: CFDictionary? = preservingHDR ? [
                kCGImageDestinationEncodeRequest: kCGImageDestinationEncodeToISOHDR,
                kCGImageDestinationLossyCompressionQuality: 0.95
            ] as CFDictionary : nil
            CGImageDestinationAddImage(destination, image, properties)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            let data = bytes as Data
            if preservingHDR {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary),
                      headroom(decoded) > 1 else { throw invalidHDR() }
            }
            return data
        }.value
        guard !Task.isCancelled, player?.currentItem === item else { throw CancellationError() }
        try await Task.detached(priority: .utility) { try data.write(to: url, options: .atomic) }.value
    }
    private func cancelCapture(_ token: UUID) {
        guard captureToken == token else { return }
        captureGenerator?.cancelAllCGImageGeneration()
    }
    func setVolume(_ value: Double) { player?.volume = Float(min(1, max(0, value / 100))) }
    func toggleMute() { if let player { player.isMuted.toggle() } }
    func close(restoring: Bool = true) { finish(restoring: restoring) }
    private func finish(restoring: Bool) {
        guard running else { return }
        running = false
        let time = player?.currentTime().seconds ?? .nan
        let result = SystemPlaybackReturn(position: seekTarget ?? (started && time.isFinite ? time : initialPosition),
                                          paused: wantsPaused,
                                          speed: lastSpeed, error: failure, tracks: handoffTracks)
        let callback = completion; completion = nil
        captureGenerator?.cancelAllCGImageGeneration()
        monitor?.cancel(); monitor = nil
        startupTimeout?.cancel(); startupTimeout = nil
        selectionTask?.cancel(); selectionTask = nil
        audioGroup = nil; subtitleGroup = nil; selectionReady = false
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        onEnd = nil; seekGeneration += 1; seekTarget = nil
        if scoped, let scopedURL { scopedURL.stopAccessingSecurityScopedResource() }
        scoped = false; scopedURL = nil
        callback?(result, restoring)
    }
}

/// AVKit owns HDR color management. Hit testing passes through to the existing
/// player canvas, preserving click, scroll, and fullscreen gestures.
struct SystemHDRSurface: NSViewRepresentable {
    let player: AVPlayer
    final class Surface: AVPlayerView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Surface {
        let view = Surface()
        view.controlsStyle = .none
        view.player = player
        return view
    }
    func updateNSView(_ view: Surface, context: Context) {
        if view.player !== player { view.player = player }
    }
    static func dismantleNSView(_ view: Surface, coordinator: ()) { view.player = nil }
}

extension PlayerModel {
    private func trackChoice(_ track: [String: Any]) -> TrackHandoffChoice {
        TrackHandoffChoice(language: track["lang"] as? String ?? "", title: track["title"] as? String ?? "")
    }
    private var currentMPVTrackChoices: [String: TrackHandoffChoice] {
        let tracks = snapshot["track-list"] as? [[String: Any]] ?? []
        var result: [String: TrackHandoffChoice] = [:]
        for (key, kind) in [("aid", "audio"), ("sid", "sub")] {
            if let track = tracks.first(where: { $0["type"] as? String == kind && $0["selected"] as? Bool == true && ($0["main-selection"] as? Int ?? 0) == 0 }) {
                if track["external"] as? Bool != true { result[key] = trackChoice(track) }
            } else { result[key] = .off }
        }
        return result
    }
    private func restoreMPVTracks(_ selections: [String: TrackHandoffChoice]) {
        let tracks = snapshot["track-list"] as? [[String: Any]] ?? []
        var unmatched = false
        for (key, kind) in [("aid", "audio"), ("sid", "sub")] {
            guard let choice = selections[key] else { continue }
            let candidates: [(String, TrackHandoffChoice)] = tracks.compactMap { track in
                guard track["type"] as? String == kind, track["external"] as? Bool != true,
                      let id = track["id"] as? Int else { return nil }
                return (String(id), trackChoice(track))
            }
            if let id = TrackHandoffChoice.match(choice, among: candidates) {
                session?.command(["set", key, id])
            } else { unmatched = true }
        }
        if unmatched { osd.show("Some tracks could not be matched; mpv selections were kept.", symbol: "info.circle") }
    }
    func openSystemHDRPlayback() {
        if systemHDRActive { return }
        guard loaded, hasMotionVideo, path.hasPrefix("/") else {
            error = String(localized: "System HDR playback currently requires an opened local video.")
            return
        }
        let source = path
        let epoch = (snapshot["media-epoch"] as? NSNumber)?.uint64Value
        let wasPaused = paused
        let handoffPosition = timeline.presentationPosition
        savePosition(); cancelScrubbing(); timeline.cancelSeek()
        markSystemHDRAttempt()
        session?.command(["set", "pause", "yes"])
        systemHDRPlayback.open(url: URL(fileURLWithPath: source), position: handoffPosition,
                               paused: wasPaused, speed: speed, volume: volume, muted: muted,
                               audioLanguages: playbackPreferences.audioLanguages,
                               subtitleLanguages: playbackPreferences.subtitleLanguages,
                               automaticSubtitles: playbackPreferences.automaticSubtitles,
                               rememberSelections: rememberMediaSelections, initialTracks: currentMPVTrackChoices) { [weak self] result, restoring in
            guard let self else { return }
            guard self.loaded, self.path == source,
                  (self.snapshot["media-epoch"] as? NSNumber)?.uint64Value == epoch else {
                self.systemHDRActive = false
                return
            }
            self.saveSystemHDRReturn(result, restoring: restoring)
            self.systemHDRActive = false
            self.apply()
            guard restoring else {
                // mpv was parked paused. Do not let that internal pause leak to
                // the next file when navigating or advancing the queue.
                self.session?.command(["set", "pause", result.paused ? "yes" : "no"])
                return
            }
            self.restoreMPVTracks(result.tracks)
            self.session?.command(["set", "volume", String(self.volume)])
            self.session?.command(["set", "mute", self.muted ? "yes" : "no"])
            self.command(["set", "speed", String(result.speed)])
            self.seek(result.position)
            self.command(["set", "pause", result.paused ? "yes" : "no"])
            if let failure = result.error { self.error = failure }
        }
        systemHDRActive = true
        liveCaptions.stop()
        apply()
        systemHDRPlayback.onEnd = { [weak self] in
            guard let self else { return }
            if self.repeatMode == "file" {
                self.systemHDRPlayback.seek(0, relative: false)
                self.systemHDRPlayback.setPaused(false)
            } else if self.canNext {
                self.nextFile()
                self.session?.command(["set", "pause", "no"])
            } else if self.repeatMode == "queue", let first = self.queue.first {
                self.playQueueItem(first.id)
                self.session?.command(["set", "pause", "no"])
            }
        }
    }
}

/// Shared explanation for controls belonging to the parked mpv backend.
struct SystemPlaybackNotice: View {
    @ObservedObject var model: PlayerModel
    var body: some View {
        if model.systemHDRActive {
            VStack(alignment: .leading, spacing: 6) {
                Label("System HDR playback", systemImage: "play.rectangle")
                    .font(.callout.weight(.semibold))
                Text("AVKit manages color, decoding and audio output. mpv-only controls are unavailable; your settings are preserved.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Screenshots export an SDR source frame at the playhead, without subtitles or HDR metadata.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Return to mpv playback", systemImage: "arrow.uturn.backward") { model.systemHDRPlayback.close() }
            }
        }
    }
}
