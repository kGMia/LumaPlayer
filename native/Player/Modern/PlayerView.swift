// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Combine

/// Reference box for last-activity timestamp, manual hide suppression, and lower-half motion detection
/// so high-frequency mouse movement in `.onContinuousHover` never invalidates SwiftUI view state unnecessarily.
@MainActor final class ActivityTracker: ObservableObject {
    var last = Date()
    private var manuallyHiddenAt = Date.distantPast
    private var hiddenLocation: CGPoint?
    private var lastHoverLocation: CGPoint?
    private var tapTask: Task<Void, Never>?

    func shouldRevealOnHover(at location: CGPoint, canvasHeight: CGFloat, controlsVisible: Bool) -> Bool {
        let previous = lastHoverLocation
        lastHoverLocation = location
        guard let previous else { return false }

        // Require actual cursor movement (not stationary rest).
        let movedDistance = hypot(location.x - previous.x, location.y - previous.y)
        guard movedDistance >= 4.0 else { return false }

        // Require cursor to be in the lower half of the window/canvas (y increases downward in local coordinates).
        guard canvasHeight > 0, location.y >= canvasHeight * 0.5 else { return false }

        if controlsVisible {
            last = Date()
            return false
        }
        let now = Date()
        if now.timeIntervalSince(manuallyHiddenAt) < 0.45 {
            return false
        }
        if let hiddenLocation {
            let distance = hypot(location.x - hiddenLocation.x, location.y - hiddenLocation.y)
            if distance < 16 { return false }
        }
        self.hiddenLocation = nil
        return true
    }

    func resetHover() {
        lastHoverLocation = nil
    }

    func recordManualToggle(hiding: Bool) {
        if hiding {
            manuallyHiddenAt = Date()
            hiddenLocation = lastHoverLocation
        } else {
            manuallyHiddenAt = .distantPast
            hiddenLocation = nil
            last = Date()
        }
    }

    func handleCanvasTap(onSingleTap: @escaping @MainActor () -> Void, onDoubleTap: @escaping @MainActor () -> Void) {
        if let existing = tapTask {
            existing.cancel()
            tapTask = nil
            onDoubleTap()
            return
        }
        tapTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.tapTask = nil
            onSingleTap()
        }
    }
}

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
    @StateObject private var activity = ActivityTracker()
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var showOverlaySidebar: Bool {
        model.inspector && !model.fullScreen && !model.miniPlayer
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            ZStack {
                Color.black.ignoresSafeArea()
                VideoSurface(model: model)
                    .ignoresSafeArea()
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
                if !model.miniPlayer, model.liveCaptionPlacement != "off" {
                    LiveCaptionOverlay(captions: model.liveCaptions, top: model.liveCaptionPlacement == "top")
                }
                if model.isSRSplitActive {
                    SRSplitComparisonOverlay(model: model)
                }
                VStack {
                    HStack(alignment: .top) {
                        if model.showVideoInfo && model.loaded && !model.miniPlayer {
                            VideoInformationHUD(model: model)
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                        }
                        Spacer(minLength: 0)
                        if model.loaded && !model.miniPlayer {
                            OSDToastView(osd: model.osd)
                                .padding(.trailing, showOverlaySidebar ? 328 : 0)
                        }
                    }
                    .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: model.showVideoInfo)
                    Spacer()
                    if model.loaded {
                        FloatingTransport(model: model, scrubbing: $scrubbing, settings: $model.quickSettings)
                            .frame(maxWidth: 780)
                            .onHover {
                                if hoveringControls != $0 { hoveringControls = $0 }
                                if $0 { activity.last = Date() }
                            }
                            .opacity(controlsVisible ? 1 : 0)
                            .offset(y: reduceMotion || controlsVisible ? 0 : 10)
                            .allowsHitTesting(controlsVisible)
                            .accessibilityHidden(!controlsVisible)
                    }
                }
                .padding(model.miniPlayer ? 10 : 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Floating overlay sidebar above the video canvas: opening/closing never resizes VideoView
            // (avoiding NSOpenGLView reshape stutter) and stays alive in the hierarchy.
            PlayerSidebar(model: model)
                .frame(width: 320)
                .padding(.vertical, 10)
                .padding(.trailing, 10)
                .offset(x: showOverlaySidebar ? 0 : 336)
                .opacity(showOverlaySidebar ? 1 : 0)
                .allowsHitTesting(showOverlaySidebar)
                .accessibilityHidden(!showOverlaySidebar)
                .animation(reduceMotion ? nil : .snappy(duration: 0.22, extraBounce: 0), value: showOverlaySidebar)
        }
        .frame(minWidth: 580, minHeight: 340)
        .ignoresSafeArea(.container, edges: model.fullScreen ? .all : [])
        .background(PlayerWindowReader(model: model).frame(width: 0, height: 0))
        .onAppear {
            model.onCanvasSingleClick = { handleSingleClick() }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let height = max(model.videoView?.bounds.height ?? model.mainVideoHost?.bounds.height ?? 600, 1)
                if activity.shouldRevealOnHover(at: location, canvasHeight: height, controlsVisible: controlsVisible) {
                    revealControls()
                }
            case .ended:
                activity.resetHover()
            }
        }
        .onReceive(timer) { now in
            if controlsVisible && !model.isMenuTracking && model.autoHideControls && model.loaded && !model.enhancementWarming && !model.paused && model.timeline.pendingSeek == nil && !scrubbing && !model.quickSettings && !model.queuePopover && !hoveringControls && now.timeIntervalSince(activity.last) > model.controlsHideDelay {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { controlsVisible = false }
            }
        }
        .onChange(of: model.miniPlayer) { scrubbing = false; hoveringControls = false; revealControls() }
        .onChange(of: model.autoHideControls) { revealControls() }
        .onChange(of: model.paused) { revealControls() }
        .onChange(of: model.enhancementWarming) { revealControls() }
        .onChange(of: model.path) { revealControls() }
        .onChange(of: model.quickSettings) { revealControls() }
        .onChange(of: model.queuePopover) { revealControls() }
        .onChange(of: model.fullScreen) { revealControls() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { note in
            if let window = note.object as? NSWindow, window === model.videoView?.window, model.colorProfile == "display" { model.applyColorProfile() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow, window === model.window else { return }
            window.toolbar?.isVisible = false
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
            if let window = note.object as? NSWindow, window === model.window {
                window.toolbar?.isVisible = false
                model.fullScreen = true
                model.windowModes.finishFullScreen(model)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if let window = note.object as? NSWindow, window === model.window {
                model.fullScreen = false
                window.toolbar?.isVisible = true
                model.inspector = inspectorBeforeFullScreen
                model.windowModes.finishFullScreen(model)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if let window = note.object as? NSWindow, window === model.window, model.miniPlayer, !model.windowTransition {
                model.windowModes.restore(model)
            }
            if let window = note.object as? NSWindow, window === model.window, let view = model.videoView, model.session == nil {
                model.attach(view)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willStartLiveResizeNotification)) { note in
            if let window = note.object as? NSWindow, window === model.window || window === model.videoView?.window {
                model.liveResizing = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification)) { note in
            if let window = note.object as? NSWindow, window === model.window || window === model.videoView?.window {
                model.liveResizing = false
                model.enhancementPlanResumeAt = ProcessInfo.processInfo.systemUptime + 0.12
                model.telemetry.flush()
                model.apply()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if let window = note.object as? NSWindow, window === model.window { model.shutdown() }
        }
        .onExitCommand { if model.queuePopover || model.quickSettings { model.queuePopover = false; model.quickSettings = false } else if model.miniPlayer { model.toggleMiniPlayer() } else if model.fullScreen { model.toggleFullScreen() } }
        .navigationTitle(model.title)
        .toolbar {
            if !model.fullScreen {
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
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbarColorScheme(model.effectiveChromeColorScheme, for: .windowToolbar)
        .preferredColorScheme(model.effectiveChromeColorScheme)
        .toolbar(model.fullScreen ? .hidden : .automatic, for: .windowToolbar)
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }; model.openFiles(urls); return true
        }
    }
    private func revealControls() {
        activity.last = Date()
        if !controlsVisible {
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.15)) { controlsVisible = true }
        }
    }
    private func handleSingleClick() {
        if model.queuePopover || model.quickSettings {
            model.queuePopover = false
            model.quickSettings = false
            return
        }
        guard model.loaded else { return }
        activity.recordManualToggle(hiding: controlsVisible)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            controlsVisible.toggle()
        }
    }
}

struct EnhancementInspector: View {
    @ObservedObject var model: PlayerModel
    let telemetry: PlayerTelemetryState
    init(model: PlayerModel) {
        self.model = model
        self.telemetry = model.telemetry
    }
    var body: some View {
        let _ = telemetry.revision
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
                SubtitleControls(model: model)
            }
            Section("Live Performance") {
                row("Playback phase", model.snapshot["playback-phase"] as? String ?? "N/A")
                row("Dropped frames", model.number("frame-drop-count").map { String(Int($0)) } ?? "N/A")
                row("Interpolation job", model.jobTime(model.fi == "rife" ? "iive-rife" : "iive-fi"))
                row("Super resolution job", model.jobTime("iive-sr"))
                row("SR input", model.meta("iive-sr")["input_surface"] ?? "N/A")
                row("Reused SR outputs", model.meta("iive-sr")["reused_outputs"] ?? "N/A")
                row("Shared SR inputs", model.meta("iive-sr")["shared_inputs"] ?? "N/A")
                row("GPU-normalized SR inputs", model.meta("iive-sr")["normalized_inputs"] ?? "N/A")
                row("SR input / model / output", model.stageTimes("iive-sr"))
                row("FI input", model.meta(model.fi == "rife" ? "iive-rife" : "iive-fi")["input_surface"] ?? "N/A")
                row("FI input / model / output", model.stageTimes(model.fi == "rife" ? "iive-rife" : "iive-fi"))
                row("A/V clock offset", model.number("avsync").map { String(format: "%.1f ms", $0 * 1000) } ?? "N/A")
                Text("Stage times are worker wall time: input conversion, model API call (including GPU wait), and output wrapping/conversion. They exclude queue and display latency; model calls may produce more than one frame.")
                    .font(.caption).foregroundStyle(.white.opacity(0.72))
            }
            Section("Processing") {
                Text("Interpolation → Super Resolution → Display").font(.callout).foregroundStyle(.white)
                Text("Apple effects: VideoToolbox. Native RIFE and FSRCNNX: FP16 Metal / MPSGraph. Compatible native stages share pooled NV12 IOSurfaces directly from VideoToolbox hardware decoding.")
                    .font(.caption).foregroundStyle(.white.opacity(0.72))
            }
            if !model.error.isEmpty { Section("Playback Message") { Text(model.error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) } }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .foregroundStyle(.white)
    }
    private func status(_ value: String) -> some View {
        Label(value, systemImage: value.hasPrefix("Active") ? "checkmark.circle.fill" : value.hasPrefix("Warming") || value.hasPrefix("Verifying") ? "clock" : "circle")
            .font(.caption).foregroundStyle(value.hasPrefix("Active") ? .green : .white.opacity(0.72))
            .accessibilityLabel(value)
    }
    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).foregroundStyle(.white.opacity(0.92)).monospacedDigit().textSelection(.enabled)
        }
        .font(.caption)
    }
}

/// Interactive split-wipe comparison overlay for Super Resolution (Original on left vs Super-Resolved on right).
/// Maps the normalized split ratio directly to the letterboxed/pillarboxed video canvas rect.
struct SRSplitComparisonOverlay: View {
    @ObservedObject var model: PlayerModel

    private func videoRect(in canvas: CGSize) -> CGRect {
        let w = (model.source["dw"] as? NSNumber)?.doubleValue ?? (model.source["w"] as? NSNumber)?.doubleValue ?? Double(max(canvas.width, 1))
        let h = (model.source["dh"] as? NSNumber)?.doubleValue ?? (model.source["h"] as? NSNumber)?.doubleValue ?? Double(max(canvas.height, 1))
        guard w > 0, h > 0, canvas.width > 0, canvas.height > 0 else {
            return CGRect(origin: .zero, size: canvas)
        }
        let videoAspect = CGFloat(w / h)
        let canvasAspect = canvas.width / canvas.height
        if canvasAspect > videoAspect {
            let videoHeight = canvas.height
            let videoWidth = videoHeight * videoAspect
            return CGRect(x: (canvas.width - videoWidth) * 0.5, y: 0, width: videoWidth, height: videoHeight)
        } else {
            let videoWidth = canvas.width
            let videoHeight = videoWidth / videoAspect
            return CGRect(x: 0, y: (canvas.height - videoHeight) * 0.5, width: videoWidth, height: videoHeight)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let rect = videoRect(in: geometry.size)
            let splitX = rect.minX + rect.width * CGFloat(model.srSplitRatio)
            ZStack(alignment: .topLeading) {
                // Vertical split line inside the active video area
                Rectangle()
                    .fill(Color.white.opacity(0.88))
                    .frame(width: 1.5, height: rect.height)
                    .shadow(color: .black.opacity(0.65), radius: 2, x: 0, y: 0)
                    .position(x: splitX, y: rect.midY)
                    .allowsHitTesting(false)

                // Left / Right comparison labels near top of divider
                HStack(spacing: 12) {
                    Text("Original")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                    Text("FSRCNNX 2×")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 4, x: 0, y: 1)
                .position(x: min(max(splitX, rect.minX + 90), rect.maxX - 90), y: max(rect.minY + 28, 36))
                .allowsHitTesting(false)

                // Draggable handle on the divider line
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 30, height: 30)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.75), lineWidth: 1))
                        .shadow(color: .black.opacity(0.45), radius: 5, x: 0, y: 2)
                    Image(systemName: "arrow.left.and.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 40, height: max(rect.height, 44))
                .contentShape(Rectangle())
                .position(x: splitX, y: rect.midY)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard rect.width > 1 else { return }
                            let ratio = Double((value.location.x - rect.minX) / rect.width)
                            model.srSplitRatio = min(0.95, max(0.05, ratio))
                        }
                )
                .help("Drag to compare Original (left) vs Super Resolution (right)")
            }
        }
    }
}

