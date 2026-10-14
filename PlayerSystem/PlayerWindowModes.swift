// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Combine

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
        let width = min(440.0, screen.width)
        let w = (model.source["dw"] as? NSNumber)?.doubleValue ?? 16
        let h = (model.source["dh"] as? NSNumber)?.doubleValue ?? 9
        let height = min(screen.height, max(260, width * h / max(1, w)))
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
        floating.minSize = NSSize(width: 320, height: 260)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            floating.standardWindowButton(button)?.isHidden = true
        }
        let host = NSView(frame: NSRect(origin: .zero, size: frame.size))
        floating.contentView = NSHostingView(rootView: MiniPlayerContent(model: model, host: host))
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
        guard let panel else { return }
        panel.level = model.miniAlwaysOnTop ? .floating : .normal
        panel.collectionBehavior = model.miniAllSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenAuxiliary]
    }
    /// Fade opacity only: avoid resizing the video or preparing enhancement graphs per animation frame.
    private func fade(_ model: PlayerModel, showing: NSWindow, hiding: NSWindow, completion: @escaping () -> Void) {
        let ticket = generation
        model.windowTransition = true
        let finish = { [weak self, weak model] in
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
        } completionHandler: { finish() }
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
        model.fullScreen = model.window?.styleMask.contains(.fullScreen) == true
        model.videoView?.finishWindowTransition()
        model.enhancementPlanResumeAt = ProcessInfo.processInfo.systemUptime + 0.5
        model.windowTransition = false
        let completion = fullScreenCompletion; fullScreenCompletion = nil
        completion?()
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
                .onTapGesture(count: 2) { model.windowModes.restore(model) }
            MiniTransport(model: model, scrubbing: $scrubbing) { hovering in
                if hoveringControls != hovering { hoveringControls = hovering }
                reveal()
            }.opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible).accessibilityHidden(!controlsVisible)
        }.ignoresSafeArea().environment(\.colorScheme, .dark)
            .onContinuousHover { phase in if case .active = phase { reveal() } }
            .onChange(of: model.paused) { reveal() }
            .onChange(of: model.path) { reveal() }
            .onChange(of: model.autoHideControls) { reveal() }
            .onReceive(timer) { now in
                if controlsVisible && !model.menuTracking && !model.systemMenuTracking && model.autoHideControls && model.loaded && !model.paused && !scrubbing && !hoveringControls && now.timeIntervalSince(activity.last) > model.controlsHideDelay {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { controlsVisible = false }
                }
            }
            .onExitCommand { model.windowModes.restore(model) }
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty else { return false }; model.openFiles(urls); return true
            }
    }
    private func reveal() {
        activity.last = Date()
        if !controlsVisible {
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.15)) { controlsVisible = true }
        }
    }
}

extension PlayerModel {
    func toggleMiniPlayer() { windowModes.toggle(self) }
    func showSidebar(_ tab: String) {
        if miniPlayer {
            windowModes.restore(self) { [weak self] in self?.showSidebar(tab) }
            return
        }
        sidebarTab = tab
        if fullScreen {
            inspector = false
            if tab == "queue" { quickSettings = false; queuePopover.toggle() }
            else { queuePopover = false; quickSettings.toggle() }
        } else {
            inspector = true
        }
    }
}

struct MiniGlassButton: View {
    let symbol: String
    let title: String
    var diameter: CGFloat = 40
    var symbolSize: CGFloat = 16
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(.white)
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
                VStack(spacing: 5) {
                    Text(model.title).font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 10) {
                        PlaybackTimeline(model: model, scrubbing: $scrubbing, compact: true)
                        MiniGlassButton(symbol: model.muted ? "speaker.slash" : "speaker.wave.2",
                                        title: model.muted ? "Unmute" : "Mute") { model.toggleMute() }
                    }
                }.padding(10).background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
                    .onHover(perform: onControlHover)
            }
            // Separate circles, deliberately no shared glass capsule or merging container.
            HStack(spacing: 16) {
                MiniGlassButton(symbol: "backward.fill", title: "Back \(Int(model.seekSeconds)) seconds",
                                diameter: 48, symbolSize: 18) { model.skip(-1) }
                MiniGlassButton(symbol: model.paused ? "play.fill" : "pause.fill", title: model.paused ? "Play" : "Pause",
                                diameter: 64, symbolSize: 26) { model.togglePause() }
                MiniGlassButton(symbol: "forward.fill", title: "Forward \(Int(model.seekSeconds)) seconds",
                                diameter: 48, symbolSize: 18) { model.skip(1) }
            }.onHover(perform: onControlHover)
        }.padding(12)
    }
}

/// One system segmented selector, not independently styled buttons.
struct SidebarTabs: View {
    @ObservedObject var model: PlayerModel
    var body: some View {
        Picker("Panel", selection: $model.sidebarTab) {
            Label("Queue", systemImage: "list.bullet").tag("queue")
            Label("Enhancement", systemImage: "slider.horizontal.3").tag("enhance")
            Label("Information", systemImage: "info.circle").tag("info")
        }.pickerStyle(.segmented).labelsHidden().labelStyle(.iconOnly)
            .controlSize(.large)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, 12).padding(.vertical, 10)
    }
}
struct PlayerSidebar: View {
    @ObservedObject var model: PlayerModel
    var body: some View {
        VStack(spacing: 0) {
            SidebarTabs(model: model)
            switch model.sidebarTab {
            case "enhance": EnhancementInspector(model: model)
            case "info":
                Form { Section("Video Information") { VideoInformationRows(model: model) } }
                    .formStyle(.grouped).scrollContentBackground(.hidden)
            default: QueueView(model: model)
            }
        }.background(.ultraThinMaterial)
    }
}
