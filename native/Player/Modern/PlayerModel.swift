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
@MainActor @Observable final class PlayerTelemetryState {
    @ObservationIgnored var raw: [String: Any] = [:]
    private(set) var snapshot: [String: Any] = [:]
    private(set) var revision: UInt64 = 0

    func update(_ value: [String: Any], visible: Bool) {
        raw = value
        if visible {
            snapshot = value
            revision &+= 1
        }
    }
    func flush() {
        snapshot = raw
        revision &+= 1
    }
    func reset() {
        raw = [:]
        snapshot = [:]
        revision &+= 1
    }
}

/// Recording counters must not broadcast through the window-wide PlayerModel.
@MainActor @Observable final class PlayerDiagnosticsState {
    var samples = 0
    var status = "Idle · 4 Hz sampled JSONL (per-frame raw trace off)"
}

/// Dedicated low-frequency state for the macOS system menu bar (.commands).
/// Decouples NSApp.mainMenu and its 2nd-level submenus from playback telemetry updates.
@MainActor final class PlayerMenuState: ObservableObject {
    @Published var paused = true
    @Published var loaded = false
    @Published var canPrevious = false
    @Published var canNext = false
    @Published var muted = false
    @Published var hasVideo = false
    @Published var hasPath = false
    @Published var fullScreen = false
    @Published var miniPlayer = false
    @Published var floatOnTop = false
    @Published var master = true
    @Published var showVideoInfo = true
    @Published var showSummaryCard = false
    @Published var showTimelinePreview = true
    @Published var inspector = false
    @Published var repeatMode = "off"
    @Published var seekSeconds = 5.0
    @Published var longSeekSeconds = 30.0
    @Published var recent: [String] = []
    @Published var chapters: [MediaChapter] = []
    @Published var playbackShortcutsEnabled = false
    @Published var playerWindowCommandsEnabled = false
    @Published var recordingMetrics = false
    @Published var hasMetricsRecording = false

    func sync(from model: PlayerModel) {
        guard !model.isMenuTracking else { return }
        if paused != model.paused { paused = model.paused }
        if loaded != model.loaded { loaded = model.loaded }
        if hasVideo != model.hasMotionVideo { hasVideo = model.hasMotionVideo }
        if canPrevious != model.canPrevious { canPrevious = model.canPrevious }
        if canNext != model.canNext { canNext = model.canNext }
        if muted != model.muted { muted = model.muted }
        let pathPresent = !model.path.isEmpty
        if hasPath != pathPresent { hasPath = pathPresent }
        if fullScreen != model.fullScreen { fullScreen = model.fullScreen }
        if miniPlayer != model.miniPlayer { miniPlayer = model.miniPlayer }
        if floatOnTop != model.mainWindowFloatOnTop { floatOnTop = model.mainWindowFloatOnTop }
        if master != model.master { master = model.master }
        if showVideoInfo != model.showVideoInfo { showVideoInfo = model.showVideoInfo }
        if showSummaryCard != model.showSummaryCard { showSummaryCard = model.showSummaryCard }
        if showTimelinePreview != model.showTimelinePreview { showTimelinePreview = model.showTimelinePreview }
        if inspector != model.inspector { inspector = model.inspector }
        if repeatMode != model.repeatMode { repeatMode = model.repeatMode }
        if seekSeconds != model.seekSeconds { seekSeconds = model.seekSeconds }
        if longSeekSeconds != model.longSeekSeconds { longSeekSeconds = model.longSeekSeconds }
        if recent != model.recent { recent = model.recent }
        let nextChapters = model.chapters
        let orderedChapters = nextChapters.sorted { $0.time < $1.time }
        if chapters != orderedChapters { chapters = orderedChapters }
        if recordingMetrics != model.recordingMetrics { recordingMetrics = model.recordingMetrics }
        let hasSaved = model.lastMetricsURL != nil
        if hasMetricsRecording != hasSaved { hasMetricsRecording = hasSaved }
        syncKeyboardFocus(from: model)
    }
    func syncKeyboardFocus(from model: PlayerModel) {
        let context = model.playbackInputContext
        if playbackShortcutsEnabled != context.allowsTransportKeys { playbackShortcutsEnabled = context.allowsTransportKeys }
        if playerWindowCommandsEnabled != context.allowsWindowCommands { playerWindowCommandsEnabled = context.allowsWindowCommands }
    }
}

/// Lightweight transient OSD status toast state (e.g. Volume, Speed, Mute, cumulative Skip, Enhancement toggle),
/// migrated to Swift `Observation` for per-property tracking in `OSDToastView`.
@MainActor @Observable final class PlayerOSDState {
    var symbol = ""
    var text = ""
    var visible = false
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var accumulatedSkip = 0.0
    @ObservationIgnored private var lastSkipUptime = 0.0

    func show(_ text: String.LocalizationValue, symbol: String) {
        accumulatedSkip = 0
        self.symbol = symbol
        self.text = String(localized: text)
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
    let systemHDRPlayback = SystemHDRPlayback()
    @Published var systemHDRActive = false
    @Published var automaticSystemHDR = UserDefaults.standard.object(forKey: "automaticSystemHDR") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automaticSystemHDR, forKey: "automaticSystemHDR") }
    }
    private var systemHDRAttempt = ""
    func markSystemHDRAttempt() {
        systemHDRAttempt = "\(path)|\((snapshot["media-epoch"] as? NSNumber)?.uint64Value ?? 0)"
    }
    let menuState = PlayerMenuState()
    let nowPlaying = PlayerNowPlayingController()
    let timeline = PlayerTimelineState()
    let timelinePreviews = TimelinePreviewGenerator()
    let audioArtwork = AudioArtworkState()
    @Published var audioOnly = false
    @Published var hasMotionVideo = false {
        didSet {
            menuState.sync(from: self)
            videoView?.setLuminanceSamplingEnabled(chromeTheme == "adaptive" && hasMotionVideo)
            if !hasMotionVideo { adaptiveLightGlass = false }
        }
    }
    @Published var audioArtist = ""
    @Published var audioAlbum = ""
    private var seekPreviewTask: Task<Void, Never>?
    private var scrubPath: String?
    let telemetry = PlayerTelemetryState()
    let osd = PlayerOSDState()
    let liveCaptions = LiveCaptionController()

    @Published var title = PlayerIdentity.displayName
    @Published var showNetworkSheet = false
    @Published var networkBuffering = false
    @Published var networkReconnecting = false
    @Published var networkRetryAvailable = false
    @Published var networkRetryAttempt = 0
    @Published var rememberNetworkProgress = UserDefaults.standard.object(forKey: "rememberNetworkProgress") as? Bool ?? true {
        didSet { defaults.set(rememberNetworkProgress, forKey: "rememberNetworkProgress") }
    }
    @Published var networkResumeStatus = ""
    let remotePlaybackMemory = RemotePlaybackMemory()
    var remotePlaybackContext: (key: String, identity: String, revision: String)?
    private(set) var metadataPriorityRevision: UInt64 = 0
    @Published var remoteMetadataDeferred = false {
        didSet {
            guard remoteMetadataDeferred != oldValue else { return }
            metadataPriorityRevision &+= 1
            let revision = metadataPriorityRevision, suspended = remoteMetadataDeferred
            let cache = remoteMetadata
            Task { await cache.setPlaybackPriority(suspended: suspended, revision: revision) }
        }
    }
    @Published var networkCachePolicy = NetworkCachePolicy(rawValue: UserDefaults.standard.string(forKey: "networkCachePolicy") ?? "") ?? .balanced {
        didSet { defaults.set(networkCachePolicy.rawValue, forKey: "networkCachePolicy") }
    }
    var metadataContinuity = PlaybackContinuityGate()
    var performanceContinuity = PlaybackContinuityGate()
    @Published private(set) var transportTitle = ""
    @Published private(set) var transportArtwork: NSImage? = nil
    private var transportArtworkPath = ""
    private var transportArtworkTask: Task<Void, Never>?
    @Published private(set) var resumedFrom: Double?
    private var resumeNotice = PlaybackResumeNotice()
    @Published private(set) var playbackActivity: PlaybackActivity = .idle
    @Published private(set) var mediaOpening = false
    @Published private(set) var mediaSwitch = MediaSwitchPresentation()
    /// True whenever media is loaded or actively transitioning to another item, keeping UI controls mounted continuously.
    var hasActiveMediaSession: Bool { loaded || mediaSwitch.active }
    func beginMediaSwitch() {
        frameActions.textSession.close()
        subtitleDiscoveryTask?.cancel(); subtitleDiscoveryTask = nil
        seekPreviewTask?.cancel(); seekPreviewTask = nil
        transportArtworkTask?.cancel(); transportArtworkTask = nil
        transportArtworkPath = ""
        // Cancel obsolete preview decoders at navigation intent, not only after
        // mpv publishes the next path. Shared artwork caches remain reusable.
        let previous = path, previews = timelinePreviews
        Task { await previews.cancel(for: previous) }
        var state = mediaSwitch
        state.begin(epoch: (snapshot["media-epoch"] as? NSNumber)?.uint64Value ?? 0,
                    now: ProcessInfo.processInfo.systemUptime)
        mediaSwitch = state
        prioritizePlaybackIO()
    }
    func stopMediaSwitch() { var state = mediaSwitch; state.stop(); mediaSwitch = state }

    var transportTitleHovered = false
    private var mediaTitleNotice = MediaTitleNotice()
    @Published var mediaSeekable = true
    var pendingNetwork: (NetworkMediaRequest, Bool)?
    var pendingRemote: RemoteQueueRequest?
    private(set) var remoteNextRevision: UInt64 = 0
    var remoteEntries: [String: RemoteQueueEntry] = [:] { didSet { cachedPlaylist = nil } }
    private var cachedPlaylist: NSArray?
    private var cachedChapters: NSArray?
    var remoteResolution: Task<Void, Never>?
    let remoteMetadata = RemoteQueueMetadataCache()
    @Published var path = "" {
        didSet {
            if path != oldValue {
                cancelScrubbing(for: oldValue)
                seekPreviewTask?.cancel(); seekPreviewTask = nil
                let previous = oldValue, previews = timelinePreviews
                Task { await previews.cancel(for: previous) }
                frameActions.loadMarkers()
            }
            menuState.sync(from: self)
        }
    }
    let fileDialogs = PlayerFileDialogs()
    lazy var frameActions = FrameActions(model: self)
    @Published var markers: [PlaybackMarker] = []
    @Published var screenshotFolder = UserDefaults.standard.string(forKey: "screenshotFolder") ?? "" {
        didSet { UserDefaults.standard.set(screenshotFolder, forKey: "screenshotFolder") }
    }
    @Published var paused = true { didSet { menuState.sync(from: self) } }
    var position: Double { timeline.position }
    var duration: Double { timeline.duration }
    var snapshot: [String: Any] { telemetry.raw }
    @Published var loaded = false { didSet { menuState.sync(from: self); updateTelemetryDemand() } }
    @Published var muted = false { didSet { menuState.sync(from: self) } }
    @Published var queue: [QueueItem] = [] { didSet { menuState.sync(from: self) } }
    @Published var chapters: [MediaChapter] = [] { didSet { menuState.sync(from: self) } }
    @Published var queueIndex = -1 { didSet { menuState.sync(from: self) } }
    @Published var volume = 50.0
    @Published var speed = 1.0
    @Published var master = true { didSet { if preferencesReady { configure(); menuState.sync(from: self); osd.show(master ? "Enhancement On" : "Enhancement Off", symbol: "sparkles") } } }
    @Published var sr: String {
        didSet {
            if preferencesReady {
                if !supportsSRComparison && srCompare { srCompare = false }
                configure()
            }
        }
    }
    @Published var fi: String { didSet { if preferencesReady { configure() } } }
    @Published var tier: String { didSet { if preferencesReady { configure() } } }
    @Published var targetFPS: Int { didSet { if preferencesReady { configure() } } }
    @Published var automatic: Bool { didSet { if preferencesReady { configure() } } }
    @Published var srCompare = false {
        didSet {
            guard oldValue != srCompare else { return }
            let ratio = srCompare ? srSplitRatio : 0.0
            apply()
            if supportsSRComparison {
                session?.updateSplit(ratio, expectedPath: path)
            }
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
            if srCompare && supportsSRComparison {
                session?.updateSplit(srSplitRatio, expectedPath: path)
            }
        }
    }
    var supportsSRComparison: Bool { ["fsrcnnx_metal8", "fsrcnnx_metal16"].contains(sr) }
    var isSRSplitActive: Bool {
        let metadata = meta("iive-sr")
        let expected = sr == "fsrcnnx_metal16" ? "fsrcnnx16-mpsgraph" : "fsrcnnx8-mpsgraph"
        return srCompare && supportsSRComparison && master && !fallback && loaded && !miniPlayer && nativeSRColorSupported &&
            metadata["backend"] == expected && ["active", "finished"].contains(metadata["state"] ?? "") &&
            (Double(metadata["split_ratio"] ?? "") ?? 0) > 0
    }
    var lastRestartedToStartAt = 0.0
    var lastRestartedPath = ""
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
    @Published var mainWindowFloatOnTop = UserDefaults.standard.bool(forKey: "mainWindowFloatOnTop") {
        didSet {
            defaults.set(mainWindowFloatOnTop, forKey: "mainWindowFloatOnTop")
            windowModes.updateMainWindowLevel(self)
            menuState.sync(from: self)
        }
    }
    func toggleFloatOnTop() {
        mainWindowFloatOnTop.toggle()
        osd.show(mainWindowFloatOnTop ? "Float on Top On" : "Float on Top Off", symbol: mainWindowFloatOnTop ? "pin.fill" : "pin.slash")
    }
    @Published var miniAlwaysOnTop = UserDefaults.standard.object(forKey: "miniAlwaysOnTop") as? Bool ?? true {
        didSet { defaults.set(miniAlwaysOnTop, forKey: "miniAlwaysOnTop"); windowModes.updatePolicy(self) }
    }
    @Published var miniAllSpaces = UserDefaults.standard.object(forKey: "miniAllSpaces") as? Bool ?? true {
        didSet { defaults.set(miniAllSpaces, forKey: "miniAllSpaces"); windowModes.updatePolicy(self) }
    }
    private var srScaleEligible = false
    @Published var rememberMediaSelections = UserDefaults.standard.object(forKey: "rememberMediaSelections") as? Bool ?? true {
        didSet { defaults.set(rememberMediaSelections, forKey: "rememberMediaSelections") }
    }
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
            updateTelemetryDemand()
            menuState.sync(from: self)
        }
    }
    @Published var sidebarTab = "queue" { didSet { updateTelemetryDemand() } }
    @Published var queuePopover = false
    @Published var quickSettings = false
    @Published var miniPlayer = false { didSet { menuState.sync(from: self); updateTelemetryDemand() } }
    @Published var windowTransition = false
    var liveResizing = false { didSet { updateTelemetryDemand() } }
    var enhancementPlanResumeAt = 0.0
    let windowModes = PlayerWindowModes()
    lazy var windowLifecycle = PlayerWindowLifecycle(model: self)
    @Published var autoQueueFolder = UserDefaults.standard.bool(forKey: "autoQueueFolder") {
        didSet {
            defaults.set(autoQueueFolder, forKey: "autoQueueFolder")
            cancelFolderScan()
            folderQueueStatus = ""
            if autoQueueFolder { scanCurrentMediaFolder() }
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

    private var lastFittedVideoKey = ""
    private var lastScrollSeekAt = 0.0

    @Published var rotation = UserDefaults.standard.integer(forKey: "videoRotation") {
        didSet {
            UserDefaults.standard.set(rotation, forKey: "videoRotation")
            command(["set", "video-rotate", String(rotation)])
            windowModes.updateMediaAspect(self)
        }
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
            videoView?.setLuminanceSamplingEnabled(chromeTheme == "adaptive" && hasMotionVideo)
            applyMiniWindowAppearance()
        }
    }
    @Published var adaptiveLightGlass = false {
        didSet {
            if oldValue != adaptiveLightGlass {
                applyMiniWindowAppearance()
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

    /// The main SwiftUI Window uses preferredColorScheme. Only the separately
    /// hosted AppKit mini panel needs an explicit native appearance fallback.
    func applyMiniWindowAppearance() {
        let appearance = effectiveChromeColorScheme.flatMap {
            NSAppearance(named: $0 == .light ? .aqua : .darkAqua)
        }
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
    var browserQueuePathOrder: [String] = []
    var pendingPlayNextPaths: [String] = []
    var queueDates: [Int64: Date] = [:]
    var queueDateTask: Task<Void, Never>?
    var queueMembership = ""
    var queueDateMembership = ""
    var queueOrderRequest = ""
    private var volumeAdjustedAt = 0.0

    @Published var fullScreen = false { didSet { menuState.sync(from: self); updateTelemetryDemand() } }
    @Published var showVideoInfo = UserDefaults.standard.object(forKey: "showVideoInfo") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showVideoInfo, forKey: "showVideoInfo")
            updateTelemetryDemand()
            menuState.sync(from: self)
        }
    }
    @Published var showSummaryCard: Bool = {
        if let saved = UserDefaults.standard.object(forKey: "showSummaryCard") as? Bool {
            return saved
        }
        return UserDefaults.standard.string(forKey: "videoInfoMode") == "full"
    }() {
        didSet {
            UserDefaults.standard.set(showSummaryCard, forKey: "showSummaryCard")
            menuState.sync(from: self)
        }
    }
    var hasAnyHUDCard: Bool { showVideoInfo || showSummaryCard }
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
    let playbackPreferences = PlaybackPreferences()
    let playbackGeometry = PlaybackGeometry()
    @Published var deinterlaceMode: String = {
        let saved = UserDefaults.standard.string(forKey: "deinterlaceMode") ?? "no"
        return ["no", "auto", "yes"].contains(saved) ? saved : "no"
    }() {
        didSet { applyDeinterlace() }
    }
    var lastDeinterlaceMode = ""
    @Published var subtitleID = "no"
    @Published var secondarySubtitleID = "no"
    @Published var liveCaptionPlacement = "off"
    @Published var autoLoadExternalSubtitles = UserDefaults.standard.object(forKey: "autoLoadExternalSubtitles") as? Bool ?? true {
        didSet { defaults.set(autoLoadExternalSubtitles, forKey: "autoLoadExternalSubtitles") }
    }
    @Published var subtitleBorderStyle = UserDefaults.standard.string(forKey: "subtitleBorderStyle") ?? "outline" {
        didSet {
            defaults.set(subtitleBorderStyle, forKey: "subtitleBorderStyle")
            applySubtitleAppearance()
        }
    }
    @Published var subtitleOutlineSize = UserDefaults.standard.string(forKey: "subtitleOutlineSize") ?? "standard" {
        didSet {
            defaults.set(subtitleOutlineSize, forKey: "subtitleOutlineSize")
            applySubtitleAppearance()
        }
    }
    @Published var secondarySubtitlePosition = UserDefaults.standard.string(forKey: "secondarySubtitlePosition") ?? "below" {
        didSet {
            defaults.set(secondarySubtitlePosition, forKey: "secondarySubtitlePosition")
            applySubtitleAppearance()
        }
    }
    @Published var bilingualSubtitleSpacing = UserDefaults.standard.string(forKey: "bilingualSubtitleSpacing") ?? "compact" {
        didSet {
            defaults.set(bilingualSubtitleSpacing, forKey: "bilingualSubtitleSpacing")
            applySubtitleAppearance()
        }
    }
    @Published var subtitleFontSize = preference("subtitleFontSize", default: 38, range: 18...96) {
        didSet {
            defaults.set(subtitleFontSize, forKey: "subtitleFontSize")
            applySubtitleAppearance()
        }
    }
    @Published var subtitleColor = UserDefaults.standard.string(forKey: "subtitleColor") ?? "#FFFFFFFF" {
        didSet {
            defaults.set(subtitleColor, forKey: "subtitleColor")
            applySubtitleAppearance()
        }
    }
    @Published var secondarySubtitleFontSize = preference("secondarySubtitleFontSize", default: 32, range: 18...96) {
        didSet {
            defaults.set(secondarySubtitleFontSize, forKey: "secondarySubtitleFontSize")
            applySubtitleAppearance()
        }
    }
    @Published var secondarySubtitleColor = UserDefaults.standard.string(forKey: "secondarySubtitleColor") ?? "#FFFFFFFF" {
        didSet {
            defaults.set(secondarySubtitleColor, forKey: "secondarySubtitleColor")
            applySubtitleAppearance()
        }
    }
    @Published var subtitleFont = UserDefaults.standard.string(forKey: "subtitleFont") ?? "sans-serif" {
        didSet {
            defaults.set(subtitleFont, forKey: "subtitleFont")
            applySubtitleAppearance()
        }
    }
    @Published var subtitleOverrideASS = UserDefaults.standard.object(forKey: "subtitleOverrideASS") as? Bool ?? true {
        didSet {
            defaults.set(subtitleOverrideASS, forKey: "subtitleOverrideASS")
            applySubtitleAppearance()
        }
    }
    @Published var captionLanguage = UserDefaults.standard.string(forKey: "captionLanguage") ?? "en-US" {
        didSet { defaults.set(captionLanguage, forKey: "captionLanguage"); updateLiveCaptions() }
    }
    func applySubtitleAppearance() {
        guard let session else { return }
        let font = subtitleFont.trimmingCharacters(in: .whitespacesAndNewlines)
        let primarySize = max(18.0, min(96.0, subtitleFontSize))
        let secondarySize = max(18.0, min(96.0, secondarySubtitleFontSize))
        let primaryScale = max(0.5, min(2.5, number("sub-scale") ?? 1.0))
        let secondaryScale = max(0.1, min(10.0, (secondarySize / primarySize) * primaryScale))

        session.command(["set", "sub-font", font.isEmpty ? "sans-serif" : font])
        session.command(["set", "sub-font-size", String(Int(primarySize.rounded()))])
        session.command(["set", "sub-color", subtitleColor])
        session.command(["set", "secondary-sub-color", secondarySubtitleColor])
        session.command(["set", "secondary-sub-scale", String(format: "%.4f", secondaryScale)])

        let isBox = subtitleBorderStyle == "box"
        let borderSize = subtitleOutlineSize == "thin" ? "1.0" : subtitleOutlineSize == "bold" ? "2.6" : "1.65"
        session.command(["set", "sub-border-style", isBox ? "opaque-box" : "outline-and-shadow"])
        session.command(["set", "sub-back-color", isBox ? "#B0000000" : "#AF000000"])
        session.command(["set", "sub-border-size", isBox ? "4.0" : borderSize])
        session.command(["set", "sub-shadow-offset", isBox ? "0.0" : "1.2"])

        let hasSecondary = secondarySubtitleID != "no" || liveCaptionPlacement == "top"
        let placeBelow = secondarySubtitlePosition == "below"
        // Two spacing tiers measured strictly from upper subtitle bottom to lower subtitle top in 720p PlayResY px:
        // "compact" (-2.0 px trims outer outline padding so strokes sit ~2 px apart), "standard" (+6.0 px).
        let stackGapPlayRes = bilingualSubtitleSpacing == "standard" ? 6.0 : -2.0
        session.command(["set", "sub-stack-gap", (placeBelow && hasSecondary) ? String(format: "%.1f", stackGapPlayRes) : "-100"])

        // Fallback single-line offset when only primary subtitle is visible at the current timestamp.
        let singleLineOffset = max(2.2, min(12.0, ((secondarySize * primaryScale * 0.78 + max(0.0, stackGapPlayRes)) / 686.0) * 100.0))
        let primaryPos = (placeBelow && hasSecondary) ? max(80.0, 100.0 - singleLineOffset) : 100.0
        let secondaryPos = placeBelow ? 100.0 : 0.0
        session.command(["set", "sub-ass-override", (subtitleOverrideASS || (placeBelow && hasSecondary)) ? "force" : "scale"])
        session.command(["set", "secondary-sub-ass-override", "strip"])
        session.command(["set", "sub-pos", String(format: "%.1f", primaryPos)])
        session.command(["set", "secondary-sub-pos", String(format: "%.1f", secondaryPos)])
    }
    func resetSubtitleAppearanceAndTiming() {
        command(["set", "audio-delay", "0"])
        command(["set", "sub-delay", "0"])
        command(["set", "secondary-sub-delay", "0"])
        command(["set", "sub-scale", "1"])
        subtitleBorderStyle = "outline"
        subtitleOutlineSize = "standard"
        bilingualSubtitleSpacing = "compact"
        subtitleFontSize = 38
        subtitleColor = "#FFFFFFFF"
        secondarySubtitleFontSize = 32
        secondarySubtitleColor = "#FFFFFFFF"
        subtitleFont = "sans-serif"
        subtitleOverrideASS = true
        applySubtitleAppearance()
    }
    func updateLiveCaptions(download: Bool = false) {
        guard !systemHDRActive else { liveCaptions.stop(); return }
        liveCaptions.update(session: session, path: path, audio: audioID, language: captionLanguage,
            enabled: liveCaptionPlacement != "off", position: position - (number("audio-delay") ?? 0), paused: paused,
            seeking: snapshot["seeking"] as? Bool == true, download: download)
    }
    func showSystemPlaybackLimitation() {
        osd.show("This feature requires mpv playback. Return to mpv in Picture & Color.", symbol: "info.circle")
    }
    func selectSubtitle(_ id: String, secondary: Bool) {
        if systemHDRActive {
            guard !secondary, id != "live" else { showSystemPlaybackLimitation(); return }
            command(["set", "sid", id])
            return
        }
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
        applySubtitleAppearance()
        updateLiveCaptions()
    }
    @Published var fallback = false
    @Published var recordingMetrics = false { didSet { menuState.sync(from: self) } }
    let diagnostics = PlayerDiagnosticsState()
    var recordedMetricsSamples: Int {
        get { diagnostics.samples }
        set { if diagnostics.samples != newValue { diagnostics.samples = newValue } }
    }
    @Published var lastMetricsURL: URL? { didSet { menuState.sync(from: self) } }
    var metricsStatus: String {
        get { diagnostics.status }
        set { if diagnostics.status != newValue { diagnostics.status = newValue } }
    }
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
    let playbackMemory = PlaybackMemory()
    private var localMemoryContext: (path: String, stamp: PlaybackFileStamp)?
    private var localPreparationTask: Task<Void, Never>?
    private var subtitleDiscoveryTask: Task<Void, Never>?
    var playbackMemoryGeneration: UInt64 = 0
    private var skipResumePath: String?
    private var badSamples = 0
    private var previousDrops = 0.0
    private var settledSamples = 0
    private var rifePerformance = RIFEPerformancePolicy()
    private var lastPerformanceState: [String: String] = [:]
    private var lastSave = 0.0
    private var fileEpoch = ""
    private let defaults = UserDefaults.standard
    private var menuObservers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    lazy var keyboardFocus = PlayerKeyboardFocus(model: self)

    init() {
        // Retire the unstable presenter, including previously persisted opt-in.
        // IIVE_EXPERIMENTAL_EDR is deliberately no longer read by the application.
        UserDefaults.standard.removeObject(forKey: "experimentalEDRPresenter")
        sr = defaults.string(forKey: "sr") ?? "fsrcnnx_metal8"
        fi = defaults.string(forKey: "fi") ?? "apple"
        tier = defaults.string(forKey: "tier") ?? "fast"
        targetFPS = defaults.integer(forKey: "fps") == 60 ? 60 : 48
        automatic = defaults.object(forKey: "automatic") as? Bool ?? true
        recent = (defaults.stringArray(forKey: "recent") ?? []).filter { $0.hasPrefix("/") }
        defaults.set(recent, forKey: "recent")
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
        _ = keyboardFocus
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.keyboardFocus.handle(event) ?? false }
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
        view.onScrollSeek = { [weak self] deltaSeconds in
            MainActor.assumeIsolated {
                guard let self, self.loaded, self.mediaSeekable, self.duration > 0 else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard now - self.lastScrollSeekAt >= 0.04 else { return }
                self.lastScrollSeekAt = now
                let step = max(-30.0, min(30.0, deltaSeconds))
                guard abs(step) >= 0.25 else { return }
                let target = min(self.duration, max(0, self.position + step))
                self.seek(target)
                self.osd.showSkip(delta: step)
            }
        }
        view.onMagnify = { [weak self] magnification in
            MainActor.assumeIsolated {
                guard let self, self.loaded, !self.windowTransition else { return }
                if magnification > 0 {
                    if self.miniPlayer {
                        self.toggleMiniPlayer()
                    } else if !self.fullScreen {
                        self.toggleFullScreen()
                    }
                } else if magnification < 0 {
                    if self.fullScreen {
                        self.toggleFullScreen()
                    } else if !self.miniPlayer, self.hasMotionVideo {
                        self.toggleMiniPlayer()
                    }
                }
            }
        }
        remoteNextRevision = 0
        session = MPVSession(view: view)
        guard let session else { error = "Unable to initialize the playback renderer."; return }
        session.onPrepareLocal = { [weak self, weak session] path, hook in
            MainActor.assumeIsolated { if let session { self?.prepareLocalPlayback(path, hook: hook, session: session) } }
        }
        session.onResolveNetwork = { [weak self, weak session] key, hook in
            MainActor.assumeIsolated { if let session { self?.resolveRemote(key, hook: hook, session: session) } }
        }
        session.onSnapshot = { [weak self] value in
            MainActor.assumeIsolated { self?.receive(value as? [String: Any] ?? [:]) }
        }
        updateTelemetryDemand()
        if let cliMetrics = session.activeMetricsPath(), !cliMetrics.isEmpty {
            let url = URL(fileURLWithPath: cliMetrics)
            lastMetricsURL = url
            recordingMetrics = true
            metricsStatus = "Recording to \(url.lastPathComponent)…"
        }
        command(["set", "volume", String(volume)])
        session.configureTrackPreferences(playbackPreferences.trackOptions)
        session.selectPreferredAudioDevice(playbackPreferences.audioDevice)
        command(["set", "deinterlace", deinterlaceMode])
        lastDeinterlaceMode = deinterlaceMode
        applyRepeat()
        applyPictureSettings()
        applySubtitleAppearance()
        applyDecoder()
        applyMiniWindowAppearance()
        view.setLuminanceSamplingEnabled(chromeTheme == "adaptive" && hasMotionVideo)
        if let pending = pendingRemote {
            pendingRemote = nil
            if pending.playNext { playNextRemoteBatch(pending.explicitItems ?? [pending.item], origin: pending.origin) }
            else { openRemote(pending.item, siblings: pending.siblings, origin: pending.origin, append: pending.append, explicitItems: pending.explicitItems) }
        }
        else if let pending = pendingNetwork { pendingNetwork = nil; openNetwork(pending.0, append: pending.1) }
        else if let pending = pendingQueue { pendingQueue = nil; openFiles(pending.0, append: pending.1) }
        else if let pending = pendingOpen { pendingOpen = nil; open(pending.0, resume: pending.1) }
        else if !openedLaunchInput, let input = argument("--input") { openedLaunchInput = true; open((try? NetworkMediaRequest.parse(input)) ?? URL(fileURLWithPath: input), resume: false) }
    }
    func command(_ args: [String]) {
        // A new explicit navigation operation supersedes the held seek target.
        let operation = args.first ?? ""
        if operation == "set", args.count >= 3, args[1] == "pause", args[2] == "no" { frameActions.textSession.close() }
        if systemHDRActive, args.count >= 2 {
            if operation == "set", args.count >= 3 {
                switch args[1] {
                case "pause": systemHDRPlayback.setPaused(args[2] == "yes"); return
                case "speed": systemHDRPlayback.setSpeed(Double(args[2]) ?? 1); return
                case "volume": systemHDRPlayback.setVolume(Double(args[2]) ?? 100); return
                case "mute": systemHDRPlayback.player?.isMuted = args[2] == "yes"; return
                case "aid", "sid":
                    if let message = systemHDRPlayback.selectTrack(args[1], id: args[2]) {
                        osd.show("\(message)", symbol: "captions.bubble")
                    }
                    return
                case "secondary-sid":
                    if args[2] != "no" { showSystemPlaybackLimitation() }
                    return
                default: break
                }
            } else if operation == "cycle", args[1] == "pause" { systemHDRPlayback.togglePause(); return }
            else if operation == "cycle", args[1] == "mute" { systemHDRPlayback.toggleMute(); return }
            else if operation == "seek", let seconds = Double(args[1]) {
                systemHDRPlayback.seek(seconds, relative: args.count < 3 || !args[2].contains("absolute")); return
            }
        }
        if systemHDRActive, operation == "frame-step" || operation == "frame-back-step" {
            systemHDRPlayback.step(backward: operation == "frame-back-step"); return
        }
        let replacingFile = operation == "loadfile" && (args.count < 3 || args[2] == "replace")
        if systemHDRActive, replacingFile || ["stop", "playlist-next", "playlist-prev", "playlist-play-index"].contains(operation) {
            systemHDRPlayback.close(restoring: false)
        }
        if replacingFile || ["playlist-next", "playlist-prev", "playlist-play-index"].contains(operation) { beginMediaSwitch() }
        if operation == "stop" { stopMediaSwitch() }
        let changesPause = args.count > 1 && args[1] == "pause" && ["set", "cycle"].contains(operation)
        let frameStep = operation == "frame-step" || operation == "frame-back-step"
        if frameStep {
            // The native frame command ends scrubbing without briefly resuming
            // playback. Discard a late thumbnail task for the superseded seek.
            scrubPath = nil
            seekPreviewTask?.cancel(); seekPreviewTask = nil
            timeline.cancelSeek()
            rifePerformance.suspend()
            settledSamples = 0
            prioritizePlaybackIO()
        } else if replacingFile || changesPause || ["seek", "stop", "playlist-next", "playlist-prev"].contains(operation) {
            cancelScrubbing()
            timeline.cancelSeek()
        }
        if replacingFile || ["stop", "playlist-next", "playlist-prev", "playlist-play-index"].contains(operation) { subtitleDiscoveryTask?.cancel() }
        if replacingFile || ["seek", "playlist-next", "playlist-prev"].contains(operation) { prioritizePlaybackIO() }
        session?.command(args)
    }
    func loadExternalSubtitle(_ url: URL, secondary: Bool = false, showOSD: Bool = true) {
        if systemHDRActive { if showOSD { showSystemPlaybackLimitation() }; return }
        if liveCaptionPlacement == (secondary ? "top" : "bottom") {
            liveCaptionPlacement = "off"
            updateLiveCaptions()
        }
        session?.loadSubtitle(url.path, secondary: secondary)
        if showOSD {
            osd.show("Subtitle Loaded · \(url.lastPathComponent)", symbol: "captions.bubble.fill")
        }
    }

    private func autoLoadMatchingSubtitles(for videoURL: URL) {
        subtitleDiscoveryTask?.cancel()
        guard autoLoadExternalSubtitles else { return }
        subtitleDiscoveryTask = Task { [weak self] in
            let match = await Task.detached(priority: .utility) {
                FolderMedia.matchingSubtitles(for: videoURL)
            }.value
            guard !Task.isCancelled, let self, self.path == videoURL.path,
                  self.loaded, self.autoLoadExternalSubtitles else { return }
            if let primary = match.primary {
                self.loadExternalSubtitle(primary, secondary: false, showOSD: false)
            }
            if let secondary = match.secondary {
                self.loadExternalSubtitle(secondary, secondary: true, showOSD: false)
            }
        }
    }

    func openPanel(subtitle: Bool = false, append: Bool = false, secondary: Bool = false) {
        fileDialogs.importFiles(title: subtitle ? "Load Subtitles" : append ? "Add to Play Queue" : "Open Media",
                                multiple: !subtitle) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                if subtitle {
                    self.loadExternalSubtitle(url, secondary: secondary)
                } else { self.openFiles(urls, append: append) }
            case .failure(let error): self.error = "Could not open file: " + error.localizedDescription
            }
        }
    }

    func openFiles(_ urls: [URL], append: Bool = false) {
        let localURLs = urls.filter(\.isFileURL)
        guard !localURLs.isEmpty else { error = String(localized: "Please choose local media files."); return }
        let expanded = FolderMedia.expandDroppedURLs(localURLs)
        let media = expanded.media
        let droppedSubs = expanded.subtitles

        if media.isEmpty, !droppedSubs.isEmpty {
            guard loaded || !path.isEmpty else {
                error = String(localized: "Open a video first before loading external subtitles.")
                return
            }
            for (index, subURL) in droppedSubs.prefix(2).enumerated() {
                loadExternalSubtitle(subURL, secondary: index == 1)
            }
            return
        }
        guard !media.isEmpty else {
            error = String(localized: "No supported media files found in the dropped items.")
            return
        }
        pendingRemote = nil
        pendingNetwork = nil
        guard session != nil else { pendingOpen = nil; pendingQueue = (media, append); return }
        cancelFolderScan()
        if append {
            // append+play starts only when nothing is playing; append leaves the
            // current item and its pause state intact.
            for url in media { command(["loadfile", url.path, "append+play"]) }
            if expanded.expandedFolders > 0 || media.count > 1 {
                folderQueueStatus = String(localized: "Added \(media.count) files to the play queue.")
                osd.show("Added \(media.count) to Queue", symbol: "text.badge.plus")
            }
        } else {
            open(media[0], scanFolder: media.count == 1 && expanded.expandedFolders == 0)
            for url in media.dropFirst() { command(["loadfile", url.path, "append"]) }
            if expanded.expandedFolders > 0 && media.count > 1 {
                folderQueueStatus = String(localized: "Added \(media.count) files from folder.")
            }
        }
        if !droppedSubs.isEmpty {
            for (index, subURL) in droppedSubs.prefix(2).enumerated() {
                loadExternalSubtitle(subURL, secondary: index == 1)
            }
        }
    }
    func open(_ url: URL, resume: Bool = true, scanFolder: Bool = true) {
        guard url.isFileURL else {
            do { openNetwork(try NetworkMediaRequest(url: url)) } catch { self.error = error.localizedDescription }
            return
        }
        pendingNetwork = nil
        guard session != nil else { pendingQueue = nil; pendingOpen = (url, resume); return }
        savePosition()
        cancelFolderScan()
        skipResumePath = resume ? nil : url.path
        fallback = false; lastPlan = ""; settledSamples = 0; error = ""
        var updatedRecent = recent
        updatedRecent.removeAll { $0 == url.path }
        updatedRecent.insert(url.path, at: 0)
        updatedRecent = Array(updatedRecent.prefix(12))
        if recent != updatedRecent {
            recent = updatedRecent
            defaults.set(recent, forKey: "recent")
        }
        applyDecoder()
        command(["loadfile", url.path, "replace"])
        updateTransportArtwork(for: url.path, allowRead: false)
        if autoQueueFolder && scanFolder { enqueueFolder(around: url) }
    }
    func clearPendingMediaOpen() { pendingOpen = nil; pendingQueue = nil; pendingNetwork = nil; pendingRemote = nil }
    func prepareRemoteReplacement() {
        systemHDRPlayback.close(restoring: false)
        beginMediaSwitch()
        cancelScrubbing(); timeline.cancelSeek(); savePosition(); skipResumePath = nil
        fallback = false; lastPlan = ""; settledSamples = 0
    }
    func openNetwork(_ request: NetworkMediaRequest, append: Bool = false) {
        if !append { systemHDRPlayback.close(restoring: false) }
        pendingRemote = nil
        guard let session else { pendingOpen = nil; pendingQueue = nil; pendingNetwork = (request, append); return }
        cancelFolderScan()
        if !append { cancelScrubbing(); timeline.cancelSeek(); savePosition(); skipResumePath = nil; fallback = false; lastPlan = ""; settledSamples = 0 }
        if !append || !loaded { beginMediaSwitch() }
        error = ""; applyDecoder()
        // Remote URLs (including signed queries) and credentials are not persisted.
        session.loadNetworkURL(request.url.absoluteString,
            options: networkCachePolicy.applying(to: request.options, url: request.url), append: append)
    }
    func togglePause() {
        frameActions.textSession.close()
        if systemHDRActive { systemHDRPlayback.togglePause(); return }
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
    // Reserve bandwidth immediately; don't wait for the next 250 ms engine poll.
    func prioritizePlaybackIO() {
        _ = metadataContinuity.update(now: ProcessInfo.processInfo.systemUptime, interruption: "interaction")
        if !remoteMetadataDeferred { remoteMetadataDeferred = true }
    }
    func previewScrub(to value: Double, expectedPath: String) {
        if systemHDRActive {
            if path == expectedPath { systemHDRPlayback.seek(value, relative: false) }
            return
        }
        guard snapshot["seekable"] as? Bool != false, loaded, path == expectedPath, value.isFinite, duration > 0, let session else { return }
        prioritizePlaybackIO()
        dismissResumeNotice()
        if scrubPath == nil {
            scrubPath = path
            timeline.cancelSeek()
            seekPreviewTask?.cancel(); seekPreviewTask = nil
        }
        guard scrubPath == path else { return }
        rifePerformance.suspend()
        settledSamples = 0
        session.previewScrub(to: min(duration, max(0, value)), expectedPath: path)
    }
    func cancelScrubbing(for expectedPath: String? = nil) {
        guard let current = scrubPath, expectedPath == nil || expectedPath == current else { return }
        scrubPath = nil
        session?.cancelScrub(forPath: current)
    }
    func seek(_ value: Double, relative: Bool = false) {
        frameActions.textSession.close()
        if systemHDRActive { systemHDRPlayback.seek(value, relative: relative); return }
        guard value.isFinite, let session, loaded, telemetry.raw["seekable"] as? Bool != false else { return }
        prioritizePlaybackIO()
        dismissResumeNotice()
        rifePerformance.suspend()
        if relative { cancelScrubbing() }
        else { scrubPath = nil } // the final native seek restores the pre-drag play state
        settledSamples = 0
        if !relative, let request = timeline.beginSeek(to: value, path: path) {
            session.seek(toSeconds: request.target, expectedPath: path, requestID: request.id)
            nowPlaying.sync(from: self, forcePosition: request.target)
            seekPreviewTask?.cancel()
            if showTimelinePreview && hasMotionVideo {
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
    func retryNetworkPlayback() {
        guard networkRetryAvailable else { return }
        session?.retryNetworkPlayback(forPath: path)
    }
    func retry() {
        rifePerformance.reset()
        fallback = false; badSamples = 0; settledSamples = 0; shaderFailed = false; unverifiedSamples = 0
        session?.applyFilters([], shader: nil); lastPlan = ""; apply()
    }
    func configure() {
        rifePerformance.reset()
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
    /// Speculative thumbnail work yields to playback; direct hover requests do not.
    var canPrewarmTimeline: Bool {
        guard path.hasPrefix("/"), loaded, !enhancementWarming, !windowTransition, !liveResizing,
              scrubPath == nil, timeline.pendingSeek == nil,
              telemetry.raw["seeking"] as? Bool != true else { return false }
        for label in ["iive-rife", "iive-fi", "iive-sr"] {
            let info = meta(label)
            if ["warming", "switching-source"].contains(info["state"] ?? "") || info["tier_switch_pending"] == "yes" { return false }
        }
        let rife = meta("iive-rife")
        if !paused, let p95 = Double(rife["p95_processing_ms"] ?? ""),
           let budget = Double(rife["pair_budget_ms"] ?? ""),
           p95.isFinite, budget.isFinite, budget > 0, p95 >= budget * 0.8 { return false }
        return true
    }
    var latency: String {
        let values = ["iive-rife", "iive-fi", "iive-sr"].compactMap { Double(meta($0)["processing_ms"] ?? "") }
        return values.isEmpty ? "N/A" : String(format: "%.1f ms", values.reduce(0, +))
    }
    // Opacity-hidden sidebar tabs stay mounted to preserve their native scroll views.
    // Only the visible tab/HUD needs presentation telemetry; control logic always
    // receives the raw 4 Hz snapshot, including fallback and reconnect decisions.
    private var telemetryVisible: Bool {
        !liveResizing && !miniPlayer && ((showVideoInfo && loaded) ||
            (inspector && ["enhance", "info"].contains(sidebarTab)))
    }
    private func updateTelemetryDemand() {
        session?.setDetailedTelemetryEnabled(telemetryVisible)
        if telemetryVisible { telemetry.flush() }
    }
    private func receive(_ rawValue: [String: Any]) {
        var value = rawValue
        if systemHDRActive, rawValue["path"] as? String == path,
           rawValue["media-loaded"] as? Bool == true {
            value["time-pos"] = systemHDRPlayback.currentPosition
            value["pause"] = systemHDRPlayback.isPaused
            value["speed"] = systemHDRPlayback.requestedRate
            value["volume"] = Double(systemHDRPlayback.player?.volume ?? 1) * 100
            value["mute"] = systemHDRPlayback.player?.isMuted ?? false
            value["seeking"] = systemHDRPlayback.isSeeking
            value["enhancement-warming"] = false
            value["paused-for-cache"] = systemHDRPlayback.isPreparing
            // These are mpv measurements, not measurements of AVKit output.
            for key in ["avsync", "frame-drop-count", "estimated-vf-fps", "estimated-display-fps", "presentation-luminance"] {
                value.removeValue(forKey: key)
            }
        }
        // Never mutate any @Published state while a menu or submenu is open/tracking.
        guard !isMenuTracking else {
            deferredSnapshot = value
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        var switchState = mediaSwitch
        switchState.update(value, now: now)
        if switchState != mediaSwitch { mediaSwitch = switchState }
        let nextLoaded = value["media-loaded"] as? Bool ?? false
        let nextPath = value["path"] as? String ?? ""
        if systemHDRActive, nextPath != path || !nextLoaded { systemHDRPlayback.close(restoring: false) }
        if nextPath != path || (loaded && value["media-loaded"] as? Bool != true) { frameActions.textSession.close(); savePosition() }
        telemetry.update(value, visible: telemetryVisible)
        playbackPreferences.update(value)
        playbackGeometry.update(value)

        let tracks = value["track-list"] as? [[String: Any]] ?? []
        let motionVideo = tracks.contains { $0["type"] as? String == "video" && $0["albumart"] as? Bool != true && $0["image"] as? Bool != true }
        let isKnownAudioExt = !nextPath.isEmpty && FolderMedia.audioExtensions.contains(URL(fileURLWithPath: nextPath).pathExtension.lowercased())
        let onlyAudio = !motionVideo && (tracks.contains { $0["type"] as? String == "audio" } || (tracks.isEmpty && isKnownAudioExt))
        if nextLoaded && hasMotionVideo != motionVideo { hasMotionVideo = motionVideo }
        if nextLoaded && audioOnly != onlyAudio {
            audioOnly = onlyAudio
            windowModes.updateMediaAspect(self)
        }
        if nextLoaded && motionVideo {
            let params = value["video-params"] as? [String: Any] ?? [:]
            let w = (params["dw"] as? NSNumber)?.intValue ?? (params["w"] as? NSNumber)?.intValue ?? 0
            let h = (params["dh"] as? NSNumber)?.intValue ?? (params["h"] as? NSNumber)?.intValue ?? 0
            if w > 0 && h > 0 {
                let fitKey = "\(nextPath)|\(w)x\(h)|\(rotation)|\(playbackGeometry.aspect)|\(playbackGeometry.crop)"
                if fitKey != lastFittedVideoKey {
                    lastFittedVideoKey = fitKey
                    windowModes.updateMediaAspect(self)
                }
            }
        } else if !nextLoaded {
            lastFittedVideoKey = ""
        }
        let reconnecting = value["network-reconnecting"] as? Bool ?? false
        if networkReconnecting != reconnecting { networkReconnecting = reconnecting }
        let retryAvailable = value["network-retry-available"] as? Bool ?? false
        if networkRetryAvailable != retryAvailable { networkRetryAvailable = retryAvailable }
        let retryAttempt = value["network-retry-attempt"] as? Int ?? 0
        if networkRetryAttempt != retryAttempt { networkRetryAttempt = retryAttempt }
        let buffering = value["paused-for-cache"] as? Bool ?? false
        if networkBuffering != buffering { networkBuffering = buffering }
        let seekable = value["seekable"] as? Bool ?? true
        if mediaSeekable != seekable { mediaSeekable = seekable }
        let opening = value["media-opening"] as? Bool ?? false
        if mediaOpening != opening { mediaOpening = opening }
        if loaded != nextLoaded { loaded = nextLoaded }
        let nextMuted = value["mute"] as? Bool ?? false
        if muted != nextMuted { muted = nextMuted }

        let playlist = value["playlist"] as? [[String: Any]] ?? []
        let nextRevision = (value["remote-next-revision"] as? NSNumber)?.uint64Value ?? 0
        let adoptNextOrder = nextRevision != remoteNextRevision && nextRevision > 0
        remoteNextRevision = nextRevision
        if adoptNextOrder || cachedPlaylist == nil || !cachedPlaylist!.isEqual(to: playlist) {
            cachedPlaylist = playlist as NSArray
            let nextQueue = playlist.compactMap { item -> QueueItem? in
                guard let id = item["id"] as? NSNumber, let filename = item["filename"] as? String else { return nil }
                return QueueItem(
                    id: id.int64Value,
                    title: remoteEntries[filename]?.item.name ?? (filename.hasPrefix("/") ? (item["title"] as? String ?? URL(fileURLWithPath: filename).lastPathComponent) : (URL(string: filename).map(NetworkMediaRequest.title) ?? "Network Media")),
                    filename: filename,
                    current: item["current"] as? Bool ?? false
                )
            }
            if adoptNextOrder || queue != nextQueue {
                queue = nextQueue
                if adoptNextOrder {
                    customQueueOrder = nextQueue.map(\.id)
                    if queueSort != "custom" { queueSort = "custom" }
                }
                synchronizeQueueOrder()
            }
        }
        let nextQueueIndex = Int((value["playlist-pos"] as? NSNumber)?.doubleValue ?? -1)
        if queueIndex != nextQueueIndex { queueIndex = nextQueueIndex }

        let chapterList = value["chapter-list"] as? [[String: Any]] ?? []
        if cachedChapters == nil || !cachedChapters!.isEqual(to: chapterList) {
            cachedChapters = chapterList as NSArray
            let nextChapters = chapterList.enumerated().compactMap { index, item -> MediaChapter? in
                guard let time = item["time"] as? Double, time.isFinite, time >= 0 else { return nil }
                return MediaChapter(id: index, title: item["title"] as? String ?? "Chapter \(index + 1)", time: time)
            }
            let orderedChapters = nextChapters.sorted { $0.time < $1.time }
            if chapters != orderedChapters { chapters = orderedChapters }
        }

        let isTransientEmptySwitch = mediaSwitch.active && !nextLoaded && nextPath.isEmpty
        let nextTitle = isTransientEmptySwitch ? title : (value["media-title"] as? String ?? PlayerIdentity.displayName)
        if !isTransientEmptySwitch {
            if title != nextTitle { title = nextTitle }
            if path != nextPath { path = nextPath }
            let nextPaused = value["pause"] as? Bool ?? true
            if paused != nextPaused { paused = nextPaused }
        }
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

        let activity = PlaybackActivity.resolve(value, pendingSeek: timeline.pendingSeek != nil,
                                                scrubbing: scrubPath != nil)
        if playbackActivity != activity { playbackActivity = activity }
        if !isTransientEmptySwitch {
            updateTransportArtwork(for: nextPath, allowRead: activity.allowsMediaNotice && !mediaSwitch.active)
        }
        let notice = mediaTitleNotice.update(epoch: (value["media-epoch"] as? NSNumber)?.uint64Value ?? 0,
            ready: playbackActivity.allowsMediaNotice,
            title: nextTitle, now: now, hovering: transportTitleHovered)
        if transportTitle != notice { transportTitle = notice }
        let resumed = resumeNotice.update(epoch: (value["media-epoch"] as? NSNumber)?.uint64Value ?? 0,
            confirmed: (value["resume-position"] as? NSNumber)?.doubleValue,
            ready: playbackActivity.allowsMediaNotice,
            now: now)
        if resumedFrom != resumed { resumedFrom = resumed }
        let remotePlaying = nextPath.hasPrefix("iive-media://") || nextPath.hasPrefix("http")
        let cachedSeconds = (value["demuxer-cache-duration"] as? NSNumber)?.doubleValue
        let cacheLow = remotePlaying && nextLoaded && value["pause"] as? Bool != true &&
            cachedSeconds.map { $0.isFinite && $0 < 2 } == true && value["eof-reached"] as? Bool != true
        let deferMetadata = !metadataContinuity.update(now: now,
            interruption: (playbackActivity.isBusy || cacheLow) ? "playback-priority" : nil)
        if remoteMetadataDeferred != deferMetadata { remoteMetadataDeferred = deferMetadata }

        let nextVol = (value["volume"] as? NSNumber)?.doubleValue ?? 50
        if now - volumeAdjustedAt > 0.45 && abs(volume - nextVol) > 0.01 { volume = nextVol }
        let nextSpeed = (value["speed"] as? NSNumber)?.doubleValue ?? 1
        if abs(speed - nextSpeed) > 0.001 { speed = nextSpeed }
        let nextError = value["error"] as? String ?? ""
        if error != nextError { error = nextError }
        if path != fileEpoch {
            rifePerformance.reset()
            if path.hasPrefix("/") {
                var updatedRecent = recent
                updatedRecent.removeAll { $0 == path }
                updatedRecent.insert(path, at: 0)
                updatedRecent = Array(updatedRecent.prefix(12))
                if recent != updatedRecent { recent = updatedRecent }
                defaults.set(recent, forKey: "recent")
                autoLoadMatchingSubtitles(for: URL(fileURLWithPath: path))
            }
            srScaleEligible = false
            fileEpoch = path; shaderFailed = false; unverifiedSamples = 0; fallback = false; badSamples = 0; settledSamples = 0; lastPlan = ""
        }
        let metadata = value["metadata"] as? [String: String] ?? [:]
        func tag(_ key: String) -> String { metadata.first { $0.key.lowercased() == key }?.value ?? "" }
        let artist = onlyAudio ? tag("artist") : "", album = onlyAudio ? tag("album") : ""
        if audioArtist != artist { audioArtist = artist }
        if audioAlbum != album { audioAlbum = album }
        // Avoid clearing artwork during brief media-loaded=false gaps when rapidly switching between audio files.
        let artworkTargetPath = onlyAudio && (nextLoaded || isKnownAudioExt) ? nextPath : ""
        if nextLoaded || !mediaSwitch.active {
            audioArtwork.update(path: artworkTargetPath,
                                embedded: tracks.contains { $0["type"] as? String == "video" && $0["albumart"] as? Bool == true })
        }
        let selectionTracks = systemHDRActive ? systemHDRPlayback.selectionTracks : tracks
        func list(_ type: String) -> [MediaTrack] {
            selectionTracks.filter { $0["type"] as? String == type }.compactMap { t in
                guard let id = t["id"] as? Int else { return nil }
                return MediaTrack(id: id, title: [t["title"] as? String, t["lang"] as? String, t["codec"] as? String].compactMap { $0 }.joined(separator: " · ").nonempty ?? "Track \(id)")
            }
        }
        let nextAudioTracks = list("audio")
        if audioTracks != nextAudioTracks { audioTracks = nextAudioTracks }
        let nextSubtitles = list("sub")
        if subtitles != nextSubtitles { subtitles = nextSubtitles }
        let nextAudioID = selectionTracks.first { $0["type"] as? String == "audio" && $0["selected"] as? Bool == true }.flatMap { ($0["id"] as? Int).map(String.init) } ?? "no"
        if audioID != nextAudioID { audioID = nextAudioID }
        func selectedSubtitle(_ slot: Int) -> String {
            selectionTracks.first { $0["type"] as? String == "sub" && $0["selected"] as? Bool == true &&
                ($0["main-selection"] as? Int ?? 0) == slot }.flatMap { ($0["id"] as? Int).map(String.init) } ?? "no"
        }
        let nextSubtitleID = selectedSubtitle(0)
        let nextSecondaryID = selectedSubtitle(1)
        let secondaryChanged = secondarySubtitleID != nextSecondaryID
        if secondaryChanged { secondarySubtitleID = nextSecondaryID }
        if subtitleID != nextSubtitleID { subtitleID = nextSubtitleID }
        if secondaryChanged { applySubtitleAppearance() }
        if !systemHDRActive, liveCaptionPlacement == "bottom", nextSubtitleID != "no" { command(["set", "sid", "no"]) }
        if !systemHDRActive, liveCaptionPlacement == "top", nextSecondaryID != "no" { command(["set", "secondary-sid", "no"]) }
        updateLiveCaptions()
        let drops = (value["frame-drop-count"] as? NSNumber)?.doubleValue ?? 0
        let rifeMeta = meta("iive-rife")
        let interruption = playbackActivity.interruptionReason ??
            ((windowTransition || liveResizing) ? "window-transition" : nil)
        let stablePlayback = performanceContinuity.update(now: now, interruption: interruption)
        let rifeEligible = !systemHDRActive && automatic && master && !fallback && fi == "rife" && stablePlayback
        let performanceSample = value["performance-sample"] as? Bool ?? true
        // Discrete transport/startup updates can arrive between the 4 Hz samples.
        // Reset interrupted evaluation immediately, but never count those extra
        // updates as additional stable/overloaded samples or split drop deltas.
        if !rifeEligible { rifePerformance.suspend() }
        if performanceSample, let stage = rifePerformance.observe(
            now: now, requestedTier: tier, observedTier: rifeMeta["requested_tier"],
            generation: rifeMeta["generation"], state: rifeMeta["state"] ?? "",
            p95: Double(rifeMeta["p95_processing_ms"] ?? ""),
            budget: Double(rifeMeta["pair_budget_ms"] ?? ""),
            samples: Int(rifeMeta["latency_samples"] ?? "") ?? 0,
            drops: number("frame-drop-count"), avsync: number("avsync"), eligible: rifeEligible) {
            badSamples = 0; settledSamples = 0
            osd.show(stage == .fast ? "Performance protection · RIFE Fast" : "Performance protection · interpolation off",
                     symbol: "speedometer")
        }
        if stablePlayback && performanceSample {
            settledSamples += 1
            if settledSamples > 25 && !systemHDRActive && automatic && master {
                let avsyncVal = (value["avsync"] as? NSNumber)?.doubleValue ?? 0
                badSamples = (drops - previousDrops > 4 || abs(avsyncVal) > 0.25) ? badSamples + 1 : 0
                // RIFE has its own staged protection. Preserve SR while reducing FI;
                // the global guard is only the final safety net for remaining effects.
                if badSamples >= 5 && !fallback &&
                    (fi != "rife" || rifePerformance.stage == .off || rifeMeta.isEmpty) { fallback = true }
            }
        } else if !stablePlayback { settledSamples = 0; badSamples = 0 }
        if performanceSample || !stablePlayback { previousDrops = drops }
        let expectedPass = sr == "fsrcnnx16" ? "IIVE FSRCNNX 16 / aggregation" : "IIVE FSRCNNX 8 / aggregation"
        if lastPlan.contains("FSRCNNX") && !sr.contains("metal") && stablePlayback && !String(describing: value["vo-passes"] ?? "").contains(expectedPass) {
            if performanceSample { unverifiedSamples += 1 }
            if unverifiedSamples > 24 && !shaderFailed { shaderFailed = true }
        } else { unverifiedSamples = 0 }
        if chromeTheme == "adaptive", hasMotionVideo, loaded, !liveResizing,
           let luma = number("presentation-luminance"), luma.isFinite {
            // Approximate brightness of the actual rendered canvas, including bars.
            // Hysteresis keeps borderline scenes from flickering the glass appearance.
            if adaptiveLightGlass {
                if luma < 0.56 { adaptiveLightGlass = false }
            } else if luma > 0.66 { adaptiveLightGlass = true }
        }
        apply()
        if supportsSRComparison && (srCompare || meta("iive-sr")["split_ratio"] != nil) {
            let expectedSplit = srCompare ? srSplitRatio : 0.0
            if let reported = Double(meta("iive-sr")["split_ratio"] ?? ""),
               abs(reported - expectedSplit) > 0.005 {
                session?.updateSplit(expectedSplit, expectedPath: path)
            }
        }
        if let isRec = value["metrics-recording"] as? Bool {
            if recordingMetrics != isRec { recordingMetrics = isRec }
            let samples = (value["metrics-samples"] as? NSNumber)?.intValue ?? 0
            if recordedMetricsSamples != samples { recordedMetricsSamples = samples }
            if isRec, let url = lastMetricsURL {
                let nextStatus = "Recording · \(samples) samples · \(url.lastPathComponent)"
                if metricsStatus != nextStatus { metricsStatus = nextStatus }
            }
        }
        menuState.sync(from: self)
        nowPlaying.sync(from: self)
        PlayerSleepAssertionManager.shared.update(
            loaded: loaded,
            paused: paused,
            hasMotionVideo: hasMotionVideo,
            audioOnly: audioOnly,
            title: title
        )
        PlayerUserActivityController.shared.update(
            path: path,
            title: title,
            loaded: loaded
        )
        if now - lastSave > 10 { savePosition() }
        let hdrKey = "\(path)|\((value["media-epoch"] as? NSNumber)?.uint64Value ?? 0)"
        let transfer = (source["gamma"] as? String ?? "").lowercased()
        if automaticSystemHDR, !systemHDRActive, loaded, hasMotionVideo,
           path.hasPrefix("/"), ["mp4", "mov", "m4v"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
           ["pq", "hlg", "smpte2084", "arib-std-b67"].contains(transfer) || isDolbyVision,
           systemHDRAttempt != hdrKey {
            systemHDRAttempt = hdrKey
            // Defer past snapshot application; never re-enter receive/queue mutation.
            Task { @MainActor [weak self] in
                guard let self, self.loaded, self.automaticSystemHDR,
                      "\(self.path)|\((self.snapshot["media-epoch"] as? NSNumber)?.uint64Value ?? 0)" == hdrKey else { return }
                self.openSystemHDRPlayback()
            }
        }
    }
    func apply() {
        if systemHDRActive {
            let bypass = String(localized: "Unavailable · system HDR playback")
            if srStatus != bypass { srStatus = bypass }
            if fiStatus != bypass { fiStatus = bypass }
            return
        }
        // Loading snapshots have incomplete color/track data. Keep the existing
        // filter configuration until the new file can be evaluated once, rather
        // than sending an empty chain followed by a second rebuild/seek.
        guard loaded else { return }
        guard session != nil, !windowTransition, !liveResizing, ProcessInfo.processInfo.systemUptime >= enhancementPlanResumeAt else { return }
        if deinterlaceMode == "no", lastDeinterlaceMode != "no" {
            command(["set", "deinterlace", "no"]); lastDeinterlaceMode = "no"
        }
        applyDecoder()
        // FILE_LOADED alone is not proof that the current decoder's parameters
        // have arrived. Removing then re-adding the same chain here causes two
        // exact seeks and needless model warmup. Native filters still validate
        // each input frame (including HDR) while this decision is deferred.
        if master && !fallback && (fi != "off" || sr != "off") && hasMotionVideo && !EnhancementInputReadiness.ready(
            source: source, fps: number("container-fps"), started: telemetry.raw["media-started"] as? Bool == true) {
            if fi != "off" { fiStatus = "Waiting for video parameters" }
            if sr != "off" { srStatus = "Waiting for video parameters" }
            return
        }
        let performanceState = ["requested_tier": tier,
                                "effective_tier": rifePerformance.stage == .off ? "off" : rifePerformance.effectiveTier(tier),
                                "stage": rifePerformance.stage.rawValue,
                                "reason": rifePerformance.reason,
                                "evaluation_hold": performanceContinuity.reason,
                                "automatic": automatic ? "yes" : "no"]
        if performanceState != lastPerformanceState {
            session?.setRIFEPerformanceState(performanceState)
            lastPerformanceState = performanceState
        }
        var filters: [String] = []; var shader: String?
        if isDolbyVision && !dolbyVisionMapping {
            filters.append("@iive-dovi-base:format=dolbyvision=no")
        }
        let disabled = !master || fallback
        let base = disabled ? (fallback ? "Degraded · Retry to restore" : "Off") : !loaded ? "Waiting for video" : !hasMotionVideo ? "Not applicable · no video" : !sdr ? "Bypassed · HDR or unknown color metadata" : nil
        var nextFiStatus = fi == "off" ? "Off" : base ?? "Warming"
        var nextSrStatus = sr == "off" ? "Off" : base ?? "Warming"
        let fallbackOption = automatic ? "yes" : "no"
        if base == nil {
            let fps = number("container-fps") ?? 0
            let rawW = (source["w"] as? NSNumber)?.doubleValue ?? 0
            let rawH = (source["h"] as? NSNumber)?.doubleValue ?? 0
            let sourceHeight = (rawW > 0 && rawH > 0) ? min(rawW, rawH) : rawH
            let sourcePixels = rawW * rawH
            let fiWithinLimits = fps <= fiMaximumFPS + 0.01 && (fiMaximumHeight == 0 || sourceHeight <= fiMaximumHeight)
            var rifeScheduled = false
            if fi != "off" && deinterlaceMode != "no" {
                nextFiStatus = "Bypassed · deinterlacing controls frame cadence"
            } else if fi == "rife" && rifePerformance.stage == .off {
                nextFiStatus = "Auto protection · interpolation off · Retry to restore"
            } else if fi != "off" && !fiWithinLimits {
                nextFiStatus = "Bypassed · source exceeds interpolation limits"
            } else if fi == "rife", fps > 0, fps < Double(targetFPS) {
                rifeScheduled = true
                let effectiveTier = rifePerformance.effectiveTier(tier)
                filters.append("@iive-rife:iive-rife=fps=\(targetFPS):tier=\(effectiveTier):fallback=\(fallbackOption)")
                nextFiStatus = meta("iive-rife")["state"] == "switching-source" ? state("iive-rife") :
                    meta("iive-rife")["requested_tier"] == effectiveTier ? state("iive-rife") : "Warming model"
                if rifePerformance.stage == .fast { nextFiStatus += " · Auto → Fast · Retry to restore" }
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
            // When Split-Screen SR Compare is enabled, always allow 2x SR execution regardless of window size.
            let minimumScale = sr.hasPrefix("fsrcnnx") && !sr.contains("metal") ? max(1.3, srMinimumScale) : srMinimumScale
            srScaleEligible = (srCompare && supportsSRComparison) || (scale > (srScaleEligible ? max(sr.hasPrefix("fsrcnnx") && !sr.contains("metal") ? 1.3 : 1.01, minimumScale - 0.1) : minimumScale))
            let srWithinLimits = srMaximumHeight == 0 || sourceHeight <= srMaximumHeight
            if sr != "off" && !srWithinLimits { nextSrStatus = "Bypassed · source exceeds super resolution limit" }
            else if sr != "off" && !srScaleEligible { nextSrStatus = "Bypassed · below upscaling threshold" }
            else if (sr == "apple" || sr.contains("metal")) && !nativeSRColorSupported {
                nextSrStatus = "Bypassed · native SR requires BT.709 / BT.1886 SDR"
            }
            else if automatic && rifeScheduled && sr.contains("metal") && !srCompare && sourcePixels >= 1920 * 1080 {
                nextSrStatus = "Bypassed · 1080p+ RIFE \(targetFPS)fps budget guard"
            }
            else if sr.contains("metal") {
                let is16 = sr == "fsrcnnx_metal16"
                let model = is16 ? "quality" : "fast"
                let initialSplit = srCompare ? "0.5" : "0.0"
                filters.append("@iive-sr:iive-fsrcnnx=tier=\(model):split=\(initialSplit):fallback=\(fallbackOption)")
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
            if srCompare && supportsSRComparison {
                session?.updateSplit(srSplitRatio, expectedPath: path)
            }
        }
        if lastDeinterlaceMode != deinterlaceMode {
            command(["set", "deinterlace", deinterlaceMode]); lastDeinterlaceMode = deinterlaceMode
        }
    }
    private func valueBool(_ key: String) -> Bool { telemetry.raw[key] as? Bool ?? false }
    private func state(_ label: String) -> String {
        switch meta(label)["state"] ?? "warming" {
        case "active": return paused ? "Paused · ready" : "Active"
        case "warming": return "Warming model"
        case "seek-preroll": return "Seeking · preparing source frames"
        case "switching-source": return "Switching model · source playback"
        case "finished": return "Finished"
        case "scene-cut-hold": return "Scene cut · holding source"
        case "degraded", "degraded-finished": return "Degraded · processing too slow"
        case "unsupported-or-model-unavailable": return "Unavailable · dimensions or system model"
        case "error-bypass":
            let details = meta(label)
            let code = details["error_code"] ?? "?"
            let stage = details["error_stage"] ?? "unknown"
            let reason = details["error_reason"] ?? "unknown"
            return "Error · \(stage) / \(reason) [\(code)] · source playback restored"
        default: return "Bypassed · unsupported input"
        }
    }
    private func prepareLocalPlayback(_ file: String, hook: UInt64, session currentSession: MPVSession) {
        // Cached online fields never block decoder startup or trigger network requests.
        Task { await OnlineMovieLibrary.shared.validate(file) }
        savePosition()
        localPreparationTask?.cancel()
        let shouldResume = resumePlayback && skipResumePath != file
        let memoryGeneration = playbackMemoryGeneration
        skipResumePath = nil
        // No file metadata I/O is needed if both memory features are off.
        guard resumePlayback || rememberMediaSelections else {
            localMemoryContext = nil
            currentSession.finishLocalHook(hook, options: [:])
            return
        }
        localPreparationTask = Task { [weak self, weak currentSession] in
            var options: [String: String] = [:]
            // Even cancellation must release the load hook. MPVSession validates
            // the hook ID, so an obsolete callback cannot release a newer hook.
            defer { currentSession?.finishLocalHook(hook, options: options) }
            let stamp: PlaybackFileStamp? = await mediaReadWithDeadline(seconds: 0.75, cancel: {}) {
                PlaybackFileStamp.read(file)
            }
            guard !Task.isCancelled, let self, let currentSession, self.session === currentSession else { return }
            guard self.playbackMemoryGeneration == memoryGeneration else { return }
            self.localMemoryContext = stamp.map { (file, $0) }
            options = self.rememberMediaSelections ? ["speed": "1"] : [:]
            if let stamp, let record = self.playbackMemory.record(for: file, stamp: stamp) {
                options.merge(record.options(resume: shouldResume, selections: self.rememberMediaSelections)) { _, saved in saved }
            } else if shouldResume, stamp != nil,
                      let old = self.defaults.dictionary(forKey: "positions")?[file] as? Double, old.isFinite, old > 5 {
                options["start"] = String(old)
            }
            if stamp == nil && shouldResume {
                self.osd.show("Playback memory unavailable · opening without resume", symbol: "info.circle")
            }
        }
    }

    func dismissResumeNotice() { resumeNotice.dismiss(); resumedFrom = nil }
    func startOverAfterResume() {
        guard resumedFrom != nil, loaded, mediaSeekable else { return }
        if path.hasPrefix("/") {
            playbackMemory.resetPosition(for: path)
            if var legacy = defaults.dictionary(forKey: "positions"), legacy.removeValue(forKey: path) != nil {
                defaults.set(legacy, forKey: "positions")
            }
        } else if let context = remotePlaybackContext, context.key == path {
            remotePlaybackMemory.resetPosition(for: context.identity)
        }
        seek(0)
        osd.show("Seeking to Beginning", symbol: "backward.end.fill")
    }
    func clearPlaybackMemory() {
        SystemTrackMemory.clear()
        playbackMemoryGeneration &+= 1
        playbackMemory.clear()
        remotePlaybackMemory.clear()
        remotePlaybackContext = nil
        // Do not recreate the current file's cleared record on the next tick.
        localMemoryContext = nil
    }
    func clearRemotePlaybackMemory() {
        playbackMemoryGeneration &+= 1
        remotePlaybackMemory.clear(); remotePlaybackContext = nil
        networkResumeStatus = "Saved network progress cleared. New records begin when you reopen media."
    }
    func saveSystemHDRReturn(_ result: SystemPlaybackReturn, restoring: Bool) {
        savePosition(overridePosition: result.position, overrideSpeed: result.speed)
        // A replacement/close must not overwrite the handoff position with mpv's paused frame.
        if !restoring, localMemoryContext?.path == path { localMemoryContext = nil }
    }
    func savePosition(overridePosition: Double? = nil, overrideSpeed: Double? = nil) {
        let position = overridePosition ?? (systemHDRActive ? systemHDRPlayback.currentPosition : self.position)
        let speed = overrideSpeed ?? (systemHDRActive && !systemHDRPlayback.isPaused ? systemHDRPlayback.playbackRate : self.speed)
        lastSave = ProcessInfo.processInfo.systemUptime
        if loaded, resumePlayback, rememberNetworkProgress, let context = remotePlaybackContext,
           context.key == path, snapshot["seekable"] as? Bool == true, !networkReconnecting,
           snapshot["media-started"] as? Bool == true, snapshot["seeking"] as? Bool != true, scrubPath == nil, timeline.pendingSeek == nil {
            remotePlaybackMemory.save(identity: context.identity, revision: context.revision,
                                      position: position, duration: duration)
        }
        guard loaded, resumePlayback || rememberMediaSelections, let context = localMemoryContext,
              context.path == path, duration.isFinite, duration > 0, position.isFinite,
              scrubPath == nil, timeline.pendingSeek == nil, snapshot["seeking"] as? Bool != true else { return }
        let tracks = snapshot["track-list"] as? [[String: Any]] ?? []
        func memorySelection(_ id: String, type: String, slot: Int = 0) -> String {
            guard systemHDRActive || (Int(id) ?? 0) <= -1000 else { return id }
            return tracks.first { $0["type"] as? String == type && $0["selected"] as? Bool == true &&
                (type != "sub" || ($0["main-selection"] as? Int ?? 0) == slot) }
                .flatMap { ($0["id"] as? Int).map(String.init) } ?? "no"
        }
        let record = PlaybackMemoryRecord(stamp: context.stamp, updated: Date(),
            position: resumePlayback && position < duration - 10 ? max(0, position) : 0, speed: rememberMediaSelections ? speed : 1,
            audio: rememberMediaSelections ? PlaybackMemoryRecord.embeddedSelection(memorySelection(audioID, type: "audio"), type: "audio", tracks: tracks) : nil,
            subtitle: rememberMediaSelections ? PlaybackMemoryRecord.embeddedSelection(memorySelection(subtitleID, type: "sub"), type: "sub", tracks: tracks) : nil,
            secondarySubtitle: rememberMediaSelections ? PlaybackMemoryRecord.embeddedSelection(memorySelection(secondarySubtitleID, type: "sub", slot: 1), type: "sub", tracks: tracks) : nil)
        playbackMemory.save(record, for: path)
        // Retire migrated entries so a replaced file cannot resurrect old progress.
        if var legacy = defaults.dictionary(forKey: "positions"), legacy.removeValue(forKey: path) != nil {
            defaults.set(legacy, forKey: "positions")
        }
    }
    func toggleMetricsRecording() {
        if recordingMetrics {
            stopMetricsRecording()
        } else {
            startMetricsRecording()
        }
    }
    func startMetricsRecording() {
        guard let session else {
            metricsStatus = "Unable to start recording · renderer not initialized"
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iive-diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        let url = dir.appendingPathComponent("iive-window-profile-\(stamp)-\(suffix).jsonl")
        metricsStatus = "Starting performance recording…"
        session.startMetricsRecording(to: url.path) { [weak self] err in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let err {
                    self.recordingMetrics = false
                    self.metricsStatus = err
                    return
                }
                self.lastMetricsURL = url
                self.recordedMetricsSamples = 1
                self.recordingMetrics = true
                self.metricsStatus = "Recording · 1 sample · \(url.lastPathComponent)"
                self.osd.show("Recording Performance", symbol: "record.circle")
            }
        }
    }
    func stopMetricsRecording(afterStop: (@MainActor (URL?) -> Void)? = nil) {
        guard let session else {
            recordingMetrics = false
            afterStop?(lastMetricsURL)
            return
        }
        session.stopMetricsRecording { [weak self] samples, savedPath in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recordingMetrics = false
                self.recordedMetricsSamples = samples
                if let savedPath, !savedPath.isEmpty {
                    let url = URL(fileURLWithPath: savedPath)
                    self.lastMetricsURL = url
                    self.metricsStatus = "Saved \(samples) samples · \(url.lastPathComponent) (paths redacted)"
                } else {
                    self.metricsStatus = "Recording stopped"
                }
                self.osd.show("Performance Saved", symbol: "checkmark.circle")
                afterStop?(self.lastMetricsURL)
            }
        }
    }
    func exportMetricsRecording() {
        if recordingMetrics {
            stopMetricsRecording { [weak self] _ in
                self?.presentMetricsExportPanel()
            }
        } else {
            presentMetricsExportPanel()
        }
    }
    private func presentMetricsExportPanel() {
        guard let sourceURL = lastMetricsURL, FileManager.default.fileExists(atPath: sourceURL.path) else {
            metricsStatus = "No recorded performance file available to export."
            return
        }
        let samples = recordedMetricsSamples
        fileDialogs.export(title: "Export Performance Recording", filename: sourceURL.lastPathComponent,
                           type: UTType(filenameExtension: "jsonl") ?? .plainText,
                           load: {
            try await Task.detached(priority: .utility) {
                try Data(contentsOf: sourceURL, options: .mappedIfSafe)
            }.value
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let destination):
                self.lastMetricsURL = destination
                self.metricsStatus = "Exported \(samples) samples · \(destination.lastPathComponent)"
                self.osd.show("Exported Performance Log", symbol: "square.and.arrow.up")
            case .failure(let error): self.metricsStatus = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func revealMetricsRecording() {
        guard let url = lastMetricsURL, FileManager.default.fileExists(atPath: url.path) else {
            metricsStatus = "No recorded performance file found on disk."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    private func updateTransportArtwork(for nextPath: String, allowRead: Bool) {
        guard nextPath != transportArtworkPath else { return }
        transportArtworkPath = nextPath
        transportArtworkTask?.cancel()
        transportArtworkTask = nil
        guard nextPath.hasPrefix("/") else {
            if transportArtwork != nil { transportArtwork = nil }
            return
        }
        let cached = QueueMetadataCache.cachedDedicatedArtwork(nextPath)
        if cached.found {
            if transportArtwork !== cached.image { transportArtwork = cached.image }
            return
        }
        if transportArtwork != nil { transportArtwork = nil }
        guard allowRead else {
            // A later ready snapshot retries; no cover probe competes with first-frame I/O.
            transportArtworkPath = ""
            return
        }
        transportArtworkTask = Task.detached(priority: .utility) { [weak self] in
            // Let decoder startup take priority; rapid switches cancel before artwork I/O.
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let dedicated = QueueMetadataCache.dedicatedArtwork(nextPath, maxPixels: 900)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.transportArtworkPath == nextPath else { return }
                self.transportArtwork = dedicated
                self.transportArtworkTask = nil
            }
        }
    }
    func applyUpdatedCover(_ image: NSImage, for targetPath: String) {
        guard path == targetPath || URL(fileURLWithPath: path).standardizedFileURL == URL(fileURLWithPath: targetPath).standardizedFileURL else { return }
        transportArtworkTask?.cancel()
        transportArtworkTask = nil
        transportArtworkPath = path
        transportArtwork = image
    }
    func shutdown() { systemHDRPlayback.close(restoring: false); subtitleDiscoveryTask?.cancel(); subtitleDiscoveryTask = nil; mediaSwitch = MediaSwitchPresentation(); playbackGeometry.reset(); windowLifecycle.resetTransientState(); savePosition(); playbackActivity = .idle; resumeNotice = PlaybackResumeNotice(); resumedFrom = nil; remotePlaybackContext = nil; networkResumeStatus = ""; localPreparationTask?.cancel(); localPreparationTask = nil; localMemoryContext = nil; networkBuffering = false; networkReconnecting = false; networkRetryAvailable = false; networkRetryAttempt = 0; remoteMetadataDeferred = false; metadataContinuity = PlaybackContinuityGate(); performanceContinuity = PlaybackContinuityGate(); remoteResolution?.cancel(); remoteResolution = nil; remoteEntries.removeAll(); pendingRemote = nil; Task { await remoteMetadata.clear() }; mediaTitleNotice = MediaTitleNotice(); transportTitleHovered = false; transportTitle = ""; transportArtworkTask?.cancel(); transportArtworkTask = nil; transportArtworkPath = ""; transportArtwork = nil; mediaOpening = false; pendingNetwork = nil; showNetworkSheet = false; recordingMetrics = false; recordedMetricsSamples = 0; audioArtwork.clear(); audioOnly = false; hasMotionVideo = false; audioArtist = ""; audioAlbum = ""; cancelScrubbing(); seekPreviewTask?.cancel(); seekPreviewTask = nil; frameActions.close(); liveCaptions.stop(); liveCaptionPlacement = "off"; secondarySubtitleID = "no"; queuePopover = false; quickSettings = false; cancelFolderScan(); queueDateTask?.cancel(); customQueueOrder = []; queueDates = [:]; queueMembership = ""; queueDateMembership = ""; queueOrderRequest = ""; deferredSnapshot = nil; windowModes.prepareForShutdown(self); savePosition(); session?.shutdown(); fileDialogs.shutdown(); windowModes.resetAfterClose(self); session = nil; lastDecoderOption = ""; colorProfileTask?.cancel(); cachedPlaylist = nil; cachedChapters = nil; telemetry.reset(); timeline.reset(); enhancementWarming = false; loaded = false; adaptiveLightGlass = false; muted = false; queue = []; chapters = []; queueIndex = -1; path = ""; title = PlayerIdentity.displayName; paused = true; audioTracks = []; subtitles = []; audioID = "no"; subtitleID = "no"; srStatus = "Off"; fiStatus = "Off"; error = ""; skipResumePath = nil; lastPlan = ""; fileEpoch = ""; menuState.sync(from: self); nowPlaying.clear() }
}
private extension String { var nonempty: String? { isEmpty ? nil : self } }

private func preference(_ key: String, default fallback: Double, range: ClosedRange<Double>) -> Double {
    let value = UserDefaults.standard.object(forKey: key) as? Double ?? fallback
    return value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
}
