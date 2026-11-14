// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Combine

/// Native indeterminate progress, delayed slightly so fast opens do not flash.
/// The video surface stays mounted; no screenshot/readback on the UI thread.
struct MediaLoadingOverlay: View {
    let message: String
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showProgress = false

    var body: some View {
        ZStack {
            if showProgress {
                HStack(spacing: 12) {
                    ProgressView().controlSize(compact ? .small : .regular)
                    Text(message).font(compact ? .caption : .callout).lineLimit(2)
                        .contentTransition(.opacity)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: message)
                }
                .foregroundStyle(.primary)
                .padding(compact ? 12 : 18)
                .modifier(PlaybackGlass(cornerRadius: compact ? 16 : 22))
                .padding(20)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityLabel(message)
        .task {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { showProgress = true }
        }
    }
}

/// Reference box for last-activity timestamp, manual hide suppression, and lower-half motion detection
/// so high-frequency mouse movement in `.onContinuousHover` never invalidates SwiftUI view state unnecessarily.
@MainActor final class ActivityTracker {
    var last = Date()
    var lastTopHover = Date.distantPast
    var isHoveringCanvas = false
    private var manuallyHiddenAt = Date.distantPast
    private var hiddenLocation: CGPoint?
    private var lastHoverLocation: CGPoint?
    private var tapTask: Task<Void, Never>?

    func shouldRevealOnHover(at location: CGPoint, canvasHeight: CGFloat, controlsVisible: Bool) -> Bool {
        isHoveringCanvas = true
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
        isHoveringCanvas = false
        lastHoverLocation = nil
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    func isCursorNearTopEdge(of window: NSWindow?, threshold: CGFloat = 80) -> Bool {
        guard let window else { return false }
        let mouseInWindow = window.mouseLocationOutsideOfEventStream
        let distanceFromTop = window.frame.height - mouseInWindow.y
        return distanceFromTop >= -48 && distanceFromTop <= threshold &&
               mouseInWindow.x >= 0 && mouseInWindow.x <= window.frame.width
    }

    func updateCursorVisibility(controlsVisible: Bool, canHideCursor: Bool) {
        if !controlsVisible && canHideCursor && isHoveringCanvas {
            NSCursor.setHiddenUntilMouseMoves(true)
        } else {
            NSCursor.setHiddenUntilMouseMoves(false)
        }
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
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var scrubbing = false
    @State private var hoveringControls = false
    @State private var controlsVisible = true
    @State private var fullScreenTopBarVisible = false
    @State private var activity = ActivityTracker()
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var showOverlaySidebar: Bool {
        model.inspector && !model.miniPlayer
    }

    private var shouldShowToolbar: Bool {
        if model.miniPlayer { return false }
        // Keep native toolbar items installed throughout fullscreen. The system's
        // onHover policy reveals the titlebar; hiding the toolbar itself disables it.
        if model.fullScreen { return true }
        if model.windowTransition { return false }
        return !model.hasActiveMediaSession || controlsVisible || showOverlaySidebar
    }

    @ViewBuilder private var leadingToolbarButtons: some View {
        Button { model.openPanel() } label: { Label("Open", systemImage: "folder") }.help("Open media (⌘O)")
        Menu {
            if model.recent.isEmpty { Text("No recent videos") }
            ForEach(model.recent, id: \.self) { path in
                Button(URL(fileURLWithPath: path).lastPathComponent) { model.open(URL(fileURLWithPath: path)) }
            }
        } label: { Label("Recent", systemImage: "clock") }.help("Open recent media")
    }
    @ViewBuilder private var trailingToolbarButtons: some View {
        Button { model.master.toggle() } label: {
            Label("Enhancement", systemImage: model.master ? "sparkles" : "sparkle")
        }.help("Toggle all enhancements (⇧⌘E)")
            .accessibilityValue(model.master ? Text("On") : Text("Off"))
        SettingsLink { Label("Settings", systemImage: "gearshape") }.help("Settings (⌘,)")
        Button { if model.inspector { model.inspector = false } else { model.showSidebar("enhance") } } label: {
            Label("Inspector", systemImage: "sidebar.right")
        }.help("Sidebar (⌥⌘I)")
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            ZStack {
                Color.black.ignoresSafeArea()
                VideoSurface(model: model)
                    .ignoresSafeArea()
                if model.audioOnly && (model.loaded || model.mediaSwitch.active) && !model.miniPlayer {
                    AudioArtworkView(artwork: model.audioArtwork, title: model.title,
                                     artist: model.audioArtist, album: model.audioAlbum)
                        .ignoresSafeArea()
                }
                if model.systemHDRActive && !model.miniPlayer, let player = model.systemHDRPlayback.player {
                    SystemHDRSurface(player: player).ignoresSafeArea()
                }
                if model.miniPlayer {
                    ContentUnavailableView {
                        Label("Playing in Mini Player", systemImage: "pip")
                    } description: {
                        Text("Playback continues in the floating window. Queue and settings remain available here.")
                    } actions: {
                        Button("Return Video to This Window") { model.windowModes.restore(model) }
                            .disabled(model.windowTransition)
                    }.foregroundStyle(.white)
                } else if !model.loaded && !model.mediaSwitch.active {
                    ContentUnavailableView {
                        Label(model.playbackActivity.progressMessage(paused: model.paused, retryAttempt: model.networkRetryAttempt) ??
                              (model.playbackActivity == .failed ? "Playback stopped" : model.mediaSwitch.hasOpened ? "No media playing" : "A better view"),
                              systemImage: model.playbackActivity == .reconnecting || model.networkRetryAvailable ? "network" : "play.rectangle")
                    } description: {
                        if model.playbackActivity.isBusy {
                            ProgressView().controlSize(.small)
                            Text(model.playbackActivity == .reconnecting ? String(localized: "Your queue and playback position are kept while reconnecting.") : String(localized: "Preparing the selected media…"))
                        } else if model.networkRetryAvailable {
                            Text("Your queue is kept. Retry when the connection is ready, or reopen the server to update access.")
                        } else { Text("Drop a video or audio file here to begin.") }
                    } actions: {
                        Button("Open Media…") { model.openPanel() }.buttonStyle(.borderedProminent)
                        Button("Browse Files", systemImage: "folder") {
                            model.showFileBrowser()
                        }
                        Button("Open Network…", systemImage: "network") { model.showNetworkSheet = true }
                    }.foregroundStyle(.white)
                }
                Group {
                    if model.mediaSwitch.active && !model.miniPlayer {
                        MediaLoadingOverlay(message: model.playbackActivity.progressMessage(paused: model.paused,
                            retryAttempt: model.networkRetryAttempt) ?? "Opening media…")
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: model.mediaSwitch.active)
                if !model.miniPlayer, !model.systemHDRActive, model.liveCaptionPlacement != "off" {
                    LiveCaptionOverlay(model: model, captions: model.liveCaptions)
                }
                if model.isSRSplitActive {
                    SRSplitComparisonOverlay(model: model)
                }
                VStack {
                    HStack(alignment: .top) {
                        if model.hasAnyHUDCard && model.hasActiveMediaSession && !model.miniPlayer && !model.systemHDRActive {
                            VideoInformationHUD(model: model)
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                        }
                        Spacer(minLength: 0)
                        if model.hasActiveMediaSession && !model.miniPlayer {
                            OSDToastView(osd: model.osd)
                                .padding(.trailing, showOverlaySidebar ? 328 : 0)
                        }
                    }
                    .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: model.showVideoInfo)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: model.showSummaryCard)
                    Spacer()
                    if !model.error.isEmpty && model.playbackActivity.showsError && !model.miniPlayer {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(model.error, systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.primary).textSelection(.enabled)
                            if model.networkRetryAvailable {
                                HStack {
                                    Button("Retry Playback", systemImage: "arrow.clockwise") { model.retryNetworkPlayback() }
                                        .buttonStyle(.borderedProminent)
                                    Button("Open Network…", systemImage: "network") { model.showNetworkSheet = true }
                                }
                            }
                        }
                            .padding(14).modifier(PlaybackGlass(cornerRadius: 16))
                            .frame(maxWidth: 640)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                    }
                    if model.hasActiveMediaSession {
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
            PlayerSidebar(model: model, active: showOverlaySidebar)
                .frame(width: 320)
                .padding(.top, (model.fullScreen && fullScreenTopBarVisible) ? 58 : 10)
                .padding(.bottom, 10)
                .padding(.trailing, 10)
                .offset(x: showOverlaySidebar ? 0 : 336)
                .opacity(showOverlaySidebar ? 1 : 0)
                .allowsHitTesting(showOverlaySidebar)
                .accessibilityHidden(!showOverlaySidebar)
                .animation(reduceMotion ? nil : .snappy(duration: 0.22, extraBounce: 0), value: showOverlaySidebar)
                .animation(reduceMotion ? nil : .snappy(duration: 0.2, extraBounce: 0), value: fullScreenTopBarVisible)
        }
        .overlay {
            if !model.miniPlayer, model.frameActions.textSession.capture != nil {
                LiveTextWindow(session: model.frameActions.textSession)
            }
        }
        .frame(minWidth: 580, minHeight: 340)
        .ignoresSafeArea(.container, edges: model.fullScreen ? .all : [])
        .background(PlayerWindowBridge(model: model).frame(width: 0, height: 0))
        .onAppear {
            model.onCanvasSingleClick = { handleSingleClick() }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                if model.fullScreen {
                    if location.y <= 56 || activity.isCursorNearTopEdge(of: model.window, threshold: 62) {
                        activity.lastTopHover = Date()
                        NSCursor.setHiddenUntilMouseMoves(false)
                        if !fullScreenTopBarVisible {
                            fullScreenTopBarVisible = true
                        }
                    } else if fullScreenTopBarVisible && location.y > 92 && !model.isMenuTracking && !activity.isCursorNearTopEdge(of: model.window, threshold: 92) && Date().timeIntervalSince(activity.lastTopHover) > 0.35 {
                        fullScreenTopBarVisible = false
                    }
                }
                let height = max(model.videoView?.bounds.height ?? model.mainVideoHost?.bounds.height ?? 600, 1)
                if activity.shouldRevealOnHover(at: location, canvasHeight: height, controlsVisible: controlsVisible) {
                    revealControls()
                }
            case .ended:
                if model.fullScreen && activity.isCursorNearTopEdge(of: model.window, threshold: 92) {
                    activity.lastTopHover = Date()
                    NSCursor.setHiddenUntilMouseMoves(false)
                    if !fullScreenTopBarVisible {
                        fullScreenTopBarVisible = true
                    }
                } else {
                    activity.resetHover()
                    if fullScreenTopBarVisible && !model.isMenuTracking && Date().timeIntervalSince(activity.lastTopHover) > 0.35 {
                        fullScreenTopBarVisible = false
                    }
                }
            }
        }
        .onReceive(timer) { now in
            guard model.fullScreen || (controlsVisible && model.autoHideControls && model.loaded && !model.paused) else { return }
            if model.fullScreen {
                let nearTop = activity.isCursorNearTopEdge(of: model.window, threshold: fullScreenTopBarVisible ? 92 : 54)
                if nearTop {
                    activity.lastTopHover = now
                    if !fullScreenTopBarVisible {
                        NSCursor.setHiddenUntilMouseMoves(false)
                        fullScreenTopBarVisible = true
                    }
                } else if fullScreenTopBarVisible && !model.isMenuTracking && now.timeIntervalSince(activity.lastTopHover) > 0.4 {
                    fullScreenTopBarVisible = false
                }
            }
            if controlsVisible && !model.isMenuTracking && model.autoHideControls && model.transportTitle.isEmpty && model.resumedFrom == nil && model.loaded && !model.playbackActivity.isBusy && !model.paused && model.timeline.pendingSeek == nil && !scrubbing && !model.quickSettings && !model.queuePopover && !hoveringControls && now.timeIntervalSince(activity.last) > model.controlsHideDelay {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { controlsVisible = false }
                activity.updateCursorVisibility(controlsVisible: false, canHideCursor: !showOverlaySidebar && !hoveringControls && !fullScreenTopBarVisible)
            }
        }
        .sheet(isPresented: $model.showNetworkSheet) { NetworkMediaSheet(model: model) }
        .onChange(of: model.miniPlayer) { scrubbing = false; hoveringControls = false; revealControls() }
        .onChange(of: model.autoHideControls) { revealControls() }
        .onChange(of: model.paused) { revealControls() }
        .onChange(of: model.playbackActivity) { revealControls() }
        .onChange(of: model.path) { revealControls() }
        .onChange(of: model.resumedFrom) { if model.resumedFrom != nil { revealControls() } }
        .onChange(of: model.transportTitle) { if !model.transportTitle.isEmpty { revealControls() } }
        .onChange(of: model.quickSettings) { revealControls() }
        .onChange(of: model.queuePopover) { revealControls() }
        .onChange(of: model.fullScreen) {
            fullScreenTopBarVisible = model.fullScreen && activity.isCursorNearTopEdge(of: model.window, threshold: 62)
            revealControls()
        }
        .onExitCommand { if model.queuePopover || model.quickSettings { model.queuePopover = false; model.quickSettings = false } else if model.miniPlayer { model.toggleMiniPlayer() } else if model.fullScreen { model.toggleFullScreen() } }
        .navigationTitle(model.title)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) { leadingToolbarButtons }
            ToolbarSpacer(.flexible, placement: .automatic)
            ToolbarItemGroup(placement: .automatic) { trailingToolbarButtons }
        }
        // SwiftUI owns window/toolbar presentation; AppKit only tracks lifecycle
        // and synchronizes renderer transitions.
        .containerBackground(Color.black, for: .window)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbarColorScheme(model.effectiveChromeColorScheme, for: .windowToolbar)
        .preferredColorScheme(model.effectiveChromeColorScheme)
        .toolbarVisibility(shouldShowToolbar ? .visible : .hidden, for: .windowToolbar)
        .windowToolbarFullScreenVisibility(.onHover)
        .onInteractiveResizeChange { isResizing in
            if model.liveResizing != isResizing {
                model.liveResizing = isResizing
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }; model.openFiles(urls); return true
        }
    }
    private func revealControls() {
        activity.last = Date()
        NSCursor.setHiddenUntilMouseMoves(false)
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
        let nextVisible = !controlsVisible
        activity.recordManualToggle(hiding: controlsVisible)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            controlsVisible = nextVisible
        }
        activity.updateCursorVisibility(controlsVisible: nextVisible, canHideCursor: !showOverlaySidebar && !hoveringControls && !fullScreenTopBarVisible)
    }
}

struct EnhancementInspector: View {
    let model: PlayerModel
    @StateObject private var observation = SidebarModelObservation()
    let telemetry: PlayerTelemetryState
    let active: Bool
    init(model: PlayerModel, active: Bool = true) {
        self.active = active
        self.model = model
        self.telemetry = model.telemetry
    }
    var body: some View {
        let _ = active ? telemetry.revision : 0
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
                row("Playback activity", model.playbackActivity.rawValue.capitalized)
                row("Engine phase", model.snapshot["playback-phase"] as? String ?? "N/A")
                row("Dropped frames", model.number("frame-drop-count").map { String(Int($0)) } ?? "N/A")
                row("Interpolation job", model.jobTime(model.fi == "rife" ? "iive-rife" : "iive-fi"))
                row("Super resolution job", model.jobTime("iive-sr"))
                row("SR job P50 / P95", model.jobPercentiles("iive-sr"))
                row("FI job P50 / P95", model.jobPercentiles(model.fi == "rife" ? "iive-rife" : "iive-fi"))
                row("SR input", model.meta("iive-sr")["input_surface"] ?? "N/A")
                row("Reused SR outputs", model.meta("iive-sr")["reused_outputs"] ?? "N/A")
                row("Shared SR inputs", model.meta("iive-sr")["shared_inputs"] ?? "N/A")
                row("GPU-normalized SR inputs", model.meta("iive-sr")["normalized_inputs"] ?? "N/A")
                row("SR input / model / output", model.stageTimes("iive-sr"))
                row("SR GPU span / CPU wait", model.modelTiming("iive-sr"))
                row("FI input", model.meta(model.fi == "rife" ? "iive-rife" : "iive-fi")["input_surface"] ?? "N/A")
                row("FI input / model / output", model.stageTimes(model.fi == "rife" ? "iive-rife" : "iive-fi"))
                row("FI GPU span / CPU wait", model.modelTiming(model.fi == "rife" ? "iive-rife" : "iive-fi"))
                row("A/V clock offset", model.number("avsync").map { String(format: "%.1f ms", $0 * 1000) } ?? "N/A")
                row("Drag preview seeks", model.number("iive-scrub-seeks").map { String(Int($0)) } ?? "N/A")
                row("Paused comparison seeks", model.number("iive-split-refresh-seeks").map { String(Int($0)) } ?? "N/A")
                Text("Stage times are worker wall time: input conversion, model API call (including GPU wait), and output wrapping/conversion. They exclude queue and display latency; model calls may produce more than one frame. GPU span covers all timesteps and submission gaps, not GPU utilization. CPU wait overlaps it; do not add the two. Cache reuse, warm-up and unavailable timings show N/A.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("P50/P95 use up to 120 recent active jobs, including reused outputs and scene-cut holds. Seeking resets the sample window. Warm-up without output, bypass and canceled jobs are excluded. Seek counters cover this playback session.")
                    .font(.caption).foregroundStyle(.secondary)

            }
            Section("Processing") {
                Text("Interpolation → Super Resolution → Display").font(.callout).foregroundStyle(.primary)
                Text("Apple effects: VideoToolbox. Native RIFE and FSRCNNX: FP16 Metal / MPSGraph. Compatible native stages share pooled NV12 IOSurfaces directly from VideoToolbox hardware decoding.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.error.isEmpty { Section("Playback Message") { Text(model.error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) } }
        }
        .onChange(of: active, initial: true) { _, value in observation.update(model, active: value) }
        .onAppear { observation.update(model, active: active) }
        .onDisappear { observation.stop() }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .foregroundStyle(.primary)
    }
    private func status(_ value: String) -> some View {
        Label(value, systemImage: value.hasPrefix("Active") ? "checkmark.circle.fill" : value.hasPrefix("Warming") || value.hasPrefix("Verifying") ? "clock" : "circle")
            .font(.caption).foregroundStyle(value.hasPrefix("Active") ? Color.green : Color.secondary)
            .accessibilityLabel(value)
    }
    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).foregroundStyle(.primary).monospacedDigit().textSelection(.enabled)
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
                    Text("Source · Bilinear")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .glassEffect(.regular, in: Capsule())
                    Text("FSRCNNX 2×")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .glassEffect(.regular, in: Capsule())
                }
                .foregroundStyle(.primary)
                .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 1)
                .position(x: min(max(splitX, rect.minX + 90), rect.maxX - 90), y: max(rect.minY + 28, 36))
                .allowsHitTesting(false)

                // Draggable handle on the divider line
                Image(systemName: "arrow.left.and.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .shadow(color: .black.opacity(0.35), radius: 5, x: 0, y: 2)
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
                .help("Drag to compare Bilinear source (left) vs FSRCNNX (right)")
            }
        }
    }
}

