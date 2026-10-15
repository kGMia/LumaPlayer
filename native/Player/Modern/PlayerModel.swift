// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Observation
import UniformTypeIdentifiers

struct MediaTrack: Identifiable, Equatable {
    let id: Int
    let title: String
}

/// High-frequency HUD and Inspector telemetry state (4 Hz), observed via Swift `Observation`
/// only by `VideoInformationHUD`, `VideoInformationRows`, and `EnhancementInspector`.
@MainActor final class PlayerTelemetryState: Observation.Observable {
    private let _$observationRegistrar = Observation.ObservationRegistrar()
    var raw: [String: Any] = [:]
    private var _snapshot: [String: Any] = [:]
    private var _revision: UInt64 = 0

    var snapshot: [String: Any] {
        _$observationRegistrar.access(self, keyPath: \.snapshot)
        return _snapshot
    }

    var revision: UInt64 {
        _$observationRegistrar.access(self, keyPath: \.revision)
        return _revision
    }

    func update(_ value: [String: Any], visible: Bool) {
        raw = value
        if visible {
            _$observationRegistrar.withMutation(of: self, keyPath: \.snapshot) {
                _snapshot = value
            }
            _$observationRegistrar.withMutation(of: self, keyPath: \.revision) {
                _revision &+= 1
            }
        }
    }
    func flush() {
        _$observationRegistrar.withMutation(of: self, keyPath: \.snapshot) {
            _snapshot = raw
        }
        _$observationRegistrar.withMutation(of: self, keyPath: \.revision) {
            _revision &+= 1
        }
    }
    func reset() {
        raw = [:]
        _$observationRegistrar.withMutation(of: self, keyPath: \.snapshot) {
            _snapshot = [:]
        }
        _$observationRegistrar.withMutation(of: self, keyPath: \.revision) {
            _revision &+= 1
        }
    }
}

/// Dedicated low-frequency state for the macOS system menu bar (.commands).
/// Decouples NSApp.mainMenu and its 2nd-level submenus from playback telemetry updates.
@MainActor final class PlayerMenuState: ObservableObject {
    @Published var paused = true
    @Published var loaded = false
    @Published var canPrevious = false
    @Published var canNext = false
    @Published var muted = false
    @Published var hasPath = false
    @Published var fullScreen = false
    @Published var miniPlayer = false
    @Published var master = true
    @Published var showVideoInfo = true
    @Published var showTimelinePreview = true
    @Published var inspector = false
    @Published var repeatMode = "off"
    @Published var seekSeconds = 5.0
    @Published var longSeekSeconds = 30.0
    @Published var recent: [String] = []
    @Published var chapters: [MediaChapter] = []
    @Published var modalPanelActive = false

    func sync(from model: PlayerModel) {
        guard !model.isMenuTracking else { return }
        if paused != model.paused { paused = model.paused }
        if loaded != model.loaded { loaded = model.loaded }
        if canPrevious != model.canPrevious { canPrevious = model.canPrevious }
        if canNext != model.canNext { canNext = model.canNext }
        if muted != model.muted { muted = model.muted }
        let pathPresent = !model.path.isEmpty
        if hasPath != pathPresent { hasPath = pathPresent }
        if fullScreen != model.fullScreen { fullScreen = model.fullScreen }
        if miniPlayer != model.miniPlayer { miniPlayer = model.miniPlayer }
        if master != model.master { master = model.master }
        if showVideoInfo != model.showVideoInfo { showVideoInfo = model.showVideoInfo }
        if showTimelinePreview != model.showTimelinePreview { showTimelinePreview = model.showTimelinePreview }
        if inspector != model.inspector { inspector = model.inspector }
        if repeatMode != model.repeatMode { repeatMode = model.repeatMode }
        if seekSeconds != model.seekSeconds { seekSeconds = model.seekSeconds }
        if longSeekSeconds != model.longSeekSeconds { longSeekSeconds = model.longSeekSeconds }
        if recent != model.recent { recent = model.recent }
        let nextChapters = model.chapters
        let orderedChapters = nextChapters.sorted { $0.time < $1.time }
        if chapters != orderedChapters { chapters = orderedChapters }
        let hasModal = NSApp?.modalWindow != nil
        if modalPanelActive != hasModal { modalPanelActive = hasModal }
    }
}

/// Lightweight transient OSD status toast state (e.g. Volume, Speed, Mute, cumulative Skip, Enhancement toggle),
/// migrated to Swift `Observation` for per-property tracking in `OSDToastView`.
@MainActor final class PlayerOSDState: Observation.Observable {
    private let _$observationRegistrar = Observation.ObservationRegistrar()
    private var _symbol = ""
    private var _text = ""
    private var _visible = false
    private var dismissTask: Task<Void, Never>?
    private var accumulatedSkip = 0.0
    private var lastSkipUptime = 0.0

    var symbol: String {
        get {
            _$observationRegistrar.access(self, keyPath: \.symbol)
            return _symbol
        }
        set {
            guard _symbol != newValue else { return }
            _$observationRegistrar.withMutation(of: self, keyPath: \.symbol) {
                _symbol = newValue
            }
        }
    }

    var text: String {
        get {
            _$observationRegistrar.access(self, keyPath: \.text)
            return _text
        }
        set {
            guard _text != newValue else { return }
            _$observationRegistrar.withMutation(of: self, keyPath: \.text) {
                _text = newValue
            }
        }
    }

    var visible: Bool {
        get {
            _$observationRegistrar.access(self, keyPath: \.visible)
            return _visible
        }
        set {
            guard _visible != newValue else { return }
            _$observationRegistrar.withMutation(of: self, keyPath: \.visible) {
                _visible = newValue
            }
        }
    }

    func show(_ text: String, symbol: String) {
        accumulatedSkip = 0
        self.symbol = symbol
        self.text = text
        if !visible { visible = true }
        scheduleDismiss()
    }

    /// Accumulates consecutive fast-forward/rewind steps while the OSD toast remains active (e.g. +5s -> +10s -> +15s).
    func showSkip(delta: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        if visible, now - lastSkipUptime < 1.35, accumulatedSkip != 0 {
            accumulatedSkip += delta
        } else {
            accumulatedSkip = delta
        }
        lastSkipUptime = now
        let total = Int(accumulatedSkip.rounded())
        if total == 0 {
            symbol = "clock.arrow.circlepath"
            text = "0s"
        } else {
            let sign = total > 0 ? "+" : ""
            symbol = total > 0 ? "goforward" : "gobackward"
            text = "\(sign)\(total)s"
        }
        if !visible { visible = true }
        scheduleDismiss()
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1250))
            guard !Task.isCancelled else { return }
            self?.visible = false
            self?.accumulatedSkip = 0
        }
    }
}

@MainActor final class PlayerModel: ObservableObject {
    let menuState = PlayerMenuState()
    let nowPlaying = PlayerNowPlayingController()
    let timeline = PlayerTimelineState()
    let timelinePreviews = TimelinePreviewGenerator()
    private var seekPreviewTask: Task<Void, Never>?
    let telemetry = PlayerTelemetryState()
    let osd = PlayerOSDState()
    let liveCaptions = LiveCaptionController()

    @Published var title = "IIVE Player"
    @Published var path = "" {
        didSet {
            if path != oldValue {
                seekPreviewTask?.cancel(); seekPreviewTask = nil
                let previous = oldValue, previews = timelinePreviews
                Task { await previews.cancel(for: previous) }
                frameActions.loadMarkers()
            }
            menuState.sync(from: self)
        }
    }
    lazy var frameActions = FrameActions(model: self)
    @Published var markers: [PlaybackMarker] = []
    @Published var screenshotFolder = UserDefaults.standard.string(forKey: "screenshotFolder") ?? "" {
        didSet { UserDefaults.standard.set(screenshotFolder, forKey: "screenshotFolder") }
    }
    @Published var paused = true { didSet { menuState.sync(from: self) } }
    var position: Double { timeline.position }
    var duration: Double { timeline.duration }
    var snapshot: [String: Any] { telemetry.raw }
    @Published var loaded = false { didSet { menuState.sync(from: self) } }
    @Published var muted = false { didSet { menuState.sync(from: self) } }
    @Published var queue: [QueueItem] = [] { didSet { menuState.sync(from: self) } }
    @Published var chapters: [MediaChapter] = [] { didSet { menuState.sync(from: self) } }
    @Published var queueIndex = -1 { didSet { menuState.sync(from: self) } }
    @Published var volume = 50.0
    @Published var speed = 1.0
    @Published var master = true { didSet { if preferencesReady { configure(); menuState.sync(from: self); osd.show(master ? "Enhancement On" : "Enhancement Off", symbol: "sparkles") } } }
    @Published var sr: String { didSet { if preferencesReady { configure() } } }
    @Published var fi: String { didSet { if preferencesReady { configure() } } }
    @Published var tier: String { didSet { if preferencesReady { configure() } } }
    @Published var targetFPS: Int { didSet { if preferencesReady { configure() } } }
    @Published var automatic: Bool { didSet { if preferencesReady { configure() } } }
    @Published var srCompare = false {
        didSet {
            guard oldValue != srCompare else { return }
            let ratio = srCompare ? srSplitRatio : 0.0
            command(["vf-command", "iive-sr", "split", String(format: "%.4f", ratio)])
            apply()
            osd.show(srCompare ? "SR Split Compare On" : "SR Split Compare Off", symbol: "rectangle.split.2x1")
        }
    }
    @Published var srSplitRatio = 0.5 {
        didSet {
            let clamped = min(0.95, max(0.05, srSplitRatio))
            if abs(clamped - srSplitRatio) > 0.0001 {
                srSplitRatio = clamped
                return
            }
            if srCompare {
                command(["vf-command", "iive-sr", "split", String(format: "%.4f", srSplitRatio)])
            }
        }
    }
    var isSRSplitActive: Bool {
        srCompare && master && !fallback && loaded && !miniPlayer && sr.hasPrefix("fsrcnnx") && nativeSRColorSupported && srScaleEligible
    }
    private var preferencesReady = false
    // Read bounded preferences so manually edited defaults cannot disable safeguards.
    @Published var seekSeconds = preference("seekSeconds", default: 5, range: 1...120) {
        didSet { defaults.set(seekSeconds, forKey: "seekSeconds"); menuState.sync(from: self) }
    }
    @Published var longSeekSeconds = preference("longSeekSeconds", default: 30, range: 1...600) {
        didSet { defaults.set(longSeekSeconds, forKey: "longSeekSeconds"); menuState.sync(from: self) }
    }
    @Published var controlsHideDelay = preference("controlsHideDelay", default: 3, range: 1...15) {
        didSet { defaults.set(controlsHideDelay, forKey: "controlsHideDelay") }
    }
    @Published var volumeStep = preference("volumeStep", default: 5, range: 1...20) {
        didSet { defaults.set(volumeStep, forKey: "volumeStep") }
    }
    @Published var doubleClickAction = UserDefaults.standard.string(forKey: "doubleClickAction") ?? "fullscreen" {
        didSet { defaults.set(doubleClickAction, forKey: "doubleClickAction") }
    }
    @Published var srMinimumScale = preference("srMinimumScale", default: 1.3, range: 1.05...2.0) {
        didSet { if preferencesReady { configure() } }
    }
    @Published var srMaximumHeight = preference("srMaximumHeight", default: 0, range: 0...4320) {
        didSet { if preferencesReady { configure() } }
    }
    @Published var fiMaximumFPS = preference("fiMaximumFPS", default: 30, range: 24...60) {
        didSet { if preferencesReady { configure() } }
    }
    @Published var fiMaximumHeight = preference("fiMaximumHeight", default: 0, range: 0...4320) {
        didSet { if preferencesReady { configure() } }
    }
    @Published var miniAlwaysOnTop = UserDefaults.standard.object(forKey: "miniAlwaysOnTop") as? Bool ?? true {
        didSet { defaults.set(miniAlwaysOnTop, forKey: "miniAlwaysOnTop"); windowModes.updatePolicy(self) }
    }
    @Published var miniAllSpaces = UserDefaults.standard.object(forKey: "miniAllSpaces") as? Bool ?? true {
        didSet { defaults.set(miniAllSpaces, forKey: "miniAllSpaces"); windowModes.updatePolicy(self) }
    }
    private var srScaleEligible = false
    @Published var resumePlayback = UserDefaults.standard.object(forKey: "resumePlayback") as? Bool ?? true {
        didSet { UserDefaults.standard.set(resumePlayback, forKey: "resumePlayback") }
    }
    @Published var autoHideControls = UserDefaults.standard.object(forKey: "autoHideControls") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoHideControls, forKey: "autoHideControls") }
    }
    @Published var showTimelinePreview = UserDefaults.standard.object(forKey: "showTimelinePreview") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showTimelinePreview, forKey: "showTimelinePreview"); menuState.sync(from: self) }
    }
    @Published var repeatMode = UserDefaults.standard.string(forKey: "repeatMode") ?? "off" {
        didSet { UserDefaults.standard.set(repeatMode, forKey: "repeatMode"); applyRepeat(); menuState.sync(from: self) }
    }
    @Published var inspector = false {
        didSet {
            if inspector { telemetry.flush() }
            menuState.sync(from: self)
        }
    }
    @Published var sidebarTab = "queue"
    @Published var queuePopover = false
    @Published var quickSettings = false
    @Published var miniPlayer = false { didSet { menuState.sync(from: self) } }
    @Published var windowTransition = false
    var liveResizing = false
    var enhancementPlanResumeAt = 0.0
    let windowModes = PlayerWindowModes()
    @Published var autoQueueFolder = UserDefaults.standard.bool(forKey: "autoQueueFolder") {
        didSet {
            defaults.set(autoQueueFolder, forKey: "autoQueueFolder")
            cancelFolderScan()
            folderQueueStatus = ""
            if autoQueueFolder, !path.isEmpty { enqueueFolder(around: URL(fileURLWithPath: path)) }
        }
    }
    @Published var decoder = UserDefaults.standard.string(forKey: "decoder") ?? "no" {
        didSet { UserDefaults.standard.set(decoder, forKey: "decoder"); applyDecoder() }
    }
    // Non-published menu tracking state so opening/closing menus or submenus never invalidates SwiftUI views.
    var menuTracking = false {
        didSet { if !isMenuTracking { flushDeferredSnapshot() } }
    }
    private var menuTrackingDepth = 0 {
        didSet { if !isMenuTracking { flushDeferredSnapshot() } }
    }
    var isMenuTracking: Bool {
        menuTracking || menuTrackingDepth > 0 || RunLoop.current.currentMode == .eventTracking
    }
    private var deferredSnapshot: [String: Any]?

    @Published var rotation = UserDefaults.standard.integer(forKey: "videoRotation") {
        didSet { UserDefaults.standard.set(rotation, forKey: "videoRotation"); command(["set", "video-rotate", String(rotation)]) }
    }
    @Published var dolbyVisionMapping = UserDefaults.standard.object(forKey: "dolbyVisionMapping") as? Bool ?? true {
        didSet { UserDefaults.standard.set(dolbyVisionMapping, forKey: "dolbyVisionMapping"); apply() }
    }
    @Published var brightness = preference("brightness", default: 0, range: -100...100) { didSet { setPictureValue("brightness", brightness) } }
    @Published var contrast = preference("contrast", default: 0, range: -100...100) { didSet { setPictureValue("contrast", contrast) } }
    @Published var saturation = preference("saturation", default: 0, range: -100...100) { didSet { setPictureValue("saturation", saturation) } }
    @Published var gamma = preference("gamma", default: 0, range: -100...100) { didSet { setPictureValue("gamma", gamma) } }
    @Published var hue = preference("hue", default: 0, range: -100...100) { didSet { setPictureValue("hue", hue) } }
    @Published var colorProfile = UserDefaults.standard.string(forKey: "colorProfile") ?? "auto" {
        didSet { UserDefaults.standard.set(colorProfile, forKey: "colorProfile"); applyColorProfile() }
    }
    @Published var chromeTheme = UserDefaults.standard.string(forKey: "chromeTheme") ?? "dark" {
        didSet {
            UserDefaults.standard.set(chromeTheme, forKey: "chromeTheme")
            videoView?.setLuminanceSamplingEnabled(chromeTheme == "adaptive")
            applyWindowAppearance()
        }
    }
    @Published var adaptiveLightGlass = false {
        didSet {
            if oldValue != adaptiveLightGlass {
                applyWindowAppearance()
            }
        }
    }

    var effectiveChromeColorScheme: ColorScheme? {
        switch chromeTheme {
        case "system":
            return nil
        case "light":
            return .light
        case "adaptive":
            return (loaded && adaptiveLightGlass) ? .light : .dark
        default:
            return .dark
        }
    }

    func applyWindowAppearance() {
        let appearance: NSAppearance?
        switch chromeTheme {
        case "system":
            appearance = nil
        case "light":
            appearance = NSAppearance(named: .aqua)
        case "adaptive":
            appearance = NSAppearance(named: (loaded && adaptiveLightGlass) ? .aqua : .darkAqua)
        default:
            appearance = NSAppearance(named: .darkAqua)
        }
        window?.appearance = appearance
        windowModes.applyAppearance(appearance)
    }

    @Published var colorProfileStatus = "Automatic · source metadata"
    var colorProfileTask: Task<Void, Never>?
    var lastDecoderOption = ""
    var folderTask: Task<Void, Never>?
    var folderScanID = 0
    @Published var folderQueueStatus = ""
    @Published var queueSort = UserDefaults.standard.string(forKey: "queueSort") ?? "custom" {
        didSet { defaults.set(queueSort, forKey: "queueSort"); synchronizeQueueOrder() }
    }
    @Published var queueDetailed = UserDefaults.standard.bool(forKey: "queueDetailed") {
        didSet { defaults.set(queueDetailed, forKey: "queueDetailed") }
    }
    var customQueueOrder: [Int64] = []
    var queueDates: [Int64: Date] = [:]
    var queueDateTask: Task<Void, Never>?
    var queueMembership = ""
    var queueOrderRequest = ""
    private var volumeAdjustedAt = 0.0

    @Published var fullScreen = false { didSet { menuState.sync(from: self) } }
    @Published var showVideoInfo = UserDefaults.standard.object(forKey: "showVideoInfo") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showVideoInfo, forKey: "showVideoInfo")
            if showVideoInfo { telemetry.flush() }
            menuState.sync(from: self)
        }
    }
    weak var window: NSWindow?
    weak var mainVideoHost: NSView?
    func toggleFullScreen() { windowModes.toggleFullScreen(self) }

    @Published var srStatus = "Off"
    @Published var fiStatus = "Off"
    @Published var error = ""
    @Published var recent: [String] { didSet { menuState.sync(from: self) } }
    @Published var audioTracks: [MediaTrack] = []
    @Published var subtitles: [MediaTrack] = []
    @Published var audioID = "no"
    @Published var subtitleID = "no"
    @Published var secondarySubtitleID = "no"
    @Published var liveCaptionPlacement = "off"
    @Published var captionLanguage = UserDefaults.standard.string(forKey: "captionLanguage") ?? "en-US" {
        didSet { defaults.set(captionLanguage, forKey: "captionLanguage"); updateLiveCaptions() }
    }
    func updateLiveCaptions(download: Bool = false) {
        liveCaptions.update(session: session, path: path, audio: audioID, language: captionLanguage,
            enabled: liveCaptionPlacement != "off", position: position - (number("audio-delay") ?? 0), paused: paused,
            seeking: snapshot["seeking"] as? Bool == true, download: download)
    }
    func selectSubtitle(_ id: String, secondary: Bool) {
        let placement = secondary ? "top" : "bottom"
        if id == "live" {
            liveCaptionPlacement = placement
            command(["set", secondary ? "secondary-sid" : "sid", "no"])
        } else {
            if liveCaptionPlacement == placement { liveCaptionPlacement = "off" }
            // One embedded/external track cannot occupy both native slots.
            if id != "no", id == (secondary ? subtitleID : secondarySubtitleID) {
                command(["set", secondary ? "sid" : "secondary-sid", "no"])
            }
            command(["set", secondary ? "secondary-sid" : "sid", id])
        }
        updateLiveCaptions()
    }
    @Published var fallback = false
    @Published var enhancementWarming = false
    weak var videoView: VideoView?
    var onCanvasSingleClick: (() -> Void)?
    var onMiniCanvasSingleClick: (() -> Void)?
    private var openedLaunchInput = false
    var session: MPVSession?
    private var lastPlan = ""
    private var shaderFailed = false
    private var unverifiedSamples = 0
    private var pendingOpen: (URL, Bool)?
    private var pendingQueue: ([URL], Bool)?
    private var pendingResume: (String, Double)?
    private var badSamples = 0
    private var previousDrops = 0.0
    private var settledSamples = 0
    private var lastSave = 0.0
    private var fileEpoch = ""
    private let defaults = UserDefaults.standard
    private var menuObservers: [NSObjectProtocol] = []
    private var keyMonitor: Any?

    init() {
        sr = defaults.string(forKey: "sr") ?? "fsrcnnx_metal8"
        fi = defaults.string(forKey: "fi") ?? "apple"
        tier = defaults.string(forKey: "tier") ?? "fast"
        targetFPS = defaults.integer(forKey: "fps") == 60 ? 60 : 48
        automatic = defaults.object(forKey: "automatic") as? Bool ?? true
        recent = defaults.stringArray(forKey: "recent") ?? []
        master = defaults.object(forKey: "master") as? Bool ?? true
        volume = defaults.object(forKey: "volume") as? Double ?? 50
        if let value = argument("--fps"), let fps = Int(value), [48, 60].contains(fps) { targetFPS = fps }
        if let value = argument("--tier"), ["fast", "balanced", "hq"].contains(value) { tier = value }
        if let value = argument("--sr"), ["off", "fsrcnnx8", "fsrcnnx16", "fsrcnnx_metal8", "fsrcnnx_metal16", "apple"].contains(value) { sr = value }
        if let value = argument("--fi"), ["off", "rife", "apple"].contains(value) { fi = value }
        preferencesReady = true
        menuState.sync(from: self)
        nowPlaying.bind(to: self)
        let center = NotificationCenter.default
        menuObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.menuTrackingDepth += 1
                }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1)
                }
            }
        ]
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let isRepeat = event.isARepeat
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .capsLock])
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                guard NSApp.modalWindow == nil, !self.isMenuTracking else { return false }
                guard let keyWindow = NSApp.keyWindow,
                      keyWindow === self.window || keyWindow === self.videoView?.window else {
                    return false
                }
                if keyWindow.firstResponder is NSText {
                    return false
                }
                // Spacebar (keyCode 49) with no modifiers: always toggle Play/Pause reliably
                // even when controls are auto-hidden or a toolbar button holds focus.
                if keyCode == 49 && mods.isEmpty {
                    if !isRepeat {
                        self.togglePause()
                    }
                    return true
                }
                return false
            }
            return handled ? nil : event
        }
    }
    private func flushDeferredSnapshot() {
        guard !isMenuTracking else { return }
        if let pending = deferredSnapshot {
            deferredSnapshot = nil
            receive(pending)
        } else {
            menuState.sync(from: self)
        }
    }
    func argument(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    func attach(_ view: VideoView) {
        if session != nil {
            if videoView === view { return }
            shutdown()
        }
        videoView = view
        view.contextMenuProvider = { [weak self] in
            // AppKit requests menus on its main thread. Keep the non-Sendable
            // NSMenu inside this synchronous callback, not an actor return value.
            var menu: NSMenu?
            MainActor.assumeIsolated { menu = self?.frameActions.menu() }
            return menu
        }
        view.onSingleClick = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.miniPlayer { self.onMiniCanvasSingleClick?() }
                else { self.onCanvasSingleClick?() }
            }
        }
        view.onDoubleClick = { [weak self] in
            MainActor.assumeIsolated {
                self?.handleDoubleClick()
            }
        }
        view.onScrollVolume = { [weak self] delta in
            MainActor.assumeIsolated {
                guard let self else { return }
                let next = min(100, max(0, self.volume + delta))
                self.setVolume(next, showOSD: true)
            }
        }
        session = MPVSession(view: view)
        guard let session else { error = "Unable to initialize the playback renderer."; return }
        session.onSnapshot = { [weak self] value in
            MainActor.assumeIsolated { self?.receive(value as? [String: Any] ?? [:]) }
        }
        command(["set", "volume", String(volume)])
        applyRepeat()
        applyPictureSettings()
        applyDecoder()
        applyWindowAppearance()
        view.setLuminanceSamplingEnabled(chromeTheme == "adaptive")
        if let pending = pendingQueue { pendingQueue = nil; openFiles(pending.0, append: pending.1) }
        else if let pending = pendingOpen { pendingOpen = nil; open(pending.0, resume: pending.1) }
        else if !openedLaunchInput, let input = argument("--input") { openedLaunchInput = true; open(URL(fileURLWithPath: input), resume: false) }
    }
    func command(_ args: [String]) {
        // A new explicit navigation operation supersedes the held seek target.
        let operation = args.first ?? ""
        let replacingFile = operation == "loadfile" && (args.count < 3 || args[2] == "replace")
        if replacingFile || ["stop", "frame-step", "frame-back-step", "playlist-next", "playlist-prev"].contains(operation) {
            timeline.cancelSeek()
        }
        session?.command(args)
    }
    func openPanel(subtitle: Bool = false, append: Bool = false, secondary: Bool = false) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = !subtitle
        panel.title = subtitle ? "Load Subtitles" : append ? "Add to Play Queue" : "Open Videos"
        if subtitle { panel.allowedContentTypes = [.plainText, .item] }
        menuState.modalPanelActive = true
        panel.begin { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuState.modalPanelActive = NSApp?.modalWindow != nil
                guard result == .OK, let url = panel.url else { return }
                if subtitle {
                    if self.liveCaptionPlacement == (secondary ? "top" : "bottom") { self.liveCaptionPlacement = "off"; self.updateLiveCaptions() }
                    self.session?.loadSubtitle(url.path, secondary: secondary)
                }
                else { self.openFiles(panel.urls, append: append) }
            }
        }
    }
    func openFiles(_ urls: [URL], append: Bool = false) {
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { error = "Please choose local media files."; return }
        guard session != nil else { pendingOpen = nil; pendingQueue = (urls, append); return }
        cancelFolderScan()
        if append {
            // append+play starts only when nothing is playing; append leaves the
            // current item and its pause state intact.
            for url in urls { command(["loadfile", url.path, "append+play"]) }
        } else {
            open(urls[0], scanFolder: urls.count == 1)
            for url in urls.dropFirst() { command(["loadfile", url.path, "append"]) }
        }
    }
    func open(_ url: URL, resume: Bool = true, scanFolder: Bool = true) {
        guard url.isFileURL else { error = "Please open a local media file."; return }
        guard session != nil else { pendingQueue = nil; pendingOpen = (url, resume); return }
        savePosition()
        cancelFolderScan()
        let saved = defaults.dictionary(forKey: "positions")?[url.path] as? Double ?? 0
        pendingResume = resume && resumePlayback && saved > 5 ? (url.path, saved) : nil
        fallback = false; lastPlan = ""; settledSamples = 0; error = ""
        var updatedRecent = recent
        updatedRecent.removeAll { $0 == url.path }
        updatedRecent.insert(url.path, at: 0)
        updatedRecent = Array(updatedRecent.prefix(12))
        if recent != updatedRecent { recent = updatedRecent }
        defaults.set(recent, forKey: "recent")
        applyDecoder()
        command(["loadfile", url.path, "replace"])
        if autoQueueFolder && scanFolder { enqueueFolder(around: url) }
    }
    func togglePause() {
        guard loaded || !path.isEmpty else { return }
        let willPlay = paused || (snapshot["eof-reached"] as? Bool == true)
        if snapshot["eof-reached"] as? Bool == true {
            seek(0)
            command(["set", "pause", "no"])
        } else {
            command(["cycle", "pause"])
        }
        osd.show(willPlay ? "Play" : "Pause", symbol: willPlay ? "play.fill" : "pause.fill")
    }
    func seek(_ value: Double, relative: Bool = false) {
        guard value.isFinite, let session, loaded else { return }
        settledSamples = 0
        if !relative, let request = timeline.beginSeek(to: value, path: path) {
            session.seek(toSeconds: request.target, expectedPath: path, requestID: request.id)
            nowPlaying.sync(from: self, forcePosition: request.target)
            seekPreviewTask?.cancel()
            if showTimelinePreview {
                let mediaPath = path, allowSDR = sdr, previews = timelinePreviews
                seekPreviewTask = Task {
                    _ = await previews.thumbnail(for: mediaPath, at: request.target, allowSDRFallback: allowSDR)
                }
            }
        } else {
            timeline.cancelSeek()
            command(["seek", String(value), relative ? "relative" : "absolute+exact"])
            let estimated = relative ? max(0, min(duration, position + value)) : value
            nowPlaying.sync(from: self, forcePosition: estimated)
        }
    }
    func setVolume(_ value: Double, showOSD: Bool = false) {
        let clamped = min(100, max(0, value))
        volumeAdjustedAt = ProcessInfo.processInfo.systemUptime
        if abs(volume - clamped) > 0.001 { volume = clamped }
        defaults.set(clamped, forKey: "volume")
        if muted && clamped > 0 { command(["set", "mute", "no"]) }
        command(["set", "volume", String(clamped)])
        if showOSD {
            let icon = clamped <= 0.5 ? "speaker.slash.fill" : clamped < 35 ? "speaker.wave.1.fill" : clamped < 70 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
            osd.show("Volume \(Int(clamped.rounded()))%", symbol: icon)
        }
    }
    func setSpeed(_ value: Double) {
        if speed != value { speed = value }
        command(["set", "speed", String(value)])
        osd.show("Speed \(value.formatted())×", symbol: "speedometer")
    }
    func selectTrack(_ type: String, _ id: String) { command(["set", type, id]) }
    func retry() {
        fallback = false; badSamples = 0; settledSamples = 0; shaderFailed = false; unverifiedSamples = 0
        session?.applyFilters([], shader: nil); lastPlan = ""; apply()
    }
    func configure() {
        for (key, value) in ["sr": sr, "fi": fi, "tier": tier] { defaults.set(value, forKey: key) }
        for (key, value) in ["srMinimumScale": srMinimumScale, "srMaximumHeight": srMaximumHeight,
                             "fiMaximumFPS": fiMaximumFPS, "fiMaximumHeight": fiMaximumHeight] { defaults.set(value, forKey: key) }
        srScaleEligible = false
        defaults.set(master, forKey: "master"); shaderFailed = false; unverifiedSamples = 0
        defaults.set(targetFPS, forKey: "fps"); defaults.set(automatic, forKey: "automatic")
        fallback = false; badSamples = 0; settledSamples = 0; apply()
    }
    func resetActivationLimits() {
        preferencesReady = false
        srMinimumScale = 1.3; srMaximumHeight = 0; fiMaximumFPS = 30; fiMaximumHeight = 0
        preferencesReady = true
        configure()
    }
    func number(_ key: String) -> Double? { (telemetry.raw[key] as? NSNumber)?.doubleValue }
    var source: [String: Any] { telemetry.raw["video-params"] as? [String: Any] ?? [:] }
    var nativeSRColorSupported: Bool {
        !isDolbyVision && source["primaries"] as? String == "bt.709" && source["gamma"] as? String == "bt.1886"
    }
    var sdr: Bool {
        if isDolbyVision { return false }
        let prim = (source["primaries"] as? String)?.lowercased() ?? ""
        let gamma = (source["gamma"] as? String)?.lowercased() ?? ""
        let hdrGammas = ["pq", "hlg", "dovi", "smpte2084", "arib-std-b67"]
        if hdrGammas.contains(gamma) { return false }
        let validPrimaries = ["bt.709", "bt.601", "smpte170m", "bt.470bg", "display-p3", "p3", "bt.2020", "bt.601-525", "bt.601-625", "ebu3213"]
        let validGammas = ["bt.1886", "srgb", "bt.709", "gamma2.2", "gamma2.8"]
        return validPrimaries.contains(prim) && validGammas.contains(gamma)
    }
    var sourceDescription: String {
        guard let w = source["w"], let h = source["h"] else { return "N/A" }
        return "\(w) × \(h)"
    }
    var renderRate: String { number("render-callback-fps").map { String(format: "%.1f fps", $0) } ?? "N/A" }
    func meta(_ label: String) -> [String: String] { telemetry.raw[label] as? [String: String] ?? [:] }
    var latency: String {
        let values = ["iive-rife", "iive-fi", "iive-sr"].compactMap { Double(meta($0)["processing_ms"] ?? "") }
        return values.isEmpty ? "N/A" : String(format: "%.1f ms", values.reduce(0, +))
    }
    private func receive(_ value: [String: Any]) {
        // Never mutate any @Published state while a menu or submenu is open/tracking.
        guard !isMenuTracking else {
            deferredSnapshot = value
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let nextPath = value["path"] as? String ?? ""
        if nextPath != path { savePosition() }
        telemetry.update(value, visible: (showVideoInfo || inspector) && !liveResizing)

        let nextLoaded = !(value["video-params"] as? [String: Any] ?? [:]).isEmpty
        if loaded != nextLoaded { loaded = nextLoaded }
        let nextMuted = value["mute"] as? Bool ?? false
        if muted != nextMuted { muted = nextMuted }

        let nextQueue = (value["playlist"] as? [[String: Any]] ?? []).compactMap { item -> QueueItem? in
            guard let id = item["id"] as? NSNumber, let filename = item["filename"] as? String else { return nil }
            return QueueItem(
                id: id.int64Value,
                title: item["title"] as? String ?? URL(fileURLWithPath: filename).lastPathComponent,
                filename: filename,
                current: item["current"] as? Bool ?? false
            )
        }
        if queue != nextQueue {
            queue = nextQueue
            synchronizeQueueOrder()
        }
        let nextQueueIndex = Int((value["playlist-pos"] as? NSNumber)?.doubleValue ?? -1)
        if queueIndex != nextQueueIndex { queueIndex = nextQueueIndex }

        let nextChapters = (value["chapter-list"] as? [[String: Any]] ?? []).enumerated().compactMap { index, item -> MediaChapter? in
            guard let time = item["time"] as? Double, time.isFinite, time >= 0 else { return nil }
            return MediaChapter(id: index, title: item["title"] as? String ?? "Chapter \(index + 1)", time: time)
        }
        let orderedChapters = nextChapters.sorted { $0.time < $1.time }
        if chapters != orderedChapters { chapters = orderedChapters }

        let nextTitle = value["media-title"] as? String ?? "IIVE Player"
        if title != nextTitle { title = nextTitle }
        if path != nextPath { path = nextPath }
        let nextPaused = value["pause"] as? Bool ?? true
        if paused != nextPaused { paused = nextPaused }
        let nextWarming = value["enhancement-warming"] as? Bool ?? false
        if enhancementWarming != nextWarming { enhancementWarming = nextWarming }
        let nextPos = (value["time-pos"] as? NSNumber)?.doubleValue
        let nextDur = (value["duration"] as? NSNumber)?.doubleValue ?? 0
        let seekOutcome = timeline.update(position: nextPos, duration: nextDur, path: nextPath,
                                          seeking: value["seeking"] as? Bool == true,
                                          requestID: value["iive-seek-request-id"] as? String,
                                          commandResult: (value["iive-seek-command-result"] as? NSNumber)?.intValue,
                                          speed: (value["speed"] as? NSNumber)?.doubleValue ?? 1)
        if let seekOutcome {
            osd.show(seekOutcome == .failed ? "Unable to seek to that position" : "Seek not confirmed · showing playback position",
                     symbol: "exclamationmark.triangle")
        }

        let nextVol = (value["volume"] as? NSNumber)?.doubleValue ?? 50
        if now - volumeAdjustedAt > 0.45 && abs(volume - nextVol) > 0.01 { volume = nextVol }
        let nextSpeed = (value["speed"] as? NSNumber)?.doubleValue ?? 1
        if abs(speed - nextSpeed) > 0.001 { speed = nextSpeed }
        let nextError = value["error"] as? String ?? ""
        if error != nextError { error = nextError }
        if path != fileEpoch {
            if !path.isEmpty {
                var updatedRecent = recent
                updatedRecent.removeAll { $0 == path }
                updatedRecent.insert(path, at: 0)
                updatedRecent = Array(updatedRecent.prefix(12))
                if recent != updatedRecent { recent = updatedRecent }
                defaults.set(recent, forKey: "recent")
            }
            srScaleEligible = false
            fileEpoch = path; shaderFailed = false; unverifiedSamples = 0; fallback = false; badSamples = 0; settledSamples = 0; lastPlan = ""
        }
        if let pending = pendingResume, pending.0 == path, duration > 0 {
            pendingResume = nil
            if pending.1 < duration - 10 { seek(pending.1) }
        }
        let tracks = value["track-list"] as? [[String: Any]] ?? []
        func list(_ type: String) -> [MediaTrack] {
            tracks.filter { $0["type"] as? String == type }.compactMap { t in
                guard let id = t["id"] as? Int else { return nil }
                return MediaTrack(id: id, title: [t["title"] as? String, t["lang"] as? String, t["codec"] as? String].compactMap { $0 }.joined(separator: " · ").nonempty ?? "Track \(id)")
            }
        }
        let nextAudioTracks = list("audio")
        if audioTracks != nextAudioTracks { audioTracks = nextAudioTracks }
        let nextSubtitles = list("sub")
        if subtitles != nextSubtitles { subtitles = nextSubtitles }
        let nextAudioID = tracks.first { $0["type"] as? String == "audio" && $0["selected"] as? Bool == true }.flatMap { ($0["id"] as? Int).map(String.init) } ?? "no"
        if audioID != nextAudioID { audioID = nextAudioID }
        func selectedSubtitle(_ slot: Int) -> String {
            tracks.first { $0["type"] as? String == "sub" && $0["selected"] as? Bool == true &&
                ($0["main-selection"] as? Int ?? 0) == slot }.flatMap { ($0["id"] as? Int).map(String.init) } ?? "no"
        }
        let nextSubtitleID = selectedSubtitle(0)
        let nextSecondaryID = selectedSubtitle(1)
        if secondarySubtitleID != nextSecondaryID { secondarySubtitleID = nextSecondaryID }
        if subtitleID != nextSubtitleID { subtitleID = nextSubtitleID }
        if liveCaptionPlacement == "bottom", nextSubtitleID != "no" { command(["set", "sid", "no"]) }
        if liveCaptionPlacement == "top", nextSecondaryID != "no" { command(["set", "secondary-sid", "no"]) }
        updateLiveCaptions()
        let drops = (value["frame-drop-count"] as? NSNumber)?.doubleValue ?? 0
        if !paused && value["seeking"] as? Bool != true && value["enhancement-warming"] as? Bool != true && loaded {
            settledSamples += 1
            if settledSamples > 25 && automatic && master {
                let avsyncVal = (value["avsync"] as? NSNumber)?.doubleValue ?? 0
                badSamples = (drops - previousDrops > 4 || abs(avsyncVal) > 0.25) ? badSamples + 1 : 0
                if badSamples >= 5 && !fallback { fallback = true }
            }
        } else { settledSamples = 0; badSamples = 0 }
        previousDrops = drops
        let expectedPass = sr == "fsrcnnx16" ? "IIVE FSRCNNX 16 / aggregation" : "IIVE FSRCNNX 8 / aggregation"
        if lastPlan.contains("FSRCNNX") && !sr.contains("metal") && !paused && !String(describing: value["vo-passes"] ?? "").contains(expectedPass) {
            unverifiedSamples += 1
            if unverifiedSamples > 24 && !shaderFailed { shaderFailed = true }
        } else { unverifiedSamples = 0 }
        if chromeTheme == "adaptive", loaded, !liveResizing,
           let luma = number("presentation-luminance"), luma.isFinite {
            // Approximate brightness of the actual rendered canvas, including bars.
            // Hysteresis keeps borderline scenes from flickering the glass appearance.
            if adaptiveLightGlass {
                if luma < 0.56 { adaptiveLightGlass = false }
            } else if luma > 0.66 { adaptiveLightGlass = true }
        }
        apply()
        menuState.sync(from: self)
        nowPlaying.sync(from: self)
        if now - lastSave > 10 { savePosition() }
    }
    func apply() {
        guard session != nil, !windowTransition, !liveResizing, ProcessInfo.processInfo.systemUptime >= enhancementPlanResumeAt else { return }
        applyDecoder()
        var filters: [String] = []; var shader: String?
        if isDolbyVision && !dolbyVisionMapping {
            filters.append("@iive-dovi-base:format=dolbyvision=no")
        }
        let disabled = !master || fallback
        let base = disabled ? (fallback ? "Degraded · Retry to restore" : "Off") : !loaded ? "Waiting for video" : !sdr ? "Bypassed · HDR or unknown color metadata" : nil
        var nextFiStatus = fi == "off" ? "Off" : base ?? "Warming"
        var nextSrStatus = sr == "off" ? "Off" : base ?? "Warming"
        let fallbackOption = automatic ? "yes" : "no"
        if base == nil {
            let fps = number("container-fps") ?? 0
            let sourceHeight = (source["h"] as? NSNumber)?.doubleValue ?? 0
            let fiWithinLimits = fps <= fiMaximumFPS + 0.01 && (fiMaximumHeight == 0 || sourceHeight <= fiMaximumHeight)
            if fi != "off" && !fiWithinLimits {
                nextFiStatus = "Bypassed · source exceeds interpolation limits"
            } else if fi == "rife", fps > 0, fps < Double(targetFPS) {
                filters.append("@iive-rife:iive-rife=fps=\(targetFPS):tier=\(tier):fallback=\(fallbackOption)")
                nextFiStatus = state("iive-rife")
                if meta("iive-rife")["state"] == "active", let input = meta("iive-rife")["input_path"] {
                    nextFiStatus += input == "nv12-metal" ? (meta("iive-rife")["output_path"] == "nv12-metal" ? " · Metal NV12 in/out" : " · NV12 → Metal") : " · BGRA input"
                }
            } else if fi == "apple", !nativeSRColorSupported {
                nextFiStatus = "Bypassed · Apple interpolation requires BT.709 / BT.1886 SDR"
            } else if fi == "apple", valueBool("apple-fi-supported"), fps > 0, fps <= 30.01 {
                filters.append("@iive-fi:iive-apple=mode=fi:fallback=\(fallbackOption)")
                nextFiStatus = state("iive-fi") + String(format: " · %.3g → %.3g fps", fps, fps * 2)
            } else if fi != "off" { nextFiStatus = "Unavailable for this source / target" }
            let w = (source["dw"] as? NSNumber)?.doubleValue ?? (source["w"] as? NSNumber)?.doubleValue ?? 1
            let h = (source["dh"] as? NSNumber)?.doubleValue ?? (source["h"] as? NSNumber)?.doubleValue ?? 1
            let scale = min((number("viewport-width") ?? w) / w, (number("viewport-height") ?? h) / h)
            // GLSL's own WHEN guard still requires >1.3×; native models use the chosen threshold.
            let minimumScale = sr.hasPrefix("fsrcnnx") && !sr.contains("metal") ? max(1.3, srMinimumScale) : srMinimumScale
            srScaleEligible = scale > (srScaleEligible ? max(sr.hasPrefix("fsrcnnx") && !sr.contains("metal") ? 1.3 : 1.01, minimumScale - 0.1) : minimumScale)
            let srWithinLimits = srMaximumHeight == 0 || sourceHeight <= srMaximumHeight
            if sr != "off" && !srWithinLimits { nextSrStatus = "Bypassed · source exceeds super resolution limit" }
            else if sr != "off" && !srScaleEligible { nextSrStatus = "Bypassed · below upscaling threshold" }
            else if (sr.contains("metal") || sr == "apple" || (srCompare && sr.hasPrefix("fsrcnnx"))) && !nativeSRColorSupported {
                nextSrStatus = "Bypassed · native SR requires BT.709 / BT.1886 SDR"
            }
            else if sr.contains("metal") || (srCompare && sr.hasPrefix("fsrcnnx")) {
                let is16 = sr == "fsrcnnx_metal16" || sr == "fsrcnnx16"
                let model = is16 ? "quality" : "fast"
                filters.append("@iive-sr:iive-fsrcnnx=tier=\(model):fallback=\(fallbackOption)")
                let backend = is16 ? "fsrcnnx16-mpsgraph" : "fsrcnnx8-mpsgraph"
                let baseStatus = meta("iive-sr")["backend"] == backend ? state("iive-sr") + " · MPSGraph 2×" : "Warming native FSRCNNX"
                nextSrStatus = srCompare ? baseStatus + " · Split Compare" : baseStatus
            }
            else if shaderFailed && sr.hasPrefix("fsrcnnx") && !sr.contains("metal") { nextSrStatus = "Disabled · shader execution not confirmed; Retry" }
            else if sr == "apple" {
                let scales = telemetry.raw["apple-sr-scales"] as? [Double] ?? []
                let supported = scales.filter { $0 > 1 }.sorted()
                if let factor = supported.first(where: { $0 >= scale }) ?? supported.last {
                    filters.append("@iive-sr:iive-apple=mode=sr:scale=\(factor):fallback=\(fallbackOption)")
                    nextSrStatus = state("iive-sr") + " · \(factor)×"
                } else { nextSrStatus = "Unavailable · no supported scale for source" }
            } else if sr.hasPrefix("fsrcnnx") {
                if sr.contains("metal") {
                    nextSrStatus = "Bypassed · no upscaling needed"
                } else {
                    let name = sr == "fsrcnnx16" ? "FSRCNNX_x2_16-0-4-1" : "FSRCNNX_x2_8-0-4-1"
                    shader = Bundle.main.url(forResource: name, withExtension: "glsl", subdirectory: "Shaders")?.path
                    let passes = String(describing: telemetry.raw["vo-passes"] ?? "")
                    nextSrStatus = shader == nil ? "Error · shader resource missing" : passes.contains(sr == "fsrcnnx16" ? "IIVE FSRCNNX 16 / aggregation" : "IIVE FSRCNNX 8 / aggregation") ? "Active · GPU pass confirmed" : "Verifying GPU shader execution"
                }
            }
        }
        if fiStatus != nextFiStatus { fiStatus = nextFiStatus }
        if srStatus != nextSrStatus { srStatus = nextSrStatus }
        let plan = filters.joined(separator: ",") + "|" + (shader ?? "")
        if plan != lastPlan {
            session?.applyFilters(filters, shader: shader); lastPlan = plan; settledSamples = 0
            if srCompare {
                command(["vf-command", "iive-sr", "split", String(format: "%.4f", srSplitRatio)])
            }
        }
    }
    private func valueBool(_ key: String) -> Bool { telemetry.raw[key] as? Bool ?? false }
    private func state(_ label: String) -> String {
        switch meta(label)["state"] ?? "warming" {
        case "active": return paused ? "Paused · ready" : "Active"
        case "warming": return "Warming model"
        case "finished": return "Finished"
        case "scene-cut-hold": return "Scene cut · holding source"
        case "degraded", "degraded-finished": return "Degraded · processing too slow"
        case "unsupported-or-model-unavailable": return "Unavailable · dimensions or system model"
        case "error-bypass": return "Error · source playback restored"
        default: return "Bypassed · unsupported input"
        }
    }
    func savePosition() {
        lastSave = ProcessInfo.processInfo.systemUptime
        guard resumePlayback, !path.isEmpty, duration > 0 else { return }
        var saved = defaults.dictionary(forKey: "positions") ?? [:]
        saved[path] = position < duration - 10 ? position : 0
        saved = saved.filter { recent.contains($0.key) }
        defaults.set(saved, forKey: "positions")
    }
    func shutdown() { seekPreviewTask?.cancel(); seekPreviewTask = nil; frameActions.close(); liveCaptions.stop(); liveCaptionPlacement = "off"; secondarySubtitleID = "no"; queuePopover = false; quickSettings = false; cancelFolderScan(); queueDateTask?.cancel(); customQueueOrder = []; queueDates = [:]; queueMembership = ""; queueOrderRequest = ""; deferredSnapshot = nil; windowModes.prepareForShutdown(self); savePosition(); session?.shutdown(); windowModes.resetAfterClose(self); session = nil; lastDecoderOption = ""; colorProfileTask?.cancel(); telemetry.reset(); timeline.reset(); enhancementWarming = false; loaded = false; adaptiveLightGlass = false; muted = false; queue = []; chapters = []; queueIndex = -1; path = ""; title = "IIVE Player"; paused = true; audioTracks = []; subtitles = []; audioID = "no"; subtitleID = "no"; srStatus = "Off"; fiStatus = "Off"; error = ""; pendingResume = nil; lastPlan = ""; fileEpoch = ""; menuState.sync(from: self); nowPlaying.clear() }
}
private extension String { var nonempty: String? { isEmpty ? nil : self } }

private func preference(_ key: String, default fallback: Double, range: ClosedRange<Double>) -> Double {
    let value = UserDefaults.standard.object(forKey: key) as? Double ?? fallback
    return value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
}
