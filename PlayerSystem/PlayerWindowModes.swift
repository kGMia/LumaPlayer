// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Combine

/// Hidden sidebar pages retain their SwiftUI state without subscribing to player broadcasts.
@MainActor final class SidebarModelObservation: ObservableObject {
    @Published private var revision: UInt64 = 0
    private var subscription: AnyCancellable?

    func update(_ model: PlayerModel, active: Bool) {
        subscription = nil
        guard active else { return }
        subscription = model.objectWillChange.sink { [weak self] _ in
            self?.revision &+= 1
        }
    }
    func stop() { subscription = nil }
}

/// A public AppKit panel hosting the existing renderer; the main window is hidden, not destroyed.
@MainActor final class PlayerWindowModes: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    // AppKit's last-window termination check does not count floating panels.
    // Keep this true through restore animation, even after miniPlayer becomes false.
    var hasMiniPlayerWindow: Bool { panel != nil }
    private weak var owner: PlayerModel?
    private var generation = 0
    private var fullScreenTransition = false
    private var fullScreenCompletion: (() -> Void)?
    private var inspectorBeforeFullScreen: Bool?

    func toggle(_ model: PlayerModel) {
        guard !model.windowTransition else { return }
        if model.miniPlayer { restore(model); return }
        if model.window?.styleMask.contains(.fullScreen) == true {
            toggleFullScreen(model) { [weak self, weak model] in
                guard let self, let model, model.window?.styleMask.contains(.fullScreen) == false else { return }
                self.toggle(model)
            }
            return
        }
        guard let main = model.window, model.videoView != nil, model.mainVideoHost != nil else { return }
        owner = model
        let screen = main.screen?.visibleFrame ?? main.frame
        let width = min(model.audioOnly ? 280.0 : 340.0, screen.width)
        let (w, h) = effectiveVideoDimensions(model)
        let height = min(screen.height, max(model.audioOnly ? 260 : 150, (width * h / max(1, w)).rounded()))
        let frame = NSRect(x: screen.maxX - width - 20, y: screen.minY + 20, width: width, height: height)
        let floating = NSPanel(contentRect: frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        floating.title = "Mini Player"
        floating.titleVisibility = .hidden
        floating.titlebarAppearsTransparent = true
        floating.titlebarSeparatorStyle = .none
        floating.backgroundColor = .black
        floating.isFloatingPanel = true
        floating.hidesOnDeactivate = false
        floating.isReleasedWhenClosed = false
        floating.isMovableByWindowBackground = true
        floating.minSize = model.audioOnly ? NSSize(width: 220, height: 220) : NSSize(width: 240, height: 135)
        if !model.audioOnly && model.hasMotionVideo {
            floating.contentAspectRatio = NSSize(width: max(1, w.rounded()), height: max(1, h.rounded()))
        }
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            floating.standardWindowButton(button)?.isHidden = true
        }
        let host = NSView(frame: NSRect(origin: .zero, size: frame.size))
        floating.contentView = NSHostingView(rootView: MiniPlayerContent(model: model, host: host)
            .playerFileDialogs(model.fileDialogs, host: .mini))
        floating.delegate = self
        panel = floating
        updatePolicy(model)
        transition(model, completion: { [weak self] in
            self?.fade(model, showing: floating, hiding: main) { main.orderOut(nil); main.alphaValue = 1 }
        }) { [weak self] in
            guard let self, let view = model.videoView else { return }
            floating.contentView?.layoutSubtreeIfNeeded()
            self.move(view, to: host)
            model.queuePopover = false; model.quickSettings = false
            model.miniPlayer = true
            floating.alphaValue = 0
            floating.makeKeyAndOrderFront(nil)
            floating.contentView?.layoutSubtreeIfNeeded()
        }
    }
    /// Drain any in-flight GL draw asynchronously before changing its AppKit drawable.
    private func transition(_ model: PlayerModel, completion: (() -> Void)? = nil, change: @escaping () -> Void) {
        guard !model.windowTransition else { return }
        generation += 1
        let ticket = generation
        model.windowTransition = true
        let changeWindow = { [weak self, weak model] in
            guard let self, let model, self.generation == ticket else { return }
            change()
            model.videoView?.finishWindowTransition()
            if model.colorProfile == "display" { model.applyColorProfile() }
            model.enhancementPlanResumeAt = ProcessInfo.processInfo.systemUptime + 0.35
            model.windowTransition = false
            completion?()
        }
        if let view = model.videoView { view.prepare(forWindowTransition: changeWindow) }
        else { changeWindow() }
    }
    private func move(_ view: VideoView, to host: NSView) {
        view.removeFromSuperview()
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
        host.layoutSubtreeIfNeeded()
    }
    func updatePolicy(_ model: PlayerModel) {
        updateMainWindowLevel(model)
        guard let panel else { return }
        panel.level = model.miniAlwaysOnTop ? .floating : .normal
        panel.collectionBehavior = model.miniAllSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenAuxiliary]
        model.applyMiniWindowAppearance()
    }
    func updateMainWindowLevel(_ model: PlayerModel) {
        guard let window = model.window else { return }
        let shouldFloat = model.mainWindowFloatOnTop && !model.fullScreen && !model.miniPlayer
        let desiredLevel: NSWindow.Level = shouldFloat ? .floating : .normal
        if window.level != desiredLevel {
            window.level = desiredLevel
        }
    }
    /// Smoothly adapts the mini player geometry to the current video's aspect ratio.
    func updateMediaAspect(_ model: PlayerModel) {
        guard let panel, model.miniPlayer, !model.windowTransition else { return }
        let screen = panel.screen?.visibleFrame ?? panel.frame
        let current = panel.frame
        let baseWidth = model.audioOnly ? 280.0 : max(240.0, min(current.width, screen.width * 0.85))
        let targetWidth = min(baseWidth, screen.width)
        let (w, h) = effectiveVideoDimensions(model)
        let targetHeight = min(screen.height, max(model.audioOnly ? 260.0 : 150.0, (targetWidth * h / max(1, w)).rounded()))
        panel.minSize = model.audioOnly ? NSSize(width: 220, height: 220) : NSSize(width: 240, height: 135)
        if !model.audioOnly && model.hasMotionVideo {
            panel.contentAspectRatio = NSSize(width: max(1, w.rounded()), height: max(1, h.rounded()))
        } else {
            panel.resizeIncrements = NSSize(width: 1, height: 1)
        }
        if abs(current.width - targetWidth) > 4 || abs(current.height - targetHeight) > 4 {
            let newOriginX = min(max(screen.minX, current.maxX - targetWidth), screen.maxX - targetWidth)
            let newOriginY = min(max(screen.minY, current.minY), screen.maxY - targetHeight)
            panel.setFrame(NSRect(x: newOriginX, y: newOriginY, width: targetWidth, height: targetHeight), display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
    }
    func effectiveVideoDimensions(_ model: PlayerModel) -> (Double, Double) {
        if model.audioOnly || !model.hasMotionVideo { return (1.0, 1.0) }
        var w = (model.source["dw"] as? NSNumber)?.doubleValue ?? (model.source["w"] as? NSNumber)?.doubleValue ?? 16.0
        var h = (model.source["dh"] as? NSNumber)?.doubleValue ?? (model.source["h"] as? NSNumber)?.doubleValue ?? 9.0
        if w <= 0 || h <= 0 || !w.isFinite || !h.isFinite { w = 16.0; h = 9.0 }
        let rot = ((model.rotation % 360) + 360) % 360
        if rot == 90 || rot == 270 { swap(&w, &h) }
        if !model.playbackGeometry.crop.isEmpty, let ratio = VideoRatio.number(model.playbackGeometry.crop), ratio.isFinite, ratio > 0 {
            return (ratio * 1000.0, 1000.0)
        }
        if model.playbackGeometry.aspect != "no", let ratio = VideoRatio.number(model.playbackGeometry.aspect), ratio.isFinite, ratio > 0 {
            return (ratio * 1000.0, 1000.0)
        }
        return (w, h)
    }
    func applyAppearance(_ appearance: NSAppearance?) {
        panel?.appearance = appearance
    }
    /// Fade opacity only: avoid resizing the video or preparing enhancement graphs per animation frame.
    private func fade(_ model: PlayerModel, showing: NSWindow, hiding: NSWindow, completion: @escaping () -> Void) {
        let ticket = generation
        model.windowTransition = true
        let finish: @MainActor () -> Void = { [weak self, weak model] in
            guard let self, let model, self.generation == ticket else { return }
            showing.alphaValue = 1
            completion()
            model.enhancementPlanResumeAt = ProcessInfo.processInfo.systemUptime + 0.35
            model.windowTransition = false
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            hiding.alphaValue = 0; finish(); return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            showing.animator().alphaValue = 1
            hiding.animator().alphaValue = 0
        } completionHandler: { Task { @MainActor in finish() } }
    }
    func restore(_ model: PlayerModel, completion: (() -> Void)? = nil) {
        guard let floating = panel, let main = model.window, !model.windowTransition else { return }
        transition(model, completion: { [weak self] in
            self?.fade(model, showing: main, hiding: floating) { [weak self] in
                self?.dismissPanel()
                // A follow-on fullscreen action must see the finished transition state.
                DispatchQueue.main.async { completion?() }
            }
        }) { [weak self] in
            guard let self else { return }
            main.alphaValue = 0
            main.makeKeyAndOrderFront(nil)
            main.contentView?.layoutSubtreeIfNeeded()
            if let view = model.videoView, let host = model.mainVideoHost { self.move(view, to: host) }
            model.miniPlayer = false
            self.updateMainWindowLevel(model)
        }
    }
    func toggleFullScreen(_ model: PlayerModel, completion: (() -> Void)? = nil) {
        guard !model.windowTransition, let window = model.window else { return }
        if model.miniPlayer {
            restore(model) { [weak self, weak model] in
                guard let self, let model else { return }; self.toggleFullScreen(model, completion: completion)
            }
            return
        }
        beginFullScreen(model)
        fullScreenCompletion = completion
        let ticket = generation
        let toggle = { [weak self, weak model, weak window] in
            guard let self, let model, let window, self.generation == ticket, self.fullScreenTransition else { return }
            model.queuePopover = false; model.quickSettings = false
            window.toggleFullScreen(nil)
        }
        if let view = model.videoView { view.prepare(forWindowTransition: toggle) } else { toggle() }
    }
    /// Also covers the system green titlebar button without replacing SwiftUI's window delegate.
    func beginFullScreen(_ model: PlayerModel) {
        guard !fullScreenTransition else { return }
        generation += 1
        let ticket = generation
        fullScreenTransition = true
        // Keep the pre-fullscreen sidebar preference through success, cancellation
        // and the timeout fallback, without depending on SwiftUI view-local state.
        if model.window?.styleMask.contains(.fullScreen) == false, inspectorBeforeFullScreen == nil {
            inspectorBeforeFullScreen = model.inspector
        }
        model.queuePopover = false; model.quickSettings = false
        model.windowTransition = true
        model.videoView?.prepare(forWindowTransition: {})
        // Recover if AppKit rejects/cancels a fullscreen request and sends no did notification.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak model] in
            guard let self, let model, self.generation == ticket, self.fullScreenTransition else { return }
            self.finishFullScreen(model)
        }
    }
    func finishFullScreen(_ model: PlayerModel) {
        guard fullScreenTransition else { return }
        fullScreenTransition = false
        let isFS = model.window?.styleMask.contains(.fullScreen) == true
        model.fullScreen = isFS
        updateMainWindowLevel(model)
        if !isFS { restoreInspector(model) }
        model.videoView?.finishWindowTransition()
        model.enhancementPlanResumeAt = ProcessInfo.processInfo.systemUptime + 0.5
        model.windowTransition = false
        let completion = fullScreenCompletion; fullScreenCompletion = nil
        completion?()
    }
    private func restoreInspector(_ model: PlayerModel) {
        guard let previous = inspectorBeforeFullScreen else { return }
        inspectorBeforeFullScreen = nil
        if model.inspector != previous { model.inspector = previous }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === panel, let owner else { return true }
        restore(owner)
        return false
    }
    private func dismissPanel() {
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        owner = nil
    }
    /// Resume render callbacks before draining mpv commands during shutdown.
    func prepareForShutdown(_ model: PlayerModel) {
        generation += 1
        fullScreenTransition = false; fullScreenCompletion = nil
        restoreInspector(model)
        model.window?.alphaValue = 1
        if model.windowTransition { model.videoView?.finishWindowTransition() }
        model.windowTransition = false
    }
    /// Called after the renderer stops, so teardown never reparents a drawing context.
    func resetAfterClose(_ model: PlayerModel) {
        generation += 1
        if let view = model.videoView, let host = model.mainVideoHost, view.superview !== host { move(view, to: host) }
        dismissPanel()
        model.miniPlayer = false; model.windowTransition = false
    }
}

private struct MiniVideoSurface: NSViewRepresentable {
    let host: NSView
    func makeNSView(context: Context) -> NSView { host }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
private struct MiniPlayerContent: View {
    @ObservedObject var model: PlayerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let host: NSView
    @State private var scrubbing = false
    @State private var controlsVisible = true
    @State private var hoveringControls = false
    @State private var activity = ActivityTracker()
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    var body: some View {
        ZStack {
            Color.black
            MiniVideoSurface(host: host)
            if model.systemHDRActive && model.miniPlayer, let player = model.systemHDRPlayback.player {
                SystemHDRSurface(player: player)
            }
            if model.audioOnly && (model.loaded || model.mediaSwitch.active) {
                AudioArtworkView(artwork: model.audioArtwork, title: model.title,
                                 artist: model.audioArtist, album: model.audioAlbum, compact: true)
            }
            Group {
                if model.mediaSwitch.active {
                    MediaLoadingOverlay(message: "Loading…", compact: true).transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: model.mediaSwitch.active)
            if !model.systemHDRActive && model.liveCaptionPlacement != "off" {
                LiveCaptionOverlay(model: model, captions: model.liveCaptions, compact: true)
            }
            MiniTransport(model: model, scrubbing: $scrubbing) { hovering in
                if hoveringControls != hovering { hoveringControls = hovering }
                if hovering { activity.last = Date() }
            }.opacity(controlsVisible ? 1 : 0)
                .offset(y: reduceMotion || controlsVisible ? 0 : 6)
                .allowsHitTesting(controlsVisible).accessibilityHidden(!controlsVisible)
            VStack {
                OSDToastView(osd: model.osd)
                    .padding(.top, 8)
                Spacer(minLength: 0)
            }
        }
        .overlay {
            if model.frameActions.textSession.capture != nil {
                LiveTextWindow(session: model.frameActions.textSession)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(model.effectiveChromeColorScheme)
        .onAppear {
            model.onMiniCanvasSingleClick = { toggleControls() }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let height = max(host.bounds.height, 1)
                if activity.shouldRevealOnHover(at: location, canvasHeight: height, controlsVisible: controlsVisible) {
                    reveal()
                }
            case .ended:
                activity.resetHover()
            }
        }
        .onChange(of: model.paused) { reveal() }
        .onChange(of: model.enhancementWarming) { reveal() }
        .onChange(of: model.path) { reveal() }
        .onChange(of: model.transportTitle) { if !model.transportTitle.isEmpty { reveal() } }
        .onChange(of: model.autoHideControls) { reveal() }
        .onReceive(timer) { now in
            guard controlsVisible && model.autoHideControls && model.loaded && !model.paused else { return }
            if !model.isMenuTracking && model.transportTitle.isEmpty && !model.enhancementWarming && model.timeline.pendingSeek == nil && !scrubbing && !hoveringControls && now.timeIntervalSince(activity.last) > model.controlsHideDelay {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { controlsVisible = false }
                activity.updateCursorVisibility(controlsVisible: false, canHideCursor: !hoveringControls)
            }
        }
        .onExitCommand { model.windowModes.restore(model) }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }; model.openFiles(urls); return true
        }
    }
    private func reveal() {
        activity.last = Date()
        NSCursor.setHiddenUntilMouseMoves(false)
        if !controlsVisible {
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.15)) { controlsVisible = true }
        }
    }
    private func toggleControls() {
        let nextVisible = !controlsVisible
        activity.recordManualToggle(hiding: controlsVisible)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            controlsVisible = nextVisible
        }
        activity.updateCursorVisibility(controlsVisible: nextVisible, canHideCursor: !hoveringControls)
    }
}

extension PlayerModel {
    func toggleMiniPlayer() { windowModes.toggle(self) }
    func showFileBrowser() {
        if miniPlayer {
            windowModes.restore(self) { [weak self] in self?.showFileBrowser() }
            return
        }
        sidebarTab = "queue"
        quickSettings = false
        queuePopover = false
        inspector = true
    }
    func showSidebar(_ tab: String) {
        if miniPlayer {
            windowModes.restore(self) { [weak self] in self?.showSidebar(tab) }
            return
        }
        if tab == "queue" {
            quickSettings = false; queuePopover.toggle()
            return
        }
        sidebarTab = tab
        quickSettings = false
        queuePopover = false
        inspector = true
    }
}

struct MiniGlassButton: View {
    let symbol: String
    let title: LocalizedStringKey
    var diameter: CGFloat = 30
    var symbolSize: CGFloat = 13
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            PlayerSymbol(name: symbol).font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: diameter, height: diameter).contentShape(Circle())
        }.buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel(title).help(title)
    }
}
struct MiniTransport: View {
    @ObservedObject var model: PlayerModel
    @Binding var scrubbing: Bool
    var onControlHover: (Bool) -> Void
    var body: some View {
        ZStack {
            VStack {
                HStack {
                    MiniGlassButton(symbol: "xmark", title: "Close Mini Player and Return to Main Window") { model.windowModes.restore(model) }
                        .disabled(model.windowTransition)
                    Spacer()
                    MiniGlassButton(symbol: "pip.exit", title: "Restore Player (Esc)") { model.toggleMiniPlayer() }
                        .disabled(model.windowTransition)
                }.onHover(perform: onControlHover)
                Spacer()
                VStack(spacing: 4) {
                    if !model.transportTitle.isEmpty {
                        TransportMediaTitle(title: model.transportTitle, artwork: model.transportArtwork, compact: true)
                            .onHover { model.transportTitleHovered = $0 }
                            .onDisappear { model.transportTitleHovered = false }
                    }
                    HStack(spacing: 8) {
                        PlaybackTimeline(model: model, timeline: model.timeline, scrubbing: $scrubbing, compact: true)
                        MiniGlassButton(symbol: model.muted ? "speaker.slash" : "speaker.wave.2",
                                        title: model.muted ? "Unmute" : "Mute", diameter: 26, symbolSize: 11) { model.toggleMute() }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .modifier(PlaybackGlass(cornerRadius: 16))
                .onHover(perform: onControlHover)
            }
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    MiniGlassButton(symbol: "backward.end.fill", title: "Restart or Previous Item (⌥⌘←)",
                                    diameter: 30, symbolSize: 11) { model.previousOrRestart() }
                        .disabled(!model.hasActiveMediaSession && !model.canPrevious)
                    MiniGlassButton(symbol: "backward.fill", title: "Back \(Int(model.seekSeconds)) seconds",
                                    diameter: 36, symbolSize: 14) { model.skip(-1) }
                        .disabled(!model.hasActiveMediaSession)
                    MiniGlassButton(symbol: model.paused ? "play.fill" : "pause.fill", title: model.paused ? "Play" : "Pause",
                                    diameter: 48, symbolSize: 20) { model.togglePause() }
                    MiniGlassButton(symbol: "forward.fill", title: "Forward \(Int(model.seekSeconds)) seconds",
                                    diameter: 36, symbolSize: 14) { model.skip(1) }
                        .disabled(!model.hasActiveMediaSession)
                    MiniGlassButton(symbol: "forward.end.fill", title: "Next Item (⌥⌘→)",
                                    diameter: 30, symbolSize: 11) { model.nextFile() }
                        .disabled(!model.canNext)
                }
            }
            .onHover(perform: onControlHover)
        }.padding(10)
    }
}

struct SidebarTabs: View {
    @ObservedObject var model: PlayerModel
    private let tabs: [(id: String, title: String, symbol: String)] = [
        ("queue", String(localized: "Files"), "folder"),
        ("enhance", String(localized: "Enhancement"), "slider.horizontal.3"),
        ("info", String(localized: "Information"), "info.circle")
    ]
    var body: some View {
        Picker("Sidebar Section", selection: $model.sidebarTab) {
            ForEach(tabs, id: \.id) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(tab.id)
            }
        }
            .labelsHidden()
            .pickerStyle(.tabs)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }
}

struct PlayerSidebar: View {
    @ObservedObject var model: PlayerModel
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 0) {
            SidebarTabs(model: model)
            Divider()
            // Keep all 3 tab views alive in a persistent ZStack so switching tabs never
            // tears down or recreates AppKit NSScrollView/NSTableView instances (eliminating white/black flashes).
            ZStack {
                LocalMediaBrowser(model: model, active: active && model.sidebarTab == "queue")
                    .opacity(model.sidebarTab == "queue" ? 1 : 0)
                    .allowsHitTesting(model.sidebarTab == "queue")
                    .accessibilityHidden(model.sidebarTab != "queue")

                EnhancementInspector(model: model, active: active && model.sidebarTab == "enhance")
                    .opacity(model.sidebarTab == "enhance" ? 1 : 0)
                    .allowsHitTesting(model.sidebarTab == "enhance")
                    .accessibilityHidden(model.sidebarTab != "enhance")

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VideoInformationMetadataSections(model: model, active: active && model.sidebarTab == "info")
                        InformationSectionCard("Video Information") {
                            VStack(alignment: .leading, spacing: 8) {
                                VideoInformationRows(model: model, active: active && model.sidebarTab == "info")
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(12)
                }
                .opacity(model.sidebarTab == "info" ? 1 : 0)
                .allowsHitTesting(model.sidebarTab == "info")
                .accessibilityHidden(model.sidebarTab != "info")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: model.sidebarTab)
        }
        .modifier(PlaybackGlass(cornerRadius: 20, scrimStrength: 0.45))
        // Clip once at the panel boundary, never at individual file rows.
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.38), radius: 18, x: -4, y: 6)
        .preferredColorScheme(model.effectiveChromeColorScheme)
    }
}
