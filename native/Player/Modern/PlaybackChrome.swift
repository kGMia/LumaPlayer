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
    var scrimStrength: Double = 1
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if opaque || contrast == .increased {
            content.background(Color(nsColor: .windowBackgroundColor), in: shape)
        } else {
            let scrim = colorScheme == .light ? Color.white.opacity(0.18 * scrimStrength) : Color.black.opacity(0.28 * scrimStrength)
            content.background {
                shape
                    .fill(scrim)
                    .glassEffect(.regular, in: shape)
            }
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
                    .foregroundStyle(.primary)
            }
            Text(osd.text)
                .contentTransition(.numericText())
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
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

/// Adaptive semantic icon/label button style that never shifts tint when panel responder state changes.
private struct TransportButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 28, minHeight: 30)
            .foregroundStyle(.primary)
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
                    .fill(.primary.opacity(0.20))
                    .frame(height: barH)
                Capsule(style: .continuous)
                    .fill(.primary.opacity(0.9))
                    .frame(width: normalized > 0.001 ? fillW : 0, height: barH)
                if isHovering || isDragging {
                    Circle()
                        .fill(.primary)
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
                .foregroundStyle(.primary)
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
                Label("Previous Item", systemImage: "backward.end")
            }
            .disabled(!model.canPrevious)
            Button {
                model.nextFile()
            } label: {
                Label("Next Item", systemImage: "forward.end")
            }
            .disabled(!model.canNext)

            TimelineNavigationMenu(model: model)
            ABLoopMenu(model: model)
            if compact {
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                        Button("\(speed.formatted())×", systemImage: abs(model.speed - speed) < 0.01 ? "checkmark" : "speedometer") {
                            model.setSpeed(speed)
                        }
                    }
                } label: { Label("Playback Speed", systemImage: "speedometer") }
                Menu {
                    Toggle("Summary Card", isOn: $model.showSummaryCard)
                    Toggle("Video Information", isOn: $model.showVideoInfo)
                } label: { Label("Video Information", systemImage: model.hasAnyHUDCard ? "info.circle.fill" : "info.circle") }
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
            VideoGeometryControls(model: model)

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
                Picker("Primary Subtitles", selection: Binding(get: { !model.systemHDRActive && model.liveCaptionPlacement == "bottom" ? "live" : model.subtitleID }, set: { model.selectSubtitle($0, secondary: false) })) {
                    Text("Off").tag("no")
                    Label("Live Captions · Apple Speech", systemImage: "waveform").tag("live").disabled(model.systemHDRActive)
                    ForEach(model.subtitles) { Text($0.title).tag(String($0.id)) }
                }
                Picker(model.secondarySubtitlePosition == "below" ? String(localized: "Second Subtitles · Below") : String(localized: "Second Subtitles · Top"), selection: Binding(get: { !model.systemHDRActive && model.liveCaptionPlacement == "top" ? "live" : model.secondarySubtitleID }, set: { model.selectSubtitle($0, secondary: true) })) {
                    Text("Off").tag("no")
                    Label("Live Captions · Apple Speech", systemImage: "waveform").tag("live").disabled(model.systemHDRActive)
                    ForEach(model.subtitles) { Text($0.title).tag(String($0.id)) }
                }
                Picker("Second Subtitle Position", selection: $model.secondarySubtitlePosition) {
                    Text("Below Primary Subtitles").tag("below")
                    Text("Top of Video").tag("top")
                }
                if model.secondarySubtitlePosition == "below" {
                    Picker("Bilingual Subtitle Spacing", selection: $model.bilingualSubtitleSpacing) {
                        Text("Compact").tag("compact")
                        Text("Standard").tag("standard")
                    }
                }
                Divider()
                Menu("Subtitle Style") {
                    Picker("Subtitle Font", selection: $model.subtitleFont) {
                        ForEach(SubtitleAppearance.fontPresets) { preset in
                            Text(preset.title).tag(preset.id)
                        }
                    }
                    Picker("Primary Subtitle Size", selection: Binding(
                        get: { Int(model.subtitleFontSize.rounded()) },
                        set: { model.subtitleFontSize = Double($0) }
                    )) {
                        ForEach(SubtitleAppearance.sizePresets, id: \.self) { pt in
                            Text("\(pt) pt").tag(pt)
                        }
                    }
                    Picker("Primary Subtitle Color", selection: $model.subtitleColor) {
                        ForEach(SubtitleAppearance.colorPresets) { preset in
                            Text(preset.title).tag(preset.id)
                        }
                    }
                    Divider()
                    Picker("Second Subtitle Size", selection: Binding(
                        get: { Int(model.secondarySubtitleFontSize.rounded()) },
                        set: { model.secondarySubtitleFontSize = Double($0) }
                    )) {
                        ForEach(SubtitleAppearance.sizePresets, id: \.self) { pt in
                            Text("\(pt) pt").tag(pt)
                        }
                    }
                    Picker("Second Subtitle Color", selection: $model.secondarySubtitleColor) {
                        ForEach(SubtitleAppearance.colorPresets) { preset in
                            Text(preset.title).tag(preset.id)
                        }
                    }
                    Divider()
                    Toggle("Apply Style to ASS / Styled Subtitles", isOn: $model.subtitleOverrideASS)
                }
                Divider()
                Button("Load Subtitles…", systemImage: "doc.badge.plus") { model.openPanel(subtitle: true) }
                Button("Load Second Subtitles…", systemImage: "captions.bubble") { model.openPanel(subtitle: true, secondary: true) }
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
                .foregroundStyle(.primary)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Playback options")
    }
}

struct TransportMediaTitle: View {
    let title: String
    var artwork: NSImage? = nil
    var compact = false
    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: compact ? 5 : 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: compact ? 5 : 6, style: .continuous)
                            .strokeBorder(.primary.opacity(0.14), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
                    .frame(maxWidth: compact ? 42 : 56, maxHeight: compact ? 24 : 34)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
            Text(title)
                .font(compact ? .caption.weight(.medium) : .callout.weight(.medium))
                .foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Now Playing: \(title)"))
    }
}

/// Scope activity transitions to the message, never to the playback clock/slider.
private struct PlaybackProgressNotice: View {
    let message: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var delayedMessage: String?
    var body: some View {
        Group {
            if let delayedMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(delayedMessage).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }.transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: delayedMessage)
        .task(id: message) {
            guard let message else {
                delayedMessage = nil
                return
            }
            if delayedMessage != nil {
                delayedMessage = message
                return
            }
            do { try await Task.sleep(for: .milliseconds(280)) } catch { return }
            guard !Task.isCancelled else { return }
            delayedMessage = message
        }
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
            if !model.transportTitle.isEmpty {
                TransportMediaTitle(title: model.transportTitle, artwork: model.transportArtwork)
                    .onHover { model.transportTitleHovered = $0 }
                    .onDisappear { model.transportTitleHovered = false }
                    .transition(.opacity)
            }
            if let position = model.resumedFrom {
                HStack(spacing: 10) {
                    Label("Resumed from \(Duration.seconds(position).formatted(.time(pattern: position >= 3600 ? .hourMinuteSecond : .minuteSecond)))", systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Start Over", systemImage: "backward.end.fill") { model.startOverAfterResume() }
                        .buttonStyle(.bordered).controlSize(.small).disabled(!model.mediaSeekable)
                    Button { model.dismissResumeNotice() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("Dismiss resume message")
                }.transition(.opacity)
            }
            PlaybackProgressNotice(message: model.playbackActivity.progressMessage(
                paused: model.paused, retryAttempt: model.networkRetryAttempt))
            PlaybackTimeline(model: model, timeline: model.timeline, scrubbing: $scrubbing)
                .zIndex(20)
            // Keep a single set of popover anchors across width changes.
            transportControls(compact: transportWidth < 680)
                .zIndex(1)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if abs(transportWidth - width) > 1 { transportWidth = width }
        }
        .modifier(PlaybackGlass(cornerRadius: 24))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.transportTitle.isEmpty)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.transportArtwork != nil)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.resumedFrom != nil)
    }
    private func transportControls(compact: Bool) -> some View {
        let queueActive = model.queuePopover
        let settingsActive = settings || (model.inspector && !model.fullScreen && model.sidebarTab == "enhance")
        return HStack(spacing: compact ? 8 : 12) {
            Button { model.previousOrRestart() } label: { Image(systemName: "backward.end.fill").font(.callout) }
                .disabled(!model.hasActiveMediaSession && !model.canPrevious)
                .accessibilityLabel("Previous or Restart").help("Previous during the first 10 seconds or first quarter; otherwise restart (⌥⌘←)")
            Button { model.skip(-1) } label: { Image(systemName: "gobackward") }
                .disabled(!model.hasActiveMediaSession)
                .accessibilityLabel("Back \(Int(model.seekSeconds)) seconds").help("Back \(Int(model.seekSeconds)) seconds (←)")
            Button { model.togglePause() } label: { PlayerSymbol(name: model.paused ? "play.fill" : "pause.fill").font(.system(size: 21, weight: .semibold)).frame(width: 32) }
                .accessibilityLabel(model.paused ? "Play" : "Pause").help("Play / Pause (Space)")
            Button { model.skip(1) } label: { Image(systemName: "goforward") }
                .disabled(!model.hasActiveMediaSession)
                .accessibilityLabel("Forward \(Int(model.seekSeconds)) seconds").help("Forward \(Int(model.seekSeconds)) seconds (→)")
            Button { model.nextFile() } label: { Image(systemName: "forward.end.fill").font(.callout) }
                .disabled(!model.canNext)
                .accessibilityLabel("Next Item").help("Next video (⌥⌘→)")
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
            Button { model.quickSettings = false; model.queuePopover.toggle() } label: {
                Image(systemName: "list.bullet")
                    .opacity(queueActive ? 1.0 : 0.78)
            }
            .accessibilityLabel("Play Queue").help("Play Queue (⇧⌘P)")
            .popover(isPresented: $model.queuePopover, arrowEdge: .top) {
                QueueView(model: model, metadataActive: model.queuePopover)
                    .presentationBackground(.ultraThinMaterial)
                    .preferredColorScheme(model.effectiveChromeColorScheme)
            }
            if !compact {
            Menu {
                Toggle("Summary Card", isOn: $model.showSummaryCard)
                Toggle("Video Information", isOn: $model.showVideoInfo)
            } label: {
                PlayerSymbol(name: model.hasAnyHUDCard ? "info.circle.fill" : "info.circle")
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .opacity(model.hasAnyHUDCard ? 1.0 : 0.78)
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("Video information")
            .help("Video information (⌘I)")
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

/// Update real playback frames while dragging, with one final exact seek on release.
/// Uses a clean QuickTime-style minimalist white capsule bar and observes `PlayerTimelineState` independently.
struct PlaybackTimeline: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: PlayerModel
    let timeline: PlayerTimelineState
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
    @State private var lastShownPreviewTime: Double = 0
    @State private var lastShownPreviewRatio: CGFloat = 0
    private var limit: Double { timeline.duration.isFinite ? max(0.001, timeline.duration) : 1 }
    private func bounded(_ value: Double) -> Double { value.isFinite ? min(limit, max(0, value)) : 0 }
    private var activeValue: Double { bounded(preview ?? timeline.presentationPosition) }
    private var timeLabelWidth: CGFloat { timeline.duration >= 3600 ? (compact ? 64 : 76) : (compact ? 40 : 56) }
    private var showSeeking: Bool { delayedSeekID != nil && delayedSeekID == timeline.pendingSeek?.id && !scrubbing && model.playbackActivity == .seeking }
    private var progressRatio: CGFloat { CGFloat(min(1, max(0, activeValue / limit))) }
    private var activePreviewTime: Double? {
        guard model.path.hasPrefix("/"), model.showTimelinePreview, model.hasMotionVideo, model.loaded, timeline.duration > 0 else { return nil }
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
        let interactive = model.loaded && model.mediaSeekable && timeline.duration > 0
        let knobSize: CGFloat = compact ? 9 : 11
        let isShowingPreview = activePreviewTime != nil && sliderWidth > 16
        let displayTime = activePreviewTime ?? lastShownPreviewTime
        let displayRatio = activePreviewTime != nil ? (preview != nil ? CGFloat(bounded(displayTime) / limit) : hoverRatio) : lastShownPreviewRatio
        HStack(spacing: compact ? 6 : 10) {
            Text(time(activeValue))
                .frame(width: timeLabelWidth, alignment: .trailing)
                .accessibilityLabel("Playback time")

            GeometryReader { geometry in
                let trackWidth = max(0, geometry.size.width)
                let bubbleW: CGFloat = compact ? 132 : 172
                let rawX = displayRatio * trackWidth - bubbleW * 0.5
                let clampedX = min(max(0, rawX), max(0, trackWidth - bubbleW))
                ZStack(alignment: .leading) {
                    ChapterTrack(chapters: model.chapters, markers: model.markers,
                                 duration: limit, position: activeValue,
                                 hover: scrubbing ? activeValue : (isHoveringTrack ? Double(hoverRatio) * limit : nil),
                                 width: trackWidth, compact: compact)
                    ABLoopOverlay(loop: model.playbackGeometry, duration: limit, width: trackWidth)

                    if (isHoveringTrack || scrubbing || timeline.pendingSeek != nil) && interactive {
                        Circle()
                            .fill(.primary)
                            .frame(width: knobSize, height: knobSize)
                            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                            .offset(x: min(max(0, trackWidth * progressRatio - knobSize * 0.5), max(0, trackWidth - knobSize)))
                    }
                }
                .frame(width: trackWidth, height: compact ? 16 : 20, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityElement()
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(time(activeValue)) of \(time(timeline.duration))" + (timeline.pendingSeek == nil ? "" : ", seeking") + (model.playbackGeometry.hasLoopPoints ? ", " + model.playbackGeometry.loopDescription : ""))
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
                        lastShownPreviewRatio = ratio
                        if model.showTimelinePreview {
                            let target = bounded(Double(ratio) * limit)
                            hoverTime = target
                            lastShownPreviewTime = target
                        } else {
                            hoverTime = nil
                        }
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
                            lastShownPreviewRatio = ratio
                            let target = bounded(Double(ratio) * limit)
                            preview = target
                            lastShownPreviewTime = target
                            model.previewScrub(to: target, expectedPath: model.path)
                        }
                        .onEnded { gesture in
                            defer { dragPath = nil }
                            guard interactive, dragPath == model.path else {
                                if let dragPath { model.cancelScrubbing(for: dragPath) }
                                scrubbing = false; preview = nil; return
                            }
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
                    if trackWidth > 16 && (isShowingPreview || lastShownPreviewTime > 0) {
                        TimelinePreviewAboveTrack(x: clampedX) {
                            TimelinePreviewBubble(
                                image: previewImage,
                                timestamp: time(displayTime),
                                imageTimestamp: previewImageTime.map(time),
                                chapter: model.chapterTitle(at: displayTime),
                                status: previewStatus,
                                compact: compact
                            )
                            .frame(width: bubbleW)
                            .fixedSize(horizontal: false, vertical: true)
                            .opacity(isShowingPreview ? 1 : 0)
                            .scaleEffect(reduceMotion || isShowingPreview ? 1.0 : 0.90, anchor: .bottom)
                            .offset(y: reduceMotion || isShowingPreview ? 0 : 7)
                        }
                        .frame(width: trackWidth, height: 0, alignment: .topLeading)
                        .allowsHitTesting(false)
                        .zIndex(50)
                        .animation(reduceMotion ? nil : .snappy(duration: 0.18, extraBounce: 0), value: isShowingPreview)
                        // Follow the pointer directly; animate only bubble appearance, not every mouse event.
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
        .foregroundStyle(.secondary)
        .overlay(alignment: .topLeading) {
            if showSeeking {
                Label("Seeking…", systemImage: "clock")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: Capsule())
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
        .task(id: "\(model.path)|\(model.showTimelinePreview)|\(model.hasMotionVideo)|\(model.loaded)|\(model.sdr)") {
            guard model.showTimelinePreview, model.hasMotionVideo, model.loaded, model.path.hasPrefix("/") else { return }
            let path = model.path
            // Low-rate warming shares the same bounded thumbnail decode lane.
            var index = 0
            while !Task.isCancelled, path == model.path {
                // Do not launch speculative decoding during seek/model startup
                // or near the RIFE budget. Hover still uses the interactive lane.
                guard model.canPrewarmTimeline else {
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
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
            await model.timelinePreviews.noteInteraction()
            // The independent presentation task shows nearby cached frames
            // immediately. Only new decode requests wait for a stable bucket;
            // SwiftUI cancels this delay when the pointer moves or leaves.
            do { try await Task.sleep(for: .milliseconds(75)) }
            catch { return }
            guard !Task.isCancelled, path == model.path else { return }
            // Keep the previous image while decoding; the actual timestamp remains hidden.
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
            lastShownPreviewTime = 0; lastShownPreviewRatio = 0
        }
        .onDisappear {
            if let dragPath { model.cancelScrubbing(for: dragPath) }
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
        SystemPlaybackNotice(model: model)
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
            if model.sr != "off" {
                Toggle("Split-Screen SR Compare", isOn: $model.srCompare)
                    .disabled(!model.supportsSRComparison)
                Text("Compare bilinear source scaling with FSRCNNX Metal output. Both sides retain the current interpolation.")
                    .font(.caption).foregroundStyle(.secondary)
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
            LabeledContent("Super Resolution") {
                Text(model.srStatus).multilineTextAlignment(.trailing).textSelection(.enabled)
            }.font(.caption).foregroundStyle(.secondary)
            LabeledContent("Interpolation") {
                Text(model.fiStatus).multilineTextAlignment(.trailing).textSelection(.enabled)
            }.font(.caption).foregroundStyle(.secondary)
            Toggle("Performance Fallback", isOn: $model.automatic)
            Text("For a first try, choose RIFE Fast at 48 fps with Performance Fallback enabled. Unsupported sources are bypassed; check the status above.")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(model.systemHDRActive)
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
    }
}

/// The remaining AppKit bridge supplies the renderer's owning window and restores
/// its normal frame. Appearance, toolbar visibility and window roles belong to SwiftUI.
struct PlayerWindowBridge: NSViewRepresentable {
    let model: PlayerModel
    final class Probe: NSView {
        weak var model: PlayerModel?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Publish only after attachment. A probe can be detached/replaced before
            // this runs; never let that delayed callback bind the old window again.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window,
                      let model = self.model, model.window !== window else { return }
                if !window.styleMask.contains(.fullScreen) {
                    // Retain existing saved positions and AppKit's screen-aware restore.
                    window.setFrameUsingName("IIVE.MainWindow")
                    window.setFrameAutosaveName("IIVE.MainWindow")
                }
                model.window = window
                model.windowLifecycle.bind(to: window)
                model.fullScreen = window.styleMask.contains(.fullScreen)
            }
        }
    }
    func makeNSView(context: Context) -> Probe { let probe = Probe(); probe.model = model; return probe }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.model = model }
    static func dismantleNSView(_ nsView: Probe, coordinator: ()) {
        // Invalidate any queued attachment without interfering with window-close cleanup.
        nsView.model = nil
    }
}
