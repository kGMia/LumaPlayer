// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AVFoundation

/// Use the system glass renderer; respect the system's transparency preference.
/// Do not attach `.interactive()` to the container background itself, otherwise clicking the
/// transport panel or dragging sliders triggers a container-wide press state that recolors child controls.
struct PlaybackGlass: ViewModifier {
    var cornerRadius: CGFloat = 24
    @Environment(\.accessibilityReduceTransparency) private var opaque
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if opaque {
            content.background(Color(nsColor: .windowBackgroundColor), in: shape)
        } else {
            // A dark scrim keeps controls readable even over saturated video;
            // OpenGL video does not always participate in system backdrop blur.
            content.background(.black.opacity(0.55), in: shape)
                .glassEffect(.regular, in: shape)
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

/// Minimalist QuickTime-style clean white capsule slider used for volume control.
struct CleanWhiteVolumeBar: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    @State private var isHovering = false
    @State private var isDragging = false

    private var normalized: CGFloat {
        let span = max(0.0001, range.upperBound - range.lowerBound)
        return CGFloat(min(1, max(0, (value - range.lowerBound) / span)))
    }

    var body: some View {
        GeometryReader { proxy in
            let w = max(1, proxy.size.width)
            let h = proxy.size.height
            let barH: CGFloat = (isHovering || isDragging) ? 6 : 4
            let fillW = max(barH, w * normalized)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.24))
                    .frame(height: barH)
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.95))
                    .frame(width: normalized > 0.001 ? fillW : 0, height: barH)
                if isHovering || isDragging {
                    Circle()
                        .fill(.white)
                        .frame(width: 10, height: 10)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .offset(x: min(max(0, w * normalized - 5), max(0, w - 10)))
                }
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    if !isHovering { isHovering = true }
                case .ended:
                    if isHovering { isHovering = false }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging { isDragging = true }
                        let ratio = min(1, max(0, Double(gesture.location.x / w)))
                        value = range.lowerBound + ratio * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .animation(.easeOut(duration: 0.12), value: isHovering || isDragging)
        }
        .frame(width: 72, height: 18)
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
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 12))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
        .allowsHitTesting(false)
    }
}

private struct PlaybackSpeedMenu: View {
    @ObservedObject var model: PlayerModel
    var body: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                Button {
                    model.setSpeed(value)
                } label: {
                    if abs(model.speed - value) < 0.01 {
                        Label("\(value.formatted())×", systemImage: "checkmark")
                    } else {
                        Text("\(value.formatted())×")
                    }
                }
            }
        } label: {
            Text("\(model.speed.formatted())×")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 52, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Playback speed")
    }
}

private struct PlaybackOptionsMenu: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var model: PlayerModel
    var body: some View {
        Menu {
            Button {
                model.toggleMiniPlayer()
            } label: {
                Label(model.miniPlayer ? "Restore Player" : "Mini Player", systemImage: "pip")
            }
            Button {
                model.showSidebar("queue")
            } label: {
                Label("Play Queue", systemImage: "list.bullet")
            }
            Toggle(isOn: $model.showTimelinePreview) {
                Label("Timeline Hover Preview", systemImage: "photo.on.rectangle.angled")
            }
            Button {
                model.previousFile()
            } label: {
                Label("Previous Video", systemImage: "backward.end")
            }
            .disabled(!model.canPrevious)
            Button {
                model.nextFile()
            } label: {
                Label("Next Video", systemImage: "forward.end")
            }
            .disabled(!model.canNext)

            Menu {
                if model.chapters.isEmpty {
                    Text("No chapters available")
                } else {
                    ForEach(model.chapters) { chapter in
                        Button(chapter.title) { model.seek(chapter.time) }
                    }
                }
            } label: {
                Label("Chapters", systemImage: "bookmark")
            }

            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                    Button {
                        model.setSpeed(value)
                    } label: {
                        if abs(model.speed - value) < 0.01 {
                            Label("\(value.formatted())×", systemImage: "checkmark")
                        } else {
                            Text("\(value.formatted())×")
                        }
                    }
                }
            } label: {
                Label("Speed", systemImage: "speedometer")
            }

            Picker(selection: $model.repeatMode) {
                Text("Off").tag("off")
                Text("Current Video").tag("file")
                Text("Play Queue").tag("queue")
            } label: {
                Label("Repeat", systemImage: "repeat")
            }

            Divider()

            Picker(selection: $model.decoder) {
                Label("Software", systemImage: "cpu").tag("no")
                Label("Auto · Hardware Enabled", systemImage: "bolt.circle").tag("auto")
                Label("Hardware · Copy", systemImage: "square.on.square").tag("videotoolbox-copy")
            } label: {
                Label("Decoder", systemImage: "cpu")
            }

            Picker(selection: $model.rotation) {
                Text("0°").tag(0)
                Text("90°").tag(90)
                Text("180°").tag(180)
                Text("270°").tag(270)
            } label: {
                Label("Rotation", systemImage: "rotate.right")
            }

            Menu {
                Button("Neutral") { model.applyLook("neutral") }
                Button("Vivid") { model.applyLook("vivid") }
                Button("Soft") { model.applyLook("soft") }
                Button("Monochrome") { model.applyLook("mono") }
            } label: {
                Label("Video Looks", systemImage: "camera.filters")
            }

            Menu {
                Picker("Output Color Profile", selection: $model.colorProfile) {
                    Text("Automatic · Source Metadata").tag("auto")
                    Text("Current Display ICC").tag("display")
                    Text("sRGB ICC").tag("srgb")
                    Text("Display P3 ICC").tag("p3")
                    if UserDefaults.standard.data(forKey: "customICCData") != nil {
                        Text("Custom ICC").tag("custom")
                    }
                }
                .labelsHidden()
                Divider()
                Button {
                    model.chooseColorProfile()
                } label: {
                    Label("Load RGB ICC Profile…", systemImage: "doc.badge.plus")
                }
            } label: {
                Label("Output Color Profile", systemImage: "paintpalette")
            }

            Divider()

            Button {
                model.stepFrame()
            } label: {
                Label("Step Forward One Frame", systemImage: "forward.frame")
            }
            .disabled(!model.loaded)

            Button {
                model.saveScreenshot()
            } label: {
                Label("Save Screenshot…", systemImage: "camera")
            }
            .disabled(!model.loaded)

            Button {
                openSettings()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Playback options")
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
                PlaybackSpeedMenu(model: model)
                PlaybackOptionsMenu(model: model)
                Spacer(minLength: 0)
                Button { model.toggleMute() } label: {
                    Image(systemName: model.muted || model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2").font(.callout)
                }.accessibilityLabel(model.muted ? "Unmute" : "Mute").help("Mute (M)")
                CleanWhiteVolumeBar(
                    value: Binding(get: { model.volume }, set: { model.setVolume($0) }),
                    range: 0...100
                )
                .accessibilityLabel("Volume")
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
        .modifier(PlaybackGlass(cornerRadius: 24))
    }
}

/// Preview locally while dragging; send one exact seek on release. Shared by both window modes.
/// Uses a clean QuickTime-style minimalist white capsule bar and observes `PlayerTimelineState` independently.
struct PlaybackTimeline: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var timeline: PlayerTimelineState
    @Binding var scrubbing: Bool
    var compact = false
    @State private var preview: Double?
    @State private var hoverTime: Double?
    @State private var hoverRatio = CGFloat(0)
    @State private var sliderWidth = CGFloat(0)
    @State private var isHoveringTrack = false
    @State private var previewImage: CGImage?
    private var limit: Double { timeline.duration.isFinite ? max(1, timeline.duration) : 1 }
    private func bounded(_ value: Double) -> Double { value.isFinite ? min(limit, max(0, value)) : 0 }
    private var activeValue: Double { bounded(preview ?? timeline.position) }
    private var progressRatio: CGFloat { CGFloat(min(1, max(0, activeValue / limit))) }
    private var activePreviewTime: Double? {
        guard model.showTimelinePreview, model.loaded, timeline.duration > 0 else { return nil }
        return preview ?? hoverTime
    }
    private var previewBucketKey: String {
        guard let target = activePreviewTime, !model.path.isEmpty else { return "" }
        return "\(model.path)#\(Int((target * 2).rounded()))"
    }
    var body: some View {
        let interactive = model.loaded && timeline.duration > 0
        let barHeight: CGFloat = (isHoveringTrack || scrubbing) ? (compact ? 5.5 : 6.5) : (compact ? 3.5 : 4.5)
        let knobSize: CGFloat = compact ? 9 : 11
        HStack(spacing: compact ? 6 : 10) {
            Text(time(activeValue))
                .frame(minWidth: compact ? 34 : 50, alignment: .trailing)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.24))
                    .frame(height: barHeight)

                if let hoverTime, !scrubbing, isHoveringTrack {
                    let hRatio = CGFloat(min(1, max(0, hoverTime / limit)))
                    Capsule(style: .continuous)
                        .fill(.white.opacity(0.18))
                        .frame(width: max(barHeight, sliderWidth * hRatio), height: barHeight)
                }

                Capsule(style: .continuous)
                    .fill(.white)
                    .frame(width: progressRatio > 0.001 ? max(barHeight, sliderWidth * progressRatio) : 0, height: barHeight)

                if (isHoveringTrack || scrubbing) && interactive {
                    Circle()
                        .fill(.white)
                        .frame(width: knobSize, height: knobSize)
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .offset(x: min(max(0, sliderWidth * progressRatio - knobSize * 0.5), max(0, sliderWidth - knobSize)))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 16 : 20)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: isHoveringTrack || scrubbing)
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(time(activeValue)) of \(time(timeline.duration))")
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                if abs(sliderWidth - width) > 0.5 { sliderWidth = width }
            }
            .onContinuousHover { phase in
                guard interactive, sliderWidth > 8 else {
                    if isHoveringTrack { isHoveringTrack = false }
                    if hoverTime != nil { hoverTime = nil }
                    return
                }
                switch phase {
                case .active(let location):
                    if !isHoveringTrack { isHoveringTrack = true }
                    let ratio = min(1, max(0, location.x / max(1, sliderWidth)))
                    hoverRatio = ratio
                    hoverTime = model.showTimelinePreview ? bounded(Double(ratio) * limit) : nil
                case .ended:
                    isHoveringTrack = false
                    hoverTime = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard interactive, sliderWidth > 8 else { return }
                        if !scrubbing { scrubbing = true }
                        let ratio = min(1, max(0, gesture.location.x / max(1, sliderWidth)))
                        hoverRatio = ratio
                        preview = bounded(Double(ratio) * limit)
                    }
                    .onEnded { gesture in
                        guard interactive else { return }
                        let ratio = min(1, max(0, gesture.location.x / max(1, sliderWidth)))
                        let finalTime = preview ?? bounded(Double(ratio) * limit)
                        scrubbing = false
                        preview = nil
                        model.seek(bounded(finalTime))
                    }
            )
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
                    .offset(x: clampedX, y: compact ? -104 : -132)
                }
            }

            if !compact { Text(time(timeline.duration)).frame(minWidth: 50, alignment: .leading) }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white.opacity(0.82))
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
            isHoveringTrack = false
            previewImage = nil
        }
        .onDisappear {
            scrubbing = false
            preview = nil
            hoverTime = nil
            isHoveringTrack = false
        }
        .help("\(time(timeline.position)) / \(time(timeline.duration)) · Click or drag to seek")
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
                let isFS = window.styleMask.contains(.fullScreen)
                model.fullScreen = isFS
                window.toolbar?.isVisible = !isFS
            }
        }
    }
    func makeNSView(context: Context) -> Probe { let probe = Probe(); probe.model = model; return probe }
    func updateNSView(_ nsView: Probe, context: Context) {}
}
