// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import VisionKit
import UniformTypeIdentifiers
import CryptoKit

struct PlaybackMarker: Codable, Identifiable, Equatable {
    var id = UUID()
    let time: Double
    let title: String
}
@MainActor final class FrameActions: NSObject {
    private weak var model: PlayerModel?
    let textSession = LiveTextSession()
    private var textCaptureTask: Task<Void, Never>?
    init(model: PlayerModel) { self.model = model }
    func close() { textSession.close() }
    var folder: URL {
        if let path = model?.screenshotFolder, !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Luma Screenshots", isDirectory: true)
    }
    private var markerKey: String? {
        guard let path = model?.path, !path.isEmpty else { return nil }
        return "markers." + SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func loadMarkers() {
        guard let key = markerKey, let data = UserDefaults.standard.data(forKey: key),
              let markers = try? JSONDecoder().decode([PlaybackMarker].self, from: data) else {
            model?.markers = []; return
        }
        model?.markers = markers.filter { $0.time.isFinite && $0.time >= 0 }.sorted { $0.time < $1.time }
    }
    private func persistMarkers() {
        guard let key = markerKey, let markers = model?.markers,
              let data = try? JSONEncoder().encode(markers) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
    @objc func addMarker() {
        guard let model, model.loaded, model.position.isFinite, model.position >= 0 else { return }
        guard model.markers.count < 500 else { model.osd.show("Marker limit reached", symbol: "bookmark"); return }
        guard !model.markers.contains(where: { abs($0.time - model.position) < 0.5 }) else {
            model.osd.show("A marker already exists here", symbol: "bookmark"); return
        }
        model.markers.append(PlaybackMarker(time: model.position, title: model.chapterTitle(at: model.position) ?? "Marker"))
        model.markers.sort { $0.time < $1.time }; persistMarkers()
        model.osd.show("Marker Added · \(Self.timestamp(model.position))", symbol: "bookmark.fill")
    }
    @objc private func jump(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID, let marker = model?.markers.first(where: { $0.id == id }) else { return }
        model?.seek(marker.time)
    }
    @objc private func remove(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID else { return }
        model?.markers.removeAll { $0.id == id }; persistMarkers()
    }
    @objc private func togglePlayPause() { model?.togglePause() }
    @objc private func previousItem() { model?.previousOrRestart() }
    @objc private func nextItem() { model?.nextFile() }
    @objc private func stepBackward() { model?.stepFrame(backward: true) }
    @objc private func stepForward() { model?.stepFrame(backward: false) }
    @objc private func selectAudioTrack(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        model?.selectTrack("aid", id)
    }
    @objc private func selectPrimarySubtitle(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        model?.selectSubtitle(id, secondary: false)
    }
    @objc private func selectSecondarySubtitle(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        model?.selectSubtitle(id, secondary: true)
    }
    @objc private func loadPrimarySubtitles() { model?.openPanel(subtitle: true, secondary: false) }
    @objc private func loadSecondarySubtitles() { model?.openPanel(subtitle: true, secondary: true) }
    @objc private func selectSecondaryPosition(_ item: NSMenuItem) {
        guard let pos = item.representedObject as? String else { return }
        model?.secondarySubtitlePosition = pos
    }
    @objc private func selectBilingualSpacing(_ item: NSMenuItem) {
        guard let spacing = item.representedObject as? String else { return }
        model?.bilingualSubtitleSpacing = spacing
    }
    @objc private func selectSubtitleFont(_ item: NSMenuItem) {
        guard let font = item.representedObject as? String else { return }
        model?.subtitleFont = font
    }
    @objc private func selectSubtitleSize(_ item: NSMenuItem) {
        guard let size = item.representedObject as? NSNumber else { return }
        model?.subtitleFontSize = size.doubleValue
    }
    @objc private func selectSubtitleColor(_ item: NSMenuItem) {
        guard let color = item.representedObject as? String else { return }
        model?.subtitleColor = color
    }
    @objc private func selectSecondarySubtitleSize(_ item: NSMenuItem) {
        guard let size = item.representedObject as? NSNumber else { return }
        model?.secondarySubtitleFontSize = size.doubleValue
    }
    @objc private func selectSecondarySubtitleColor(_ item: NSMenuItem) {
        guard let color = item.representedObject as? String else { return }
        model?.secondarySubtitleColor = color
    }
    @objc private func selectSubtitleBorderStyle(_ item: NSMenuItem) {
        guard let style = item.representedObject as? String else { return }
        model?.subtitleBorderStyle = style
    }
    @objc private func selectSubtitleOutlineSize(_ item: NSMenuItem) {
        guard let size = item.representedObject as? String else { return }
        model?.subtitleOutlineSize = size
    }
    @objc private func copyCurrentSubtitleAction() { model?.copyCurrentSubtitle() }
    @objc private func selectSpeed(_ item: NSMenuItem) {
        guard let value = item.representedObject as? NSNumber else { return }
        model?.setSpeed(value.doubleValue)
    }
    @objc private func selectLoopPoint(_ item: NSMenuItem) {
        guard let point = item.representedObject as? String else { return }
        model?.setLoopPoint(point)
    }
    @objc private func selectRepeatMode(_ item: NSMenuItem) {
        guard let mode = item.representedObject as? String else { return }
        model?.repeatMode = mode
    }
    @objc private func selectAspectRatio(_ item: NSMenuItem) {
        guard let ratio = item.representedObject as? String else { return }
        model?.setGeometry("video-aspect-override", ratio)
    }
    @objc private func selectRotation(_ item: NSMenuItem) {
        guard let deg = item.representedObject as? NSNumber else { return }
        model?.rotation = deg.intValue
    }
    @objc private func toggleFullScreenAction() { model?.toggleFullScreen() }
    @objc private func toggleMiniPlayerAction() { model?.toggleMiniPlayer() }
    @objc private func toggleFloatOnTopAction() { model?.toggleFloatOnTop() }
    @objc private func subtitleSettingsAction() {
        model?.sidebarTab = "enhance"; model?.inspector = true
    }
    @objc private func revealInFinderAction() { model?.showInFinder() }

    func menu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let isLoaded = model?.loaded == true
        let hasVideo = model?.hasMotionVideo == true
        func item(_ title: String, _ icon: String?, _ action: Selector?, enabled: Bool = isLoaded, checked: Bool = false, object: Any? = nil) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            if let icon { entry.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) }
            entry.isEnabled = enabled
            entry.state = checked ? .on : .off
            entry.representedObject = object
            return entry
        }

        func submenu(_ title: String, _ icon: String) -> NSMenu {
            let entry = item(title, icon, nil, enabled: true)
            let child = NSMenu(); child.autoenablesItems = false
            entry.submenu = child; menu.addItem(entry)
            return child
        }
        // 1. Core Playback Controls
        menu.addItem(item(model?.paused == false ? String(localized: "Pause") : String(localized: "Play"),
                          model?.paused == false ? "pause.fill" : "play.fill",
                          #selector(togglePlayPause),
                          enabled: isLoaded || model?.path.isEmpty == false))
        let playbackMenu = submenu(String(localized: "Playback"), "play.circle")
        playbackMenu.addItem(item(String(localized: "Previous Item"), "backward.end", #selector(previousItem),
                          enabled: isLoaded || model?.canPrevious == true))
        playbackMenu.addItem(item(String(localized: "Next Item"), "forward.end", #selector(nextItem),
                          enabled: model?.canNext == true))
        playbackMenu.addItem(item(String(localized: "Step Back One Frame"), "backward.frame", #selector(stepBackward), enabled: hasVideo))
        playbackMenu.addItem(item(String(localized: "Step Forward One Frame"), "forward.frame", #selector(stepForward), enabled: hasVideo))

        playbackMenu.addItem(.separator())

        // 2. Audio & Subtitles Submenus
        let audioItem = item(String(localized: "Audio"), "waveform", nil, enabled: isLoaded)
        let audioSub = NSMenu(); audioSub.autoenablesItems = false
        audioSub.addItem(item(String(localized: "None"), "speaker.slash", #selector(selectAudioTrack(_:)),
                              enabled: isLoaded, checked: model?.audioID == "no", object: "no"))
        if let tracks = model?.audioTracks {
            for track in tracks {
                let idStr = String(track.id)
                audioSub.addItem(item(track.title, nil, #selector(selectAudioTrack(_:)),
                                      enabled: isLoaded, checked: model?.audioID == idStr, object: idStr))
            }
        }
        audioItem.submenu = audioSub
        menu.addItem(audioItem)

        let subItem = item(String(localized: "Subtitles"), "captions.bubble", nil, enabled: true)
        let subMenu = NSMenu(); subMenu.autoenablesItems = false
        let primaryActive = model?.systemHDRActive != true && model?.liveCaptionPlacement == "bottom" ? "live" : (model?.subtitleID ?? "no")
        subMenu.addItem(item(String(localized: "Off"), "captions.bubble", #selector(selectPrimarySubtitle(_:)),
                             enabled: isLoaded, checked: primaryActive == "no", object: "no"))
        subMenu.addItem(item(String(localized: "Live Captions · Apple Speech"), "waveform", #selector(selectPrimarySubtitle(_:)),
                             enabled: isLoaded, checked: primaryActive == "live", object: "live"))
        if let subs = model?.subtitles, !subs.isEmpty {
            subMenu.addItem(.separator())
            for sub in subs {
                let idStr = String(sub.id)
                subMenu.addItem(item(sub.title, nil, #selector(selectPrimarySubtitle(_:)),
                                     enabled: isLoaded, checked: primaryActive == idStr, object: idStr))
            }
        }
        subMenu.addItem(.separator())
        let secTitle = model?.secondarySubtitlePosition == "below" ? String(localized: "Second Subtitles · Below") : String(localized: "Second Subtitles · Top")
        let secItem = item(secTitle, "captions.bubble.fill", nil, enabled: true)
        let secMenu = NSMenu(); secMenu.autoenablesItems = false
        let secondaryActive = model?.systemHDRActive != true && model?.liveCaptionPlacement == "top" ? "live" : (model?.secondarySubtitleID ?? "no")
        secMenu.addItem(item(String(localized: "Off"), nil, #selector(selectSecondarySubtitle(_:)),
                             enabled: isLoaded, checked: secondaryActive == "no", object: "no"))
        secMenu.addItem(item(String(localized: "Live Captions · Apple Speech"), "waveform", #selector(selectSecondarySubtitle(_:)),
                             enabled: isLoaded, checked: secondaryActive == "live", object: "live"))
        if let subs = model?.subtitles {
            for sub in subs {
                let idStr = String(sub.id)
                secMenu.addItem(item(sub.title, nil, #selector(selectSecondarySubtitle(_:)),
                                     enabled: isLoaded, checked: secondaryActive == idStr, object: idStr))
            }
        }
        secMenu.addItem(.separator())
        secMenu.addItem(item(String(localized: "Below Primary Subtitles"), nil, #selector(selectSecondaryPosition(_:)),
                             enabled: true, checked: model?.secondarySubtitlePosition == "below", object: "below"))
        secMenu.addItem(item(String(localized: "Top of Video"), nil, #selector(selectSecondaryPosition(_:)),
                             enabled: true, checked: model?.secondarySubtitlePosition == "top", object: "top"))
        if model?.secondarySubtitlePosition == "below" {
            secMenu.addItem(.separator())
            let spacingHeader = NSMenuItem(title: String(localized: "Bilingual Subtitle Spacing"), action: nil, keyEquivalent: "")
            spacingHeader.isEnabled = false
            secMenu.addItem(spacingHeader)
            secMenu.addItem(item(String(localized: "Compact"), nil, #selector(selectBilingualSpacing(_:)),
                                 enabled: true, checked: model?.bilingualSubtitleSpacing != "standard", object: "compact"))
            secMenu.addItem(item(String(localized: "Standard"), nil, #selector(selectBilingualSpacing(_:)),
                                 enabled: true, checked: model?.bilingualSubtitleSpacing == "standard", object: "standard"))
        }
        secItem.submenu = secMenu
        subMenu.addItem(secItem)

        subMenu.addItem(item(String(localized: "Subtitle Settings…"), "slider.horizontal.3", #selector(subtitleSettingsAction), enabled: true))
        subMenu.addItem(.separator())
        subMenu.addItem(item(String(localized: "Copy Current Subtitle"), "doc.on.doc", #selector(copyCurrentSubtitleAction),
                             enabled: model?.hasActiveSubtitleText == true))
        subMenu.addItem(item(String(localized: "Load Subtitles…"), "doc.badge.plus", #selector(loadPrimarySubtitles), enabled: isLoaded))
        subMenu.addItem(item(String(localized: "Load Second Subtitles…"), "captions.bubble", #selector(loadSecondarySubtitles), enabled: isLoaded))
        subItem.submenu = subMenu
        if model?.systemHDRActive == true {
            secItem.isEnabled = false
            for entry in subMenu.items where entry.action == #selector(loadPrimarySubtitles) || entry.action == #selector(loadSecondarySubtitles) || entry.representedObject as? String == "live" { entry.isEnabled = false }
        }
        menu.addItem(subItem)

        // 3. Speed, Loop & Picture Submenus
        let speedItem = item(String(localized: "Playback Speed"), "speedometer", nil, enabled: isLoaded)
        let speedMenu = NSMenu(); speedMenu.autoenablesItems = false
        for spd in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0] {
            let active = abs((model?.speed ?? 1.0) - spd) < 0.01
            speedMenu.addItem(item("\(spd.formatted())×", nil, #selector(selectSpeed(_:)),
                                   enabled: isLoaded, checked: active, object: NSNumber(value: spd)))
        }
        speedItem.submenu = speedMenu
        playbackMenu.addItem(speedItem)

        let pictureMenu = submenu(String(localized: "Picture"), "slider.horizontal.3")
        if let loop = model?.playbackGeometry {
            let loopItem = item(String(localized: "A–B Loop"), "repeat", nil, enabled: isLoaded)
            let loopMenu = NSMenu(); loopMenu.autoenablesItems = false
            let desc = NSMenuItem(title: loop.loopDescription, action: nil, keyEquivalent: "")
            desc.isEnabled = false
            loopMenu.addItem(desc)
            loopMenu.addItem(item(String(localized: "Set A at Current Position"), "a.circle", #selector(selectLoopPoint(_:)),
                                  enabled: loop.canLoop, object: "a"))
            loopMenu.addItem(item(String(localized: "Set B and Start Loop"), "b.circle", #selector(selectLoopPoint(_:)),
                                  enabled: loop.canLoop && loop.start != nil, object: "b"))
            loopMenu.addItem(item(String(localized: "Clear A–B Loop"), "xmark.circle", #selector(selectLoopPoint(_:)),
                                  enabled: loop.hasLoopPoints, object: "clear"))
            loopItem.isEnabled = model?.systemHDRActive != true
            loopItem.submenu = loopMenu
            playbackMenu.addItem(loopItem)

            let aspectItem = item(String(localized: "Aspect Ratio"), "aspectratio", nil, enabled: loop.hasVideo)
            let aspectMenu = NSMenu(); aspectMenu.autoenablesItems = false
            aspectMenu.addItem(item(String(localized: "Original"), nil, #selector(selectAspectRatio(_:)),
                                    enabled: loop.hasVideo, checked: loop.aspect == "no", object: "no"))
            for preset in VideoRatio.presets {
                aspectMenu.addItem(item(preset.title, nil, #selector(selectAspectRatio(_:)),
                                        enabled: loop.hasVideo, checked: loop.aspect == preset.id, object: preset.id))
            }
            aspectItem.submenu = aspectMenu
            pictureMenu.addItem(aspectItem)
        }

        let rotItem = item(String(localized: "Rotation"), "rotate.right", nil, enabled: hasVideo)
        let rotMenu = NSMenu(); rotMenu.autoenablesItems = false
        for deg in [0, 90, 180, 270] {
            rotMenu.addItem(item("\(deg)°", nil, #selector(selectRotation(_:)),
                                 enabled: hasVideo, checked: model?.rotation == deg, object: NSNumber(value: deg)))
        }
        rotItem.submenu = rotMenu
        pictureMenu.addItem(rotItem)
        if model?.systemHDRActive == true {
            for entry in pictureMenu.items { entry.isEnabled = false }
        }

        menu.addItem(.separator())

        let imageMenu = submenu(String(localized: "Image"), "photo")
        // 4. Frame Capture, Live Text & Markers
        imageMenu.addItem(item(String(localized: "Copy Frame"), "doc.on.clipboard", #selector(copyFrame), enabled: isLoaded && model?.audioOnly != true))
        imageMenu.addItem(item(String(localized: "Save Image"), "camera", #selector(save), enabled: isLoaded && model?.audioOnly != true))
        imageMenu.addItem(item(String(localized: "Save Image As…"), "square.and.arrow.down", #selector(saveAs), enabled: isLoaded && model?.audioOnly != true))
        imageMenu.addItem(item(String(localized: "Export HDR Image…"), "sun.max", #selector(saveHDRAs), enabled: isLoaded && model?.systemHDRActive == true))
        imageMenu.addItem(item(String(localized: "Set Current Frame as Cover"), "photo.badge.checkmark", #selector(setCurrentFrameAsCover),
                          enabled: isLoaded && model?.audioOnly != true && model?.path.hasPrefix("/") == true))
        menu.addItem(item(String(localized: "Live Text"), "text.viewfinder", #selector(liveText),
                          enabled: isLoaded && model?.audioOnly != true && ImageAnalyzer.isSupported))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Add Time Marker"), "bookmark", #selector(addMarker), enabled: isLoaded))
        if let markers = model?.markers, !markers.isEmpty {
            let list = item(String(localized: "Time Markers"), "bookmark.fill", #selector(addMarker), enabled: isLoaded)
            let sub = NSMenu(); sub.autoenablesItems = false; list.submenu = sub
            let removeList = NSMenuItem(title: String(localized: "Remove Marker"), action: nil, keyEquivalent: "")
            let removeMenu = NSMenu(); removeMenu.autoenablesItems = false; removeList.submenu = removeMenu
            for marker in markers {
                for (targetMenu, action) in [(sub, #selector(jump(_:))), (removeMenu, #selector(remove(_:)))] {
                    let entry = NSMenuItem(title: Self.timestamp(marker.time) + " · " + marker.title, action: action, keyEquivalent: "")
                    entry.target = self; entry.representedObject = marker.id; targetMenu.addItem(entry)
                }
            }
            sub.addItem(.separator()); sub.addItem(removeList)
            menu.addItem(list)
        }

        let windowMenu = submenu(String(localized: "Window"), "macwindow")
        // Window & Finder actions
        windowMenu.addItem(item(model?.fullScreen == true ? String(localized: "Exit Full Screen") : String(localized: "Enter Full Screen"),
                          model?.fullScreen == true ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                          #selector(toggleFullScreenAction), enabled: model?.windowTransition != true))
        windowMenu.addItem(item(model?.miniPlayer == true ? String(localized: "Restore Player") : String(localized: "Mini Player"),
                          model?.miniPlayer == true ? "pip.exit" : "pip.enter",
                          #selector(toggleMiniPlayerAction), enabled: model?.windowTransition != true))
        windowMenu.addItem(item(String(localized: "Float on Top"),
                          model?.mainWindowFloatOnTop == true ? "pin.fill" : "pin",
                          #selector(toggleFloatOnTopAction),
                          enabled: model?.fullScreen != true && model?.miniPlayer != true,
                          checked: model?.mainWindowFloatOnTop == true))
        if model?.path.hasPrefix("/") == true {
            windowMenu.addItem(item(String(localized: "Show in Finder"), "folder", #selector(revealInFinderAction), enabled: true))
        }
        return menu
    }
    private var filename: String {
        let base = model.map { $0.path.hasPrefix("/") ? URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent : "Network-Frame" } ?? "Frame"
        return "\(base.prefix(48))-\(Int(max(0, model?.position ?? 0)))s-\(UUID().uuidString.prefix(8)).png"
    }
    @objc func copyFrame() {
        guard let model, model.loaded, !model.audioOnly else { return }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("iive-copy-\(UUID().uuidString).png")
        capture(to: temporary) { [weak self, weak model] error in
            guard let self, let model else {
                try? FileManager.default.removeItem(at: temporary)
                return
            }
            if let error {
                try? FileManager.default.removeItem(at: temporary)
                self.report(error)
                return
            }
            Task {
                let payload: (Data, NSImage)? = await Task.detached(priority: .userInitiated) {
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    guard let data = try? Data(contentsOf: temporary),
                          let image = NSImage(data: data) else { return nil }
                    return (data, image)
                }.value
                guard let (pngData, image) = payload else {
                    self.report("Could not decode frame image")
                    return
                }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setData(pngData, forType: .png)
                pb.writeObjects([image])
                model.osd.show("Frame Copied", symbol: "doc.on.clipboard.fill")
            }
        }
    }
    @objc func save() {
        guard model?.loaded == true else { return }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { report("Cannot create screenshot folder: " + error.localizedDescription); return }
        capture(to: folder.appendingPathComponent(filename)) { [weak self] error in self?.report(error) }
    }
    private func report(_ error: String?) {
        if let error {
            model?.error = "Screenshot failed: " + error
            model?.osd.show("Image could not be saved · Check the selected folder", symbol: "exclamationmark.triangle")
        }
        else { model?.osd.show("Image Saved", symbol: "camera.fill") }
    }
    @objc func saveAs() {
        guard let model, model.loaded else { return }
        model.fileDialogs.export(title: "Save Image As", filename: filename, type: .png,
                                 directory: folder, load: { [weak self] in
            guard let self else { throw CancellationError() }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("iive-save-\(UUID()).png")
            defer { try? FileManager.default.removeItem(at: temporary) }
            // Capture before displaying the dialog, preserving the requested frame.
            let error = await withCheckedContinuation { continuation in
                self.capture(to: temporary) { continuation.resume(returning: $0) }
            }
            try Task.checkCancellation()
            if let error { throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: error]) }
            return try await Task.detached(priority: .utility) {
                // Own the bytes before deleting the temporary PNG.
                try Data(contentsOf: temporary)
            }.value
        }) { [weak self] result in
            switch result {
            case .success: self?.report(nil)
            case .failure(let error): self?.report(error.localizedDescription)
            }
        }
    }
    @objc func saveHDRAs() {
        guard let model, model.loaded, model.systemHDRActive else { return }
        let name = (filename as NSString).deletingPathExtension + ".heic"
        model.fileDialogs.export(title: "Export HDR Image…", filename: name, type: .heic,
                                 directory: folder, load: { [weak model] in
            guard let model, model.systemHDRActive else { throw CancellationError() }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("luma-hdr-\(UUID()).heic")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await model.systemHDRPlayback.capture(to: temporary, preservingHDR: true)
            try Task.checkCancellation()
            return try await Task.detached(priority: .utility) { try Data(contentsOf: temporary) }.value
        }) { [weak self] result in
            switch result {
            case .success: self?.report(nil)
            case .failure(let error): self?.report(error.localizedDescription)
            }
        }
    }
    func chooseFolder() {
        model?.fileDialogs.importFiles(title: "Choose Screenshot Folder", types: [.folder], directory: folder) { [weak self] result in
            switch result {
            case .success(let urls): if let url = urls.first { self?.model?.screenshotFolder = url.path }
            case .failure(let error): self?.report(error.localizedDescription)
            }
        }
    }

    private func capture(to url: URL, sourceOnly: Bool = false, completion: @escaping @MainActor (String?) -> Void) {
        guard let model, let session = model.session, model.loaded else { completion("No video is loaded."); return }
        if model.systemHDRActive {
            let task = Task {
                do { try await model.systemHDRPlayback.capture(to: url, maximumPixelSize: sourceOnly ? 3200 : nil); completion(nil) }
                catch { completion(error.localizedDescription) }
            }
            if sourceOnly { textCaptureTask?.cancel(); textCaptureTask = task }
            return
        }
        if sourceOnly {
            session.saveSourceFrame(to: url.path, expectedPath: model.path) { error in
                MainActor.assumeIsolated { completion(error) }
            }
        } else {
            session.saveFrame(to: url.path, expectedPath: model.path) { error in
                MainActor.assumeIsolated { completion(error) }
            }
        }
    }
    @objc func setCurrentFrameAsCover() {
        guard let model, model.loaded, !model.audioOnly, model.path.hasPrefix("/") else { return }
        let mediaPath = model.path
        let mediaTitle = model.title
        let rawMetadata = model.snapshot["metadata"] as? [String: String] ?? [:]
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("iive-cover-\(UUID().uuidString).png")
        capture(to: temporary) { [weak self, weak model] error in
            guard let self, let model else {
                try? FileManager.default.removeItem(at: temporary)
                return
            }
            if let error {
                try? FileManager.default.removeItem(at: temporary)
                self.report(error)
                return
            }
            Task {
                do {
                    let processed = try await Task.detached(priority: .userInitiated) { () -> (posterURL: URL, posterImage: NSImage, thumbImage: NSImage, thumbData: Data, theme: MediaArtworkTheme?) in
                        defer { try? FileManager.default.removeItem(at: temporary) }
                        let mediaURL = URL(fileURLWithPath: mediaPath)
                        let folder = mediaURL.deletingLastPathComponent()
                        let base = mediaURL.deletingPathExtension().lastPathComponent
                        let posterURL = folder.appendingPathComponent("\(base)-poster.jpg")

                        guard let source = CGImageSourceCreateWithURL(temporary as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                              let fullCG = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                            throw CocoaError(.fileReadCorruptFile)
                        }

                        let jpegData = NSMutableData()
                        guard let dest = CGImageDestinationCreateWithData(jpegData, "public.jpeg" as CFString, 1, nil) else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                        CGImageDestinationAddImage(dest, fullCG, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
                        guard CGImageDestinationFinalize(dest) else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                        try (jpegData as Data).write(to: posterURL, options: .atomic)

                        // Remove any stale non-jpg -poster sidecar so <base>-poster.jpg is always picked first.
                        for ext in ["png", "heic", "webp", "jpeg"] {
                            let alt = folder.appendingPathComponent("\(base)-poster").appendingPathExtension(ext)
                            if alt != posterURL && FileManager.default.fileExists(atPath: alt.path) {
                                try? FileManager.default.removeItem(at: alt)
                            }
                        }

                        let posterCG = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 900,
                            kCGImageSourceShouldCacheImmediately: true
                        ] as CFDictionary) ?? fullCG
                        let posterImage = NSImage(cgImage: posterCG, size: NSSize(width: posterCG.width, height: posterCG.height))

                        let thumbCG = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 320,
                            kCGImageSourceShouldCacheImmediately: true
                        ] as CFDictionary) ?? posterCG
                        let thumbImage = NSImage(cgImage: thumbCG, size: NSSize(width: thumbCG.width, height: thumbCG.height))

                        let thumbMutable = NSMutableData()
                        if let thumbDest = CGImageDestinationCreateWithData(thumbMutable, "public.jpeg" as CFString, 1, nil) {
                            CGImageDestinationAddImage(thumbDest, thumbCG, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
                            _ = CGImageDestinationFinalize(thumbDest)
                        }
                        let thumbData = (thumbMutable.length > 0 ? (thumbMutable as Data) : (jpegData as Data))
                        let theme = MediaArtworkTheme.update(for: mediaPath, image: posterImage)
                        return (posterURL, posterImage, thumbImage, thumbData, theme)
                    }.value

                    await QueueMetadataCache.shared.updateCoverCache(
                        for: mediaPath,
                        detailImage: processed.posterImage,
                        thumbData: processed.thumbData
                    )
                    _ = try await MediaNFOCache.shared.applyCoverAndSaveNFO(
                        forMediaPath: mediaPath,
                        coverFileName: processed.posterURL.lastPathComponent,
                        fallbackTitle: mediaTitle,
                        rawMetadata: rawMetadata
                    )

                    await MainActor.run {
                        let stdPath = URL(fileURLWithPath: mediaPath).standardizedFileURL.path
                        ThumbnailImageCache.shared.store(key: mediaPath, image: processed.thumbImage, duration: nil, size: nil)
                        if stdPath != mediaPath {
                            ThumbnailImageCache.shared.store(key: stdPath, image: processed.thumbImage, duration: nil, size: nil)
                        }
                        model.applyUpdatedCover(processed.posterImage, for: mediaPath)
                        NotificationCenter.default.post(name: .mediaCoverDidChange, object: mediaPath)
                        model.osd.show("Cover Updated", symbol: "photo.badge.checkmark")
                    }
                } catch {
                    await MainActor.run {
                        model.error = String(localized: "Failed to set cover") + ": " + error.localizedDescription
                        model.osd.show("Failed to set cover", symbol: "exclamationmark.triangle")
                    }
                }
            }
        }
    }
    @objc func liveText() {
        guard ImageAnalyzer.isSupported, let model, model.loaded, !model.audioOnly else { return }
        // Focus a pending capture; completed results are replaced in the same window.
        if textSession.focusIfBusy() { return }
        model.command(["set", "pause", "yes"])
        let source = (model.title.isEmpty ? "Current Frame" : model.title) + " · " + Self.timestamp(model.position)
        let request = textSession.begin(source: source)
        textSession.onCancelCapture = { [weak self] in
            self?.textCaptureTask?.cancel(); self?.textCaptureTask = nil
        }
        let requestID = request.id
        let result = request.result
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iive-text-\(UUID()).png")
        capture(to: url, sourceOnly: true) { [weak self, weak result] error in
            guard let self, let result, self.textSession.contains(requestID) else {
                try? FileManager.default.removeItem(at: url); return
            }
            if let error {
                try? FileManager.default.removeItem(at: url)
                result.fail("Frame capture failed: " + error); return
            }
            Task { @MainActor [weak self, weak result] in
                let cgImage = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                    defer { try? FileManager.default.removeItem(at: url) }
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 3200,
                        kCGImageSourceShouldCacheImmediately: true
                    ] as CFDictionary)
                }.value
                guard let self, let result, self.textSession.contains(requestID) else { return }
                self.textCaptureTask = nil
                guard let cgImage else { result.fail("The captured image could not be read."); return }
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                result.recognize(image)
            }
        }
    }
    static func timestamp(_ value: Double) -> String {
        let seconds = Int(min(Double(Int32.max), max(0, value.isFinite ? value : 0)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}
