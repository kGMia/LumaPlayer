// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Local transitions only: video geometry and telemetry polling must never animate.
struct PlayerSymbol: View {
    let name: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if reduceMotion { Image(systemName: name) }
        else {
            Image(systemName: name)
                .contentTransition(.symbolEffect(.replace))
        }
    }
}

/// Use the system glass renderer; respect the system's transparency preference.
/// Do not attach `.interactive()` to the container background itself, otherwise clicking the
/// transport panel or dragging sliders triggers a container-wide press state that recolors child controls.
struct PlaybackGlass: ViewModifier {
    var cornerRadius: CGFloat = 24
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if opaque {
            content.background(Color(nsColor: .windowBackgroundColor), in: shape)
        } else {
            let scrim = colorScheme == .light ? Color.white.opacity(0.18) : Color.black.opacity(0.28)
            content.background(scrim, in: shape)
                .glassEffect(.regular, in: shape)
        }
    }
}

/// Top-right transient Liquid Glass OSD toast for volume, speed, mute, frame step, and enhancement changes.
struct OSDToastView: View {
    let osd: PlayerOSDState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 8) {
            if !osd.symbol.isEmpty {
                PlayerSymbol(name: osd.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(osd.text)
                .contentTransition(.numericText())
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .modifier(PlaybackGlass(cornerRadius: 18))
        .opacity(osd.visible && !osd.text.isEmpty ? 1 : 0)
        .scaleEffect(reduceMotion || (osd.visible && !osd.text.isEmpty) ? 1.0 : 0.94)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: osd.visible)
        .animation(reduceMotion ? nil : .smooth(duration: 0.16), value: osd.text)
        .allowsHitTesting(false)
        .accessibilityHidden(!osd.visible)
    }
}

/// Consistent white icon/label button style that never shifts tint when panel responder state changes.
private struct TransportButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 28, minHeight: 30)
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.65 : 1.0)
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.92 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// Minimalist QuickTime-style clean white capsule slider used for volume control.
struct CleanWhiteVolumeBar: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    @State private var isHovering = false
    @State private var isDragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering || isDragging)
            .accessibilityElement()
            .accessibilityValue("\(Int(value.rounded())) percent")
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 5.0 : -5.0
                value = min(range.upperBound, max(range.lowerBound, value + step))
            }
        }
        .frame(width: 72, height: 18)
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

/// Shared navigation content keeps chapters and user bookmarks together.
struct TimelineNavigationMenu: View {
    @ObservedObject var model: PlayerModel
    var body: some View {
        Menu {
            if !model.chapters.isEmpty {
                Section("Chapters") {
                    ForEach(model.chapters) { chapter in
                        Button { model.seek(chapter.time) } label: {
                            Label("\(FrameActions.timestamp(chapter.time)) · \(chapter.title)", systemImage: "text.book.closed")
                        }
                    }
                }
            }
            Section("Markers") {
                Button("Add Marker Here", systemImage: "bookmark.badge.plus") { model.frameActions.addMarker() }
                    .disabled(!model.loaded)
                ForEach(model.markers) { marker in
                    Button { model.seek(marker.time) } label: {
                        Label("\(FrameActions.timestamp(marker.time)) · \(marker.title)", systemImage: "bookmark.fill")
                    }
                }
            }
            if model.chapters.isEmpty && model.markers.isEmpty { Text("No chapters or markers") }
        } label: { Label("Chapters & Markers", systemImage: "bookmark") }
    }
}

/// Streamlined playback options menu; omits controls that already have dedicated buttons on the transport bar.
private struct PlaybackOptionsMenu: View {
    var compact = false
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var model: PlayerModel
    var body: some View {
        Menu {
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

            TimelineNavigationMenu(model: model)
            if compact {
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                        Button("\(speed.formatted())×", systemImage: abs(model.speed - speed) < 0.01 ? "checkmark" : "speedometer") {
                            model.setSpeed(speed)
                        }
                    }
                } label: { Label("Playback Speed", systemImage: "speedometer") }
                Toggle(isOn: $model.showVideoInfo) { Label("Video Information", systemImage: "info.circle") }
                Button("Mini Player", systemImage: "pip.enter") { model.toggleMiniPlayer() }
                    .disabled(model.windowTransition)
                Menu {
                    ForEach([0, 25, 50, 75, 100], id: \.self) { volume in
                        Button("\(volume)%") { model.setVolume(Double(volume), showOSD: true) }
                    }
                } label: { Label("Volume", systemImage: "speaker.wave.2") }
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
            Menu {
                Picker("Bottom", selection: Binding(get: { model.liveCaptionPlacement == "bottom" ? "live" : model.subtitleID }, set: { model.selectSubtitle($0, secondary: false) })) {
                    Text("Off").tag("no")
                    Label("Live Captions · Apple Speech", systemImage: "waveform").tag("live")
                    ForEach(model.subtitles) { Text($0.title).tag(String($0.id)) }
                }
                Picker("Top · Second Subtitles", selection: Binding(get: { model.liveCaptionPlacement == "top" ? "live" : model.secondarySubtitleID }, set: { model.selectSubtitle($0, secondary: true) })) {
                    Text("Off").tag("no")
                    Label("Live Captions · Apple Speech", systemImage: "waveform").tag("live")
                    ForEach(model.subtitles) { Text($0.title).tag(String($0.id)) }
                }
                Button("Load Subtitles…", systemImage: "doc.badge.plus") { model.openPanel(subtitle: true) }
            } label: { Label("Subtitles", systemImage: "captions.bubble") }

            Toggle(isOn: $model.showTimelinePreview) {
                Label("Timeline Hover Preview", systemImage: "photo.on.rectangle.angled")
            }

            Button {
                model.stepFrame()
            } label: {
                Label("Step Forward One Frame", systemImage: "forward.frame")
            }
            .disabled(!model.loaded)

            Button {
                model.saveScreenshot()
            } label: {
                Label("Save Screenshot", systemImage: "camera")
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: PlayerModel
    @Binding var scrubbing: Bool
    @Binding var settings: Bool
    @State private var transportWidth: CGFloat = 0
    var body: some View {
        VStack(spacing: 12) {
            if model.enhancementWarming {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(model.paused ? "Preparing enhancement · staying paused" : "Preparing enhancement…")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }
            PlaybackTimeline(model: model, timeline: model.timeline, scrubbing: $scrubbing)
            // Keep a single set of popover anchors across width changes.
            transportControls(compact: transportWidth < 680)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if abs(transportWidth - width) > 1 { transportWidth = width }
        }
        .modifier(PlaybackGlass(cornerRadius: 24))
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: model.enhancementWarming)
    }
    private func transportControls(compact: Bool) -> some View {
        let queueActive = model.queuePopover || (model.inspector && !model.fullScreen && model.sidebarTab == "queue")
        let settingsActive = settings || (model.inspector && !model.fullScreen && model.sidebarTab == "enhance")
        return HStack(spacing: compact ? 8 : 12) {
            Button { model.skip(-1) } label: { Image(systemName: "gobackward") }
                .accessibilityLabel("Back \(Int(model.seekSeconds)) seconds").help("Back \(Int(model.seekSeconds)) seconds (←)")
            Button { model.togglePause() } label: { PlayerSymbol(name: model.paused ? "play.fill" : "pause.fill").font(.system(size: 21, weight: .semibold)).frame(width: 32) }
                .accessibilityLabel(model.paused ? "Play" : "Pause").help("Play / Pause (Space)")
            Button { model.skip(1) } label: { Image(systemName: "goforward") }
                .accessibilityLabel("Forward \(Int(model.seekSeconds)) seconds").help("Forward \(Int(model.seekSeconds)) seconds (→)")
            if !compact { PlaybackSpeedMenu(model: model) }
            PlaybackOptionsMenu(compact: compact, model: model)
            Spacer(minLength: 0)
            Button { model.toggleMute() } label: {
                PlayerSymbol(name: model.muted || model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2").font(.callout)
            }.accessibilityLabel(model.muted ? "Unmute" : "Mute").help("Mute (M)")
            if !compact {
            CleanWhiteVolumeBar(
                value: Binding(get: { model.volume }, set: { model.setVolume($0, showOSD: true) }),
                range: 0...100
            )
            .accessibilityLabel("Volume")
            }
            Button { model.showSidebar("queue") } label: {
                Image(systemName: "list.bullet")
                    .opacity(queueActive ? 1.0 : 0.78)
            }
            .accessibilityLabel("Play Queue").help("Play Queue (⇧⌘P)")
            .popover(isPresented: $model.queuePopover, arrowEdge: .top) {
                QueueView(model: model)
                    .frame(width: 360, height: 420)
                    .background(Color.black.opacity(0.14))
                    .presentationBackground(.ultraThinMaterial)
                    .preferredColorScheme(model.effectiveChromeColorScheme)
            }
            if !compact {
            Button { model.showVideoInfo.toggle() } label: {
                PlayerSymbol(name: model.showVideoInfo ? "info.circle.fill" : "info.circle")
                    .opacity(model.showVideoInfo ? 1.0 : 0.78)
            }
            .accessibilityLabel("Video information").help("Video information (⌘I)")
            }
            Button { model.queuePopover = false; settings.toggle() } label: {
                Image(systemName: "slider.horizontal.3")
                    .opacity(settingsActive ? 1.0 : 0.78)
            }
            .accessibilityLabel("Quick settings").help("Enhancement settings")
            .popover(isPresented: $settings, arrowEdge: .top) {
                QuickEnhancementSettings(model: model)
                    .presentationBackground(.ultraThinMaterial)
                    .preferredColorScheme(model.effectiveChromeColorScheme)
            }
            if !compact {
            Button { model.toggleMiniPlayer() } label: { Image(systemName: model.miniPlayer ? "pip.exit" : "pip.enter") }
                .accessibilityLabel("Mini Player").help("Mini Player (⌥⌘P)")
                .disabled(model.windowTransition)
            }
            Button { model.toggleFullScreen() } label: { Image(systemName: model.fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                .accessibilityLabel(model.fullScreen ? "Exit Full Screen" : "Enter Full Screen").help("Full screen (⌃⌘F)")
        }
        .font(.title3)
        .buttonStyle(TransportButtonStyle())
        .focusEffectDisabled()
    }

}

/// Preview locally while dragging; send one exact seek on release. Shared by both window modes.
/// Uses a clean QuickTime-style minimalist white capsule bar and observes `PlayerTimelineState` independently.
struct PlaybackTimeline: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: PlayerModel
    @ObservedObject var timeline: PlayerTimelineState
    @Binding var scrubbing: Bool
    var compact = false
    @AppStorage("timelineShowsRemaining") private var showsRemaining = false
    @State private var delayedSeekID: String?
    @State private var dragPath: String?
    @State private var preview: Double?
    @State private var hoverTime: Double?
    @State private var hoverRatio = CGFloat(0)
    @State private var sliderWidth = CGFloat(0)
    @State private var isHoveringTrack = false
    @State private var previewImage: CGImage?
    @State private var previewImageTime: Double?
    @State private var previewStatus: String?
    @State private var stalePreviewSince: Double?
    private var limit: Double { timeline.duration.isFinite ? max(0.001, timeline.duration) : 1 }
    private func bounded(_ value: Double) -> Double { value.isFinite ? min(limit, max(0, value)) : 0 }
    private var activeValue: Double { bounded(preview ?? timeline.presentationPosition) }
    private var timeLabelWidth: CGFloat { timeline.duration >= 3600 ? (compact ? 64 : 76) : (compact ? 40 : 56) }
    private var showSeeking: Bool { delayedSeekID != nil && delayedSeekID == timeline.pendingSeek?.id && !scrubbing }
    private var progressRatio: CGFloat { CGFloat(min(1, max(0, activeValue / limit))) }
    private var activePreviewTime: Double? {
        guard model.showTimelinePreview, model.loaded, timeline.duration > 0 else { return nil }
        return preview ?? hoverTime
    }
    private var requestedPreviewTime: Double? {
        guard let target = activePreviewTime else { return nil }
        // Avoid requesting subpixel time differences on long movies.
        let step = max(0.5, min(4, timeline.duration / max(120, Double(sliderWidth))))
        return min(max(0, timeline.duration - 0.05), (target / step).rounded() * step)
    }
    private var previewBucketKey: String {
        guard let target = requestedPreviewTime, !model.path.isEmpty else { return "" }
        return "\(model.path)#\(Int((target * 2).rounded()))#sdr=\(model.sdr)"
    }
    var body: some View {
        let interactive = model.loaded && timeline.duration > 0
        let knobSize: CGFloat = compact ? 9 : 11
        HStack(spacing: compact ? 6 : 10) {
            Text(time(activeValue))
                .frame(width: timeLabelWidth, alignment: .trailing)
                .accessibilityLabel("Playback time")

            GeometryReader { geometry in
                let trackWidth = max(0, geometry.size.width)
                ZStack(alignment: .leading) {
                    ChapterTrack(chapters: model.chapters, markers: model.markers,
                                 duration: limit, position: activeValue,
                                 hover: scrubbing ? activeValue : (isHoveringTrack ? Double(hoverRatio) * limit : nil),
                                 width: trackWidth, compact: compact)

                    if (isHoveringTrack || scrubbing || timeline.pendingSeek != nil) && interactive {
                        Circle()
                            .fill(.white)
                            .frame(width: knobSize, height: knobSize)
                            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                            .offset(x: min(max(0, trackWidth * progressRatio - knobSize * 0.5), max(0, trackWidth - knobSize)))
                    }
                }
                .frame(width: trackWidth, height: compact ? 16 : 20, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityElement()
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(time(activeValue)) of \(time(timeline.duration))" + (timeline.pendingSeek == nil ? "" : ", seeking"))
                .accessibilityAdjustableAction { direction in
                    guard interactive else { return }
                    model.seek(bounded(timeline.presentationPosition + (direction == .increment ? model.seekSeconds : -model.seekSeconds)))
                }
                .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.width } action: { width in
                    if abs(sliderWidth - width) > 0.5 { sliderWidth = width }
                }
                .onContinuousHover { phase in
                    guard interactive, trackWidth > 8 else {
                        if isHoveringTrack { isHoveringTrack = false }
                        if hoverTime != nil { hoverTime = nil }
                        return
                    }
                    switch phase {
                    case .active(let location):
                        if !isHoveringTrack { isHoveringTrack = true }
                        let ratio = min(1, max(0, location.x / max(1, trackWidth)))
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
                            guard interactive, trackWidth > 8 else { return }
                            if dragPath == nil { dragPath = model.path }
                            guard dragPath == model.path else { return }
                            if !scrubbing { scrubbing = true }
                            let ratio = min(1, max(0, gesture.location.x / max(1, trackWidth)))
                            hoverRatio = ratio
                            preview = bounded(Double(ratio) * limit)
                        }
                        .onEnded { gesture in
                            defer { dragPath = nil }
                            guard interactive, dragPath == model.path else { scrubbing = false; preview = nil; return }
                            let ratio = min(1, max(0, gesture.location.x / max(1, trackWidth)))
                            let finalTime = bounded(Double(ratio) * limit)
                            // Establish the pending target before dropping the local
                            // drag preview, so no old decoder clock can flash through.
                            model.seek(bounded(finalTime))
                            scrubbing = false
                            preview = nil
                        }
                )
                .overlay(alignment: .topLeading) {
                    if let targetTime = activePreviewTime, trackWidth > 16 {
                        let bubbleW: CGFloat = compact ? 132 : 172
                        let ratio = preview != nil ? CGFloat(bounded(targetTime) / limit) : hoverRatio
                        let rawX = ratio * trackWidth - bubbleW * 0.5
                        let clampedX = min(max(0, rawX), max(0, trackWidth - bubbleW))
                        TimelinePreviewAboveTrack(x: clampedX) {
                            TimelinePreviewBubble(
                                image: previewImage,
                                timestamp: time(targetTime),
                                imageTimestamp: previewImageTime.map(time),
                                chapter: model.chapterTitle(at: targetTime),
                                status: previewStatus,
                                compact: compact
                            )
                            .frame(width: bubbleW)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(width: trackWidth, height: 0, alignment: .topLeading)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }
                }
            }
            .frame(height: compact ? 16 : 20)

            if !compact {
                Button { showsRemaining.toggle() } label: {
                    Text(showsRemaining ? "−" + time(max(0, timeline.duration - activeValue)) : time(timeline.duration))
                        .frame(width: timeLabelWidth, height: 24, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showsRemaining ? "Remaining time · Click to show duration" : "Duration · Click to show remaining time")
                .accessibilityLabel(showsRemaining ? "Remaining time" : "Duration")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white.opacity(0.82))
        .overlay(alignment: .topLeading) {
            if showSeeking {
                Label("Seeking…", systemImage: "clock")
                    .font(.caption2).foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.65), in: Capsule())
                    .offset(y: -25)
                    .allowsHitTesting(false)
            }
        }
        .task(id: timeline.pendingSeek?.id) {
            delayedSeekID = nil
            guard let request = timeline.pendingSeek else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, timeline.pendingSeek?.id == request.id else { return }
            delayedSeekID = request.id
        }
        .task(id: "\(model.path)|\(model.showTimelinePreview)|\(model.loaded)|\(model.sdr)") {
            guard model.showTimelinePreview, model.loaded, !model.path.isEmpty else { return }
            let path = model.path
            // Low-rate warming shares the same bounded thumbnail decode lane.
            var index = 0
            while !Task.isCancelled, path == model.path {
                let candidate = index == 0 ? timeline.position : timeline.duration * Double(index % 12) / 12
                await model.timelinePreviews.prewarm(for: path, at: max(0, candidate), allowSDRFallback: model.sdr)
                index += 1
                if index > 12 { break }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .task(id: previewBucketKey) {
            guard let target = requestedPreviewTime, !model.path.isEmpty else { return }
            let path = model.path
            // Keep the previous image while decoding. Its actual timestamp stays visible.
            let result = await model.timelinePreviews.thumbnail(for: path, at: target, allowSDRFallback: model.sdr)
            guard !Task.isCancelled, path == model.path else { return }
            if let result {
                previewImage = result.image; previewImageTime = result.seconds
                stalePreviewSince = nil; previewStatus = nil
            }
        }
        .task(id: previewBucketKey + "|presentation") {
            guard let target = requestedPreviewTime, !model.path.isEmpty else { return }
            let path = model.path
            // Key presentation to the same target as decoding. Only nearby cache
            // frames are usable; unrelated old images get a short transition grace.
            while !Task.isCancelled {
                let hit = await model.timelinePreviews.cached(for: path, at: target)
                let status = hit == nil ? await model.timelinePreviews.status(for: path, at: target) : nil
                guard !Task.isCancelled, path == model.path else { return }
                if let hit {
                    if previewImage !== hit.image || previewImageTime != hit.seconds {
                        previewImage = hit.image; previewImageTime = hit.seconds
                    }
                    if stalePreviewSince != nil { stalePreviewSince = nil }
                    if previewStatus != nil { previewStatus = nil }
                } else {
                    let now = ProcessInfo.processInfo.systemUptime
                    if previewImage != nil {
                        if stalePreviewSince == nil { stalePreviewSince = now }
                        if status != nil || now - (stalePreviewSince ?? now) >= 0.35 {
                            previewImage = nil; previewImageTime = nil
                        }
                    }
                    let message = status ?? (previewImage == nil ? "Preparing preview…" : "Updating preview…")
                    if previewStatus != message { previewStatus = message }
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
        .onChange(of: model.path) {
            scrubbing = false
            preview = nil
            hoverTime = nil
            isHoveringTrack = false
            previewImage = nil; previewImageTime = nil; previewStatus = nil; stalePreviewSince = nil
        }
        .onDisappear {
            dragPath = nil
            scrubbing = false
            preview = nil
            hoverTime = nil
            isHoveringTrack = false
        }
        .contextMenu { TimelineNavigationMenu(model: model) }
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
            if model.sr.hasPrefix("fsrcnnx") {
                Toggle("Split-Screen SR Compare", isOn: $model.srCompare)
                if model.srCompare {
                    HStack(spacing: 8) {
                        Text("Split").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $model.srSplitRatio, in: 0.05...0.95)
                        Text("\(Int((model.srSplitRatio * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
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
            Section("Appearance") {
                Picker("Controls Theme", selection: $model.chromeTheme) {
                    Text("Dark Glass").tag("dark")
                    Text("Adaptive to Video").tag("adaptive")
                    Text("System Theme").tag("system")
                }
                Toggle("Show Live Video Information", isOn: $model.showVideoInfo)
                Toggle("Show Timeline Hover Preview", isOn: $model.showTimelinePreview)
                SettingsLink { Label("Open Settings…", systemImage: "gearshape") }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.black.opacity(0.14))
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
                model.applyWindowAppearance()
                let isFS = window.styleMask.contains(.fullScreen)
                model.fullScreen = isFS
                window.toolbar?.isVisible = !isFS
            }
        }
    }
    func makeNSView(context: Context) -> Probe { let probe = Probe(); probe.model = model; return probe }
    func updateNSView(_ nsView: Probe, context: Context) {}
}
