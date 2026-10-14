// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AVFoundation

/// Use the system glass renderer; respect the system's transparency preference.
/// Do not attach `.interactive()` to the container background itself, otherwise clicking the
/// transport panel or dragging sliders triggers a container-wide press state that recolors child controls.
struct PlaybackGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var opaque
    func body(content: Content) -> some View {
        if opaque {
            content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 24))
        } else {
            // A dark scrim keeps controls readable even over saturated video;
            // OpenGL video does not always participate in system backdrop blur.
            content.background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 24))
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
        }
    }
}

/// Consistent white icon/label button style that never shifts tint when panel responder state changes.
private struct TransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.65 : 1.0)
            .contentShape(Rectangle())
    }
}

/// Lightweight background thumbnail generator for timeline hover/scrub previews.
/// Uses a single cached AVAssetImageGenerator for the current media file without touching libmpv.
actor TimelinePreviewGenerator {
    static let shared = TimelinePreviewGenerator()
    private var activePath = ""
    private var generator: AVAssetImageGenerator?
    private var cache: [Int: CGImage] = [:]

    func thumbnail(for path: String, at seconds: Double) async -> CGImage? {
        guard !path.isEmpty, seconds.isFinite, seconds >= 0 else { return nil }
        if path != activePath {
            activePath = path
            cache.removeAll(keepingCapacity: true)
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 320, height: 180)
            let tolerance = CMTime(seconds: 0.4, preferredTimescale: 600)
            gen.requestedTimeToleranceBefore = tolerance
            gen.requestedTimeToleranceAfter = tolerance
            generator = gen
        }
        let bucket = Int((seconds * 2).rounded())
        if let hit = cache[bucket] { return hit }
        guard let gen = generator else { return nil }
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        guard let result = try? await gen.image(at: time) else { return nil }
        if cache.count >= 96 { cache.removeAll(keepingCapacity: true) }
        cache[bucket] = result.image
        return result.image
    }
}

private struct TimelinePreviewBubble: View {
    let image: CGImage?
    let timestamp: String
    let chapter: String?
    var compact = false
    var body: some View {
        let thumbW: CGFloat = compact ? 120 : 160
        let thumbH: CGFloat = compact ? 68 : 90
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.black.opacity(0.65))
                if let image {
                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .scaledToFill()
                        .frame(width: thumbW, height: thumbH)
                        .clipped()
                } else {
                    Image(systemName: "film")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .frame(width: thumbW, height: thumbH)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.16), lineWidth: 0.5))

            if let chapter, !chapter.isEmpty {
                Text(chapter)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .frame(maxWidth: thumbW)
            }
            Text(timestamp)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(6)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
        .allowsHitTesting(false)
    }
}

struct FloatingTransport: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: PlayerModel
    @Binding var scrubbing: Bool
    @Binding var settings: Bool
    var body: some View {
        let queueActive = model.queuePopover || (model.inspector && !model.fullScreen && model.sidebarTab == "queue")
        let settingsActive = settings || (model.inspector && !model.fullScreen && model.sidebarTab == "enhance")
        VStack(spacing: 12) {
            PlaybackTimeline(model: model, timeline: model.timeline, scrubbing: $scrubbing)
            HStack(spacing: 12) {
                Button { model.skip(-1) } label: { Image(systemName: "gobackward") }
                    .accessibilityLabel("Back \(Int(model.seekSeconds)) seconds").help("Back \(Int(model.seekSeconds)) seconds (←)")
                Button { model.togglePause() } label: { Image(systemName: model.paused ? "play.fill" : "pause.fill").frame(width: 24) }
                    .accessibilityLabel(model.paused ? "Play" : "Pause").help("Play / Pause (Space)")
                Button { model.skip(1) } label: { Image(systemName: "goforward") }
                    .accessibilityLabel("Forward \(Int(model.seekSeconds)) seconds").help("Forward \(Int(model.seekSeconds)) seconds (→)")
                NativePlayerMenu(model: model, title: "\(model.speed.formatted())×", help: "Playback speed", entries: { model.speedMenuEntries() })
                    .frame(width: 55, height: 26)
                NativePlayerMenu(model: model, symbol: "ellipsis.circle", help: "Playback options", entries: { model.playbackMenuEntries(openSettings: { openSettings() }) })
                    .frame(width: 28, height: 26)
                Spacer(minLength: 0)
                Button { model.toggleMute() } label: {
                    Image(systemName: model.muted || model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2").font(.callout)
                }.accessibilityLabel(model.muted ? "Unmute" : "Mute").help("Mute (M)")
                Slider(value: Binding(get: { model.volume }, set: { model.setVolume($0) }), in: 0...100)
                    .frame(width: 72).accessibilityLabel("Volume")
                Button { model.showSidebar("queue") } label: {
                    Image(systemName: "list.bullet")
                        .opacity(queueActive ? 1.0 : 0.78)
                }
                .accessibilityLabel("Play Queue").help("Play Queue (⇧⌘P)")
                .popover(isPresented: $model.queuePopover, arrowEdge: .top) {
                    QueueView(model: model).frame(width: 360, height: 420)
                }
                Button { model.showVideoInfo.toggle() } label: {
                    Image(systemName: model.showVideoInfo ? "info.circle.fill" : "info.circle")
                        .opacity(model.showVideoInfo ? 1.0 : 0.78)
                }
                .accessibilityLabel("Video information").help("Video information (⌘I)")
                Button { model.queuePopover = false; settings.toggle() } label: {
                    Image(systemName: "slider.horizontal.3")
                        .opacity(settingsActive ? 1.0 : 0.78)
                }
                .accessibilityLabel("Quick settings").help("Enhancement settings")
                .popover(isPresented: $settings, arrowEdge: .top) { QuickEnhancementSettings(model: model) }
                Button { model.toggleMiniPlayer() } label: { Image(systemName: model.miniPlayer ? "pip.exit" : "pip.enter") }
                    .accessibilityLabel("Mini Player").help("Mini Player (⌥⌘P)")
                    .disabled(model.windowTransition)
                Button { model.toggleFullScreen() } label: { Image(systemName: model.fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                    .accessibilityLabel(model.fullScreen ? "Exit Full Screen" : "Enter Full Screen").help("Full screen (⌃⌘F)")
            }
            .font(.title3)
            .buttonStyle(TransportButtonStyle())
            .focusEffectDisabled()
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .modifier(PlaybackGlass())
    }
}

/// Preview locally while dragging; send one exact seek on release. Shared by both window modes.
/// Observes `PlayerTimelineState` independently so 4 Hz time updates only redraw the timeline bar.
struct PlaybackTimeline: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var timeline: PlayerTimelineState
    @Binding var scrubbing: Bool
    var compact = false
    @State private var preview: Double?
    @State private var hoverTime: Double?
    @State private var hoverRatio = CGFloat(0)
    @State private var sliderWidth = CGFloat(0)
    @State private var previewImage: CGImage?
    private var limit: Double { timeline.duration.isFinite ? max(1, timeline.duration) : 1 }
    private func bounded(_ value: Double) -> Double { value.isFinite ? min(limit, max(0, value)) : 0 }
    private var activePreviewTime: Double? {
        guard model.showTimelinePreview, model.loaded, timeline.duration > 0 else { return nil }
        return preview ?? hoverTime
    }
    private var previewBucketKey: String {
        guard let target = activePreviewTime, !model.path.isEmpty else { return "" }
        return "\(model.path)#\(Int((target * 2).rounded()))"
    }
    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            Text(time(preview ?? timeline.position))
                .frame(minWidth: compact ? 34 : 50, alignment: .trailing)
            Slider(value: Binding(get: { bounded(preview ?? timeline.position) }, set: { preview = bounded($0) }), in: 0...limit) { editing in
                // Keep the preview optional: touching the thumb without moving must not seek.
                if editing { scrubbing = true }
                else if scrubbing {
                    scrubbing = false
                    if let preview { model.seek(bounded(preview)) }
                    preview = nil
                }
            }
            .controlSize(compact ? .small : .regular)
            .focusEffectDisabled()
            .accessibilityLabel("Playback position")
            .disabled(!model.loaded || timeline.duration <= 0)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                if abs(sliderWidth - width) > 0.5 { sliderWidth = width }
            }
            .onContinuousHover { phase in
                guard model.showTimelinePreview, model.loaded, timeline.duration > 0, sliderWidth > 16 else {
                    if hoverTime != nil { hoverTime = nil }
                    return
                }
                switch phase {
                case .active(let location):
                    let inset: CGFloat = 8
                    let usable = max(1, sliderWidth - inset * 2)
                    let ratio = min(1, max(0, (location.x - inset) / usable))
                    hoverRatio = ratio
                    hoverTime = bounded(Double(ratio) * limit)
                case .ended:
                    hoverTime = nil
                }
            }
            .overlay(alignment: .topLeading) {
                if let targetTime = activePreviewTime, sliderWidth > 16 {
                    let bubbleW: CGFloat = compact ? 132 : 172
                    let ratio = preview != nil ? CGFloat(bounded(targetTime) / limit) : hoverRatio
                    let rawX = ratio * sliderWidth - bubbleW * 0.5
                    let clampedX = min(max(0, rawX), max(0, sliderWidth - bubbleW))
                    TimelinePreviewBubble(
                        image: previewImage,
                        timestamp: time(targetTime),
                        chapter: model.chapterTitle(at: targetTime),
                        compact: compact
                    )
                    .offset(x: clampedX, y: compact ? -108 : -136)
                }
            }
            if !compact { Text(time(timeline.duration)).frame(minWidth: 50, alignment: .leading) }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white.opacity(0.75))
        .task(id: previewBucketKey) {
            guard let target = activePreviewTime, !model.path.isEmpty else { return }
            if let img = await TimelinePreviewGenerator.shared.thumbnail(for: model.path, at: target),
               !Task.isCancelled {
                previewImage = img
            }
        }
        .onChange(of: model.path) {
            scrubbing = false
            preview = nil
            hoverTime = nil
            previewImage = nil
        }
        .onDisappear {
            scrubbing = false
            preview = nil
            hoverTime = nil
        }
        .help("\(time(timeline.position)) / \(time(timeline.duration)) · Drag to seek")
    }
    private func time(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "--:--" }
        let seconds = Int(min(value, Double(Int32.max)))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct EnhancementControls: View {
    @ObservedObject var model: PlayerModel
    var body: some View {
        Group {
            Toggle("Enhancement", isOn: $model.master)
            Picker("Super Resolution", selection: $model.sr) {
                Text("Off").tag("off")
                Text("FSRCNNX Metal · Fast").tag("fsrcnnx_metal8")
                Text("FSRCNNX Metal · Quality").tag("fsrcnnx_metal16")
                Text("Apple · Low Latency").tag("apple")
                Text("FSRCNNX GLSL · 8").tag("fsrcnnx8")
                Text("FSRCNNX GLSL · 16").tag("fsrcnnx16")
            }
            Picker("Interpolation", selection: $model.fi) {
                Text("Off").tag("off"); Text("RIFE Metal").tag("rife"); Text("Apple · 2×").tag("apple")
            }
            if model.fi == "rife" {
                Picker("Model", selection: $model.tier) {
                    Text("Fast").tag("fast"); Text("Balanced · Heavy").tag("balanced"); Text("HQ · Experimental").tag("hq")
                }
                Picker("Target FPS", selection: $model.targetFPS) {
                    Text("48").tag(48); Text("60").tag(60)
                }.pickerStyle(.segmented)
            }
            Text(model.srStatus).font(.caption).foregroundStyle(.secondary)
            Text(model.fiStatus).font(.caption).foregroundStyle(.secondary)
            Toggle("Performance Fallback", isOn: $model.automatic)
        }
    }
}
struct QuickEnhancementSettings: View {
    @ObservedObject var model: PlayerModel
    var body: some View {
        Form {
            Section("Enhancement") { EnhancementControls(model: model) }
            Section("Decoder") { DecoderSettings(model: model) }
            Toggle("Show Live Video Information", isOn: $model.showVideoInfo)
            Toggle("Show Timeline Hover Preview", isOn: $model.showTimelinePreview)
            SettingsLink { Label("Open Settings…", systemImage: "gearshape") }
        }.formStyle(.grouped).frame(width: 360).fixedSize(horizontal: false, vertical: true)
            .background(.background)
    }
}

/// Capture this player's window instead of whichever window happens to be key.
struct PlayerWindowReader: NSViewRepresentable {
    var model: PlayerModel
    final class Probe: NSView {
        weak var model: PlayerModel?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.titleVisibility = .hidden
            window.backgroundColor = .black
            // Publish after AppKit has finished attaching the SwiftUI hierarchy.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let model = self?.model, let window else { return }
                model.window = window
                model.fullScreen = window.styleMask.contains(.fullScreen)
            }
        }
    }
    func makeNSView(context: Context) -> Probe { let probe = Probe(); probe.model = model; return probe }
    func updateNSView(_ nsView: Probe, context: Context) {}
}

/// A frozen native menu tree avoids replacing open submenus on every playback snapshot.
struct PlayerMenuEntry {
    var title: String
    var symbol: String = ""
    var selected = false
    var enabled = true
    var children: [PlayerMenuEntry]? = nil
    var action: (() -> Void)? = nil
    static var separator: Self { Self(title: "-") }
}
struct NativePlayerMenu: NSViewRepresentable {
    var model: PlayerModel
    var title = ""
    var symbol = ""
    var help: String
    var entries: () -> [PlayerMenuEntry]
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.appearance = NSAppearance(named: .darkAqua)
        button.contentTintColor = .white
        button.focusRingType = .none
        if let cell = button.cell as? NSPopUpButtonCell {
            cell.highlightsBy = []
            cell.showsStateBy = []
            cell.arrowPosition = .noArrow
        }
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.setAccessibilityLabel(help)
        button.toolTip = help
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        button.menu = menu
        context.coordinator.install(menu)
        return button
    }
    func updateNSView(_ view: NSPopUpButton, context: Context) {
        // Update the next-open builder only, never mutate a menu or control being tracked.
        context.coordinator.parent = self
        guard !context.coordinator.tracking else { return }
        if let first = view.menu?.items.first {
            context.coordinator.configureLabelItem(first)
        }
    }
    static func dismantleNSView(_ view: NSPopUpButton, coordinator: Coordinator) {
        view.menu?.cancelTracking()
    }
    @MainActor final class Coordinator: NSObject, NSMenuDelegate {
        var parent: NativePlayerMenu
        var tracking = false
        private var actions: [() -> Void] = []
        init(_ parent: NativePlayerMenu) { self.parent = parent }
        func configureLabelItem(_ label: NSMenuItem) {
            if parent.title.isEmpty {
                label.title = ""
            } else {
                label.attributedTitle = NSAttributedString(
                    string: parent.title,
                    attributes: [
                        .foregroundColor: NSColor.white,
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
                    ]
                )
            }
            if !parent.symbol.isEmpty {
                let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                    .applying(.init(paletteColors: [.white]))
                let img = NSImage(systemSymbolName: parent.symbol, accessibilityDescription: parent.help)?
                    .withSymbolConfiguration(config)
                img?.isTemplate = false
                label.image = img
            }
        }
        func install(_ menu: NSMenu) {
            guard !tracking else { return }
            menu.removeAllItems(); actions.removeAll()
            let label = NSMenuItem(title: parent.title, action: nil, keyEquivalent: "")
            configureLabelItem(label)
            menu.addItem(label) // Pull-down button label, not a selectable menu entry.
            append(parent.entries(), to: menu)
        }
        private func append(_ entries: [PlayerMenuEntry], to menu: NSMenu) {
            for entry in entries {
                if entry.title == "-" { menu.addItem(.separator()); continue }
                let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                item.isEnabled = entry.enabled
                item.state = entry.selected ? .on : .off
                if !entry.symbol.isEmpty {
                    item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
                    item.image?.isTemplate = true
                }
                if let children = entry.children {
                    let sub = NSMenu(title: entry.title); sub.autoenablesItems = false
                    append(children, to: sub); item.submenu = sub
                } else if let action = entry.action {
                    item.target = self; item.action = #selector(choose(_:))
                    item.tag = actions.count; actions.append(action)
                }
                menu.addItem(item)
            }
        }
        func menuNeedsUpdate(_ menu: NSMenu) { install(menu) }
        func menuWillOpen(_ menu: NSMenu) { tracking = true; parent.model.menuTracking = true }
        func menuDidClose(_ menu: NSMenu) {
            tracking = false
            let model = parent.model
            DispatchQueue.main.async { model.menuTracking = false }
        }
        @objc private func choose(_ sender: NSMenuItem) {
            guard actions.indices.contains(sender.tag) else { return }
            let action = actions[sender.tag]
            DispatchQueue.main.async { action() }
        }
    }
}

extension PlayerModel {
    func decoderMenuEntries() -> [PlayerMenuEntry] {
        [("Software", "cpu", "no"), ("Auto · Hardware Enabled", "bolt.circle", "auto"), ("Hardware · Copy", "square.on.square", "videotoolbox-copy")].map { title, icon, value in
            PlayerMenuEntry(title: title, symbol: icon, selected: decoder == value, action: { self.decoder = value })
        }
    }
    func speedMenuEntries() -> [PlayerMenuEntry] {
        [0.5, 0.75, 1.0, 1.25, 1.5, 2.0].map { value in
            PlayerMenuEntry(title: "\(value.formatted())×", symbol: "speedometer", selected: speed == value, action: { self.setSpeed(value) })
        }
    }
    func playbackMenuEntries(openSettings: @escaping () -> Void) -> [PlayerMenuEntry] {
        var chapterItems = chapters.map { chapter in PlayerMenuEntry(title: chapter.title, symbol: "bookmark", action: { self.seek(chapter.time) }) }
        if chapterItems.isEmpty { chapterItems = [PlayerMenuEntry(title: "No chapters available", enabled: false)] }
        let rotationItems = [0, 90, 180, 270].map { degrees in
            PlayerMenuEntry(title: "\(degrees)°", symbol: "rotate.right", selected: rotation == degrees, action: { self.rotation = degrees })
        }
        var profiles = [("Automatic · Source Metadata", "auto"), ("Current Display ICC", "display"), ("sRGB ICC", "srgb"), ("Display P3 ICC", "p3")].map { title, value in
            PlayerMenuEntry(title: title, symbol: "paintpalette", selected: colorProfile == value, action: { self.colorProfile = value })
        }
        if UserDefaults.standard.data(forKey: "customICCData") != nil {
            profiles.append(PlayerMenuEntry(title: "Custom ICC", symbol: "doc", selected: colorProfile == "custom", action: { self.colorProfile = "custom" }))
        }
        profiles.append(PlayerMenuEntry(title: "Load RGB ICC Profile…", symbol: "doc.badge.plus", action: { self.chooseColorProfile() }))
        return [
            PlayerMenuEntry(title: miniPlayer ? "Restore Player" : "Mini Player", symbol: "pip", action: { self.toggleMiniPlayer() }),
            PlayerMenuEntry(title: "Play Queue", symbol: "list.bullet", action: { self.showSidebar("queue") }),
            PlayerMenuEntry(title: "Timeline Hover Preview", symbol: "photo.on.rectangle.angled", selected: showTimelinePreview, action: { self.showTimelinePreview.toggle() }),
            PlayerMenuEntry(title: "Previous Video", symbol: "backward.end", enabled: canPrevious, action: { self.previousFile() }),
            PlayerMenuEntry(title: "Next Video", symbol: "forward.end", enabled: canNext, action: { self.nextFile() }),
            PlayerMenuEntry(title: "Chapters", symbol: "bookmark", children: chapterItems),
            PlayerMenuEntry(title: "Speed", symbol: "speedometer", children: speedMenuEntries()),
            PlayerMenuEntry(title: "Repeat", symbol: "repeat", children: [("Off", "off"), ("Current Video", "file"), ("Play Queue", "queue")].map { title, value in
                PlayerMenuEntry(title: title, selected: repeatMode == value, action: { self.repeatMode = value })
            }),
            .separator,
            PlayerMenuEntry(title: "Decoder", symbol: "cpu", children: decoderMenuEntries()),
            PlayerMenuEntry(title: "Rotation", symbol: "rotate.right", children: rotationItems),
            PlayerMenuEntry(title: "Video Looks", symbol: "camera.filters", children: [("Neutral", "neutral"), ("Vivid", "vivid"), ("Soft", "soft"), ("Monochrome", "mono")].map { title, value in
                PlayerMenuEntry(title: title, symbol: "camera.filters", action: { self.applyLook(value) })
            }),
            PlayerMenuEntry(title: "Output Color Profile", symbol: "paintpalette", children: profiles),
            .separator,
            PlayerMenuEntry(title: "Step Forward One Frame", symbol: "forward.frame", enabled: loaded, action: { self.stepFrame() }),
            PlayerMenuEntry(title: "Save Screenshot…", symbol: "camera", enabled: loaded, action: { self.saveScreenshot() }),
            PlayerMenuEntry(title: "Settings…", symbol: "gearshape", action: openSettings)
        ]
    }
    func queueMenuEntries() -> [PlayerMenuEntry] {
        [
            PlayerMenuEntry(title: "Sort", symbol: "arrow.up.arrow.down", children: [("Custom / Added Order", "custom", "line.3.horizontal"), ("Filename", "name", "textformat.abc"), ("Date Created · Oldest First", "created", "calendar")].map { title, value, icon in
                PlayerMenuEntry(title: title, symbol: icon, selected: queueSort == value, action: { self.queueSort = value })
            }),
            PlayerMenuEntry(title: "Display", symbol: "list.bullet.rectangle", children: [
                PlayerMenuEntry(title: "Title & Duration", symbol: "list.bullet", selected: !queueDetailed, action: { self.queueDetailed = false }),
                PlayerMenuEntry(title: "Cover, Title, Duration & Size", symbol: "photo.on.rectangle", selected: queueDetailed, action: { self.queueDetailed = true })
            ]), .separator,
            PlayerMenuEntry(title: "Add Media from the Same Folder", symbol: "folder.badge.plus", selected: autoQueueFolder, action: { self.autoQueueFolder.toggle() }),
            PlayerMenuEntry(title: "Scan Current Folder", symbol: "arrow.clockwise", enabled: autoQueueFolder && !path.isEmpty, action: { self.enqueueFolder(around: URL(fileURLWithPath: self.path)) })
        ]
    }
}
