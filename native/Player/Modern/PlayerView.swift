// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Combine

struct VideoSurface: NSViewRepresentable {
    @ObservedObject var model: PlayerModel
    func makeNSView(context: Context) -> NSView {
        let host = NSView(frame: .zero)
        let view = VideoView(frame: host.bounds)
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
        model.mainVideoHost = host
        DispatchQueue.main.async { model.attach(view) }
        return host
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
struct PlayerView: View {
    @ObservedObject var model: PlayerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @State private var scrubbing = false
    @State private var inspectorBeforeFullScreen = false
    @State private var hoveringControls = false
    @State private var controlsVisible = true
    @State private var lastActivity = Date()
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(model: model)
                .ignoresSafeArea()
                .onTapGesture(count: 2) { model.handleDoubleClick() }
            if model.miniPlayer {
                ContentUnavailableView {
                    Label("Playing in Mini Player", systemImage: "pip")
                } description: {
                    Text("Playback continues in the floating window. Queue and settings remain available here.")
                } actions: {
                    Button("Return Video to This Window") { model.windowModes.restore(model) }
                        .disabled(model.windowTransition)
                }.foregroundStyle(.white)
            } else if !model.loaded {
                ContentUnavailableView {
                    Label("A better view", systemImage: "play.rectangle")
                } description: {
                    Text("Drop a video here, or open a file to begin.")
                } actions: {
                    Button("Open Video…") { model.openPanel() }.buttonStyle(.borderedProminent)
                }.foregroundStyle(.white)
            }
            GlassEffectContainer(spacing: 20) {
                VStack {
                    if model.showVideoInfo && model.loaded && !model.miniPlayer {
                        HStack { VideoInformationHUD(model: model); Spacer(minLength: 0) }
                    }
                    Spacer()
                    if model.loaded {
                        FloatingTransport(model: model, scrubbing: $scrubbing, settings: $model.quickSettings)
                        .frame(maxWidth: 780)
                        .onHover { hoveringControls = $0; revealControls() }
                        .opacity(controlsVisible ? 1 : 0)
                        .allowsHitTesting(controlsVisible)
                        .accessibilityHidden(!controlsVisible)
                    }
                }.padding(model.miniPlayer ? 10 : 20)
            }.environment(\.colorScheme, .dark)
        }
        .frame(minWidth: 580, minHeight: 340)
        .ignoresSafeArea(.container, edges: model.fullScreen ? .all : [])
        .background(PlayerWindowReader(model: model).frame(width: 0, height: 0))
        .onContinuousHover { phase in if case .active = phase { revealControls() } }
        .onReceive(timer) { now in
            if !model.menuTracking && model.autoHideControls && model.loaded && !model.paused && !scrubbing && !model.quickSettings && !model.queuePopover && !hoveringControls && now.timeIntervalSince(lastActivity) > model.controlsHideDelay {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { controlsVisible = false }
            }
        }
        .onChange(of: model.miniPlayer) { scrubbing = false; hoveringControls = false; revealControls() }
        .onChange(of: model.autoHideControls) { revealControls() }
        .onChange(of: model.paused) { revealControls() }
        .onChange(of: model.path) { revealControls() }
        .onChange(of: model.quickSettings) { revealControls() }
        .onChange(of: model.queuePopover) { revealControls() }
        .onChange(of: model.fullScreen) { revealControls() }
        .onChange(of: model.menuTracking) { revealControls() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { note in
            if let window = note.object as? NSWindow, window === model.videoView?.window, model.colorProfile == "display" { model.applyColorProfile() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow, window === model.window else { return }
            model.windowModes.beginFullScreen(model)
            inspectorBeforeFullScreen = model.inspector
            model.inspector = false
            model.queuePopover = false; model.quickSettings = false
            model.fullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow, window === model.window else { return }
            model.windowModes.beginFullScreen(model)
            model.queuePopover = false; model.quickSettings = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            if let window = note.object as? NSWindow, window === model.window { model.fullScreen = true; model.windowModes.finishFullScreen(model) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if let window = note.object as? NSWindow, window === model.window { model.fullScreen = false; model.inspector = inspectorBeforeFullScreen; model.windowModes.finishFullScreen(model) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if let window = note.object as? NSWindow, window === model.window, model.miniPlayer, !model.windowTransition {
                model.windowModes.restore(model)
            }
            if let window = note.object as? NSWindow, window === model.window, let view = model.videoView, model.session == nil {
                model.attach(view)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if let window = note.object as? NSWindow, window === model.window { model.shutdown() }
        }
        .onExitCommand { if model.queuePopover || model.quickSettings { model.queuePopover = false; model.quickSettings = false } else if model.miniPlayer { model.toggleMiniPlayer() } else if model.fullScreen { model.toggleFullScreen() } }
        .navigationTitle(model.title)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button { model.openPanel() } label: { Label("Open", systemImage: "folder") }.help("Open media (⌘O)")
                Menu {
                    if model.recent.isEmpty { Text("No recent videos") }
                    ForEach(model.recent, id: \.self) { path in
                        Button(URL(fileURLWithPath: path).lastPathComponent) { model.open(URL(fileURLWithPath: path)) }
                    }
                } label: { Label("Recent", systemImage: "clock") }
            }
            ToolbarSpacer(.flexible, placement: .automatic)
            ToolbarItemGroup(placement: .automatic) {
                Toggle(isOn: $model.master) { Label("Enhancement", systemImage: "sparkles") }.help("Toggle all enhancements")
                Button { model.toggleFullScreen() } label: { Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") }
                Button { model.showSidebar("queue") } label: { Label("Play Queue", systemImage: "list.bullet") }
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                Button { if model.inspector { model.inspector = false } else { model.showSidebar("enhance") } } label: { Label("Inspector", systemImage: "sidebar.right") }
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbarColorScheme(.dark, for: .windowToolbar)
        .toolbar(model.fullScreen ? .hidden : .automatic, for: .windowToolbar)
        .inspector(isPresented: Binding(get: { model.inspector && !model.fullScreen }, set: { model.inspector = $0 })) { PlayerSidebar(model: model).inspectorColumnWidth(min: 270, ideal: 310, max: 380) }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }; model.openFiles(urls); return true
        }
    }
    private func revealControls() {
        if !controlsVisible { withAnimation(reduceMotion ? nil : .easeIn(duration: 0.15)) { controlsVisible = true } }
        if Date().timeIntervalSince(lastActivity) > 0.2 { lastActivity = Date() }
    }
}

struct EnhancementInspector: View {
    @ObservedObject var model: PlayerModel
    var body: some View {
        Form {
            Section("Enhancement") {
                EnhancementControls(model: model)
                Button("Retry Enhancements", systemImage: "arrow.clockwise") { model.retry() }
            }
            Section("Audio & Subtitles") {
                Picker("Audio", selection: Binding(get: { model.audioID }, set: { model.selectTrack("aid", $0) })) {
                    Text("None").tag("no")
                    ForEach(model.audioTracks) { Text($0.title).tag(String($0.id)) }
                }
                Picker("Subtitles", selection: Binding(get: { model.subtitleID }, set: { model.selectTrack("sid", $0) })) {
                    Text("Off").tag("no")
                    ForEach(model.subtitles) { Text($0.title).tag(String($0.id)) }
                }
                Button("Load Subtitles…") { model.openPanel(subtitle: true) }
            }
            Section("Live Performance") {
                row("Dropped frames", model.number("frame-drop-count").map { String(Int($0)) } ?? "N/A")
                row("Interpolation job", model.jobTime(model.fi == "rife" ? "iive-rife" : "iive-fi"))
                row("Super resolution job", model.jobTime("iive-sr"))
                row("SR input", model.meta("iive-sr")["input_surface"] ?? "N/A")
                row("Shared SR inputs", model.meta("iive-sr")["shared_inputs"] ?? "N/A")
                row("A/V clock offset", model.number("avsync").map { String(format: "%.1f ms", $0 * 1000) } ?? "N/A")
                Text("Latest job times include conversion and inference; they are not end-to-end playback latency.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Processing") {
                Text("Interpolation → Super Resolution → Display").font(.callout)
                Text("Apple effects: VideoToolbox. Native RIFE and FSRCNNX: FP16 Metal / MPSGraph. Compatible native stages share pooled NV12 surfaces.").font(.caption).foregroundStyle(.secondary)
                Text("GPU / Neural Accelerator utilization: N/A (not measured). Scheduling is managed by Apple frameworks; this does not prove ANE execution. Native enhancement supports SDR BT.709; unsupported input bypasses it.").font(.caption).foregroundStyle(.secondary)
            }
            if !model.error.isEmpty { Section("Playback Message") { Text(model.error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) } }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
    }
    private func status(_ value: String) -> some View {
        Label(value, systemImage: value.hasPrefix("Active") ? "checkmark.circle.fill" : value.hasPrefix("Warming") || value.hasPrefix("Verifying") ? "clock" : "circle")
            .font(.caption).foregroundStyle(value.hasPrefix("Active") ? .green : .secondary)
            .accessibilityLabel(value)
    }
    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).monospacedDigit().textSelection(.enabled) }.font(.caption)
    }
}
