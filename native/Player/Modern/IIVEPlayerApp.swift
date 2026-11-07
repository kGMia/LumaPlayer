// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppIntents
import CoreSpotlight

@MainActor final class PlayerAppDelegate: NSObject, NSApplicationDelegate {
    static weak var sharedModel: PlayerModel?
    let model: PlayerModel
    override init() {
        PlayerIdentity.migratePreferences()
        model = PlayerModel()
        Self.sharedModel = model
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        PlayerEnergyPolicy.shared.start()
        PlayerSpotlightLibrary.shared.start()
        PlayerAudioRouteMonitor.shared.start { [weak self] in
            guard let model = self?.model, model.loaded, !model.paused else { return }
            model.togglePause()
            model.osd.show("Audio Output Changed · Paused", symbol: "headphones")
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Hiding the main window can invoke this callback even while the mini
        // NSPanel is visible. It is a presentation change, not the end of playback.
        !model.miniPlayer && !model.windowTransition && !model.windowModes.hasMiniPlayerWindow
    }
    func applicationWillTerminate(_ notification: Notification) {
        PlayerEnergyPolicy.shared.stop()
        PlayerSpotlightLibrary.shared.stop()
        PlayerAudioRouteMonitor.shared.stop()
        PlayerSleepAssertionManager.shared.releaseAssertion()
        PlayerUserActivityController.shared.clear()
        model.shutdown()
    }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if model.loaded && !model.title.isEmpty {
            let header = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
        }
        let playPause = NSMenuItem(
            title: model.paused ? String(localized: "Play") : String(localized: "Pause"),
            action: #selector(dockTogglePlayPause),
            keyEquivalent: ""
        )
        playPause.target = self
        playPause.isEnabled = model.loaded || !model.path.isEmpty
        menu.addItem(playPause)

        let prevItem = NSMenuItem(
            title: String(localized: "Previous Item"),
            action: #selector(dockPreviousItem),
            keyEquivalent: ""
        )
        prevItem.target = self
        prevItem.isEnabled = model.loaded || model.canPrevious
        menu.addItem(prevItem)

        let nextItem = NSMenuItem(
            title: String(localized: "Next Item"),
            action: #selector(dockNextItem),
            keyEquivalent: ""
        )
        nextItem.target = self
        nextItem.isEnabled = model.canNext
        menu.addItem(nextItem)

        menu.addItem(.separator())

        let enhanceItem = NSMenuItem(
            title: String(localized: "Enable Enhancements"),
            action: #selector(dockToggleEnhancements),
            keyEquivalent: ""
        )
        enhanceItem.target = self
        enhanceItem.state = model.master ? .on : .off
        menu.addItem(enhanceItem)

        let miniItem = NSMenuItem(
            title: model.miniPlayer ? String(localized: "Restore Player") : String(localized: "Mini Player"),
            action: #selector(dockToggleMiniPlayer),
            keyEquivalent: ""
        )
        miniItem.target = self
        miniItem.isEnabled = !model.windowTransition
        menu.addItem(miniItem)

        if !model.recent.isEmpty {
            menu.addItem(.separator())
            let recentMenu = NSMenu()
            recentMenu.autoenablesItems = false
            for path in model.recent.prefix(8) {
                let entry = NSMenuItem(
                    title: URL(fileURLWithPath: path).lastPathComponent,
                    action: #selector(dockOpenRecent(_:)),
                    keyEquivalent: ""
                )
                entry.target = self
                entry.representedObject = path
                recentMenu.addItem(entry)
            }
            let recentRoot = NSMenuItem(title: String(localized: "Open Recent"), action: nil, keyEquivalent: "")
            recentRoot.submenu = recentMenu
            menu.addItem(recentRoot)
        }
        return menu
    }
    @objc private func dockTogglePlayPause() { model.togglePause() }
    @objc private func dockPreviousItem() { model.previousOrRestart() }
    @objc private func dockNextItem() { model.nextFile() }
    @objc private func dockToggleEnhancements() { model.master.toggle() }
    @objc private func dockToggleMiniPlayer() { model.toggleMiniPlayer() }
    @objc private func dockOpenRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSApp.activate(ignoringOtherApps: true)
        model.open(URL(fileURLWithPath: path))
    }
}

@main struct LumaPlayerApp: App {
    @NSApplicationDelegateAdaptor(PlayerAppDelegate.self) private var delegate
    var body: some Scene {
        let model = delegate.model
        let menu = model.menuState
        Window(PlayerIdentity.displayName, id: "player") {
            PlayerView(model: model).playerFileDialogs(model.fileDialogs, host: .player).onOpenURL { model.open($0) }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    NSApp.activate(ignoringOtherApps: true)
                    PlayerSpotlightLibrary.shared.open(activity, model: model)
                }
                .onContinueUserActivity(PlayerUserActivityController.playbackActivityType) { activity in
                    NSApp.activate(ignoringOtherApps: true)
                    if let url = activity.webpageURL {
                        model.open(url)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowManagerRole(.principal)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 760)
        .defaultLaunchBehavior(.presented)
        .commands {
            PlayerWindowCommands(model: model)
            PlayerFileCommands(model: model, menu: menu)
            PlayerViewCommands(model: model, menu: menu)
            PlayerPlaybackCommands(model: model, menu: menu)
        }
        Window("Live Text", id: LiveTextSession.windowID) {
            LiveTextWindow(session: model.frameActions.textSession)
        }
        .defaultSize(width: 640, height: 480)
        .windowResizability(.contentMinSize)
        .windowManagerRole(.associated)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()
        Settings { PlayerSettings(model: model).playerFileDialogs(model.fileDialogs, host: .settings) }
    }
}

struct PlayerWindowCommands: Commands {
    let model: PlayerModel
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Player") { openWindow(id: "player") }
            Toggle("Float on Top", isOn: Binding(
                get: { model.menuState.floatOnTop },
                set: { _ in model.toggleFloatOnTop() }
            ))
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(model.menuState.fullScreen || model.menuState.miniPlayer)
            Button("Play Queue") { openWindow(id: "player"); model.showSidebar("queue") }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}

struct PlayerFileCommands: Commands {
    let model: PlayerModel
    @ObservedObject var menu: PlayerMenuState
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Media…") { openWindow(id: "player"); model.openPanel() }
                .keyboardShortcut("o")
            Button("Add to Play Queue…") { openWindow(id: "player"); model.openPanel(append: true) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Open Network…") { openWindow(id: "player"); model.showNetworkSheet = true }
            Button("Use system HDR playback") { model.openSystemHDRPlayback() }
                .keyboardShortcut("h", modifiers: [.command, .option])
                .keyboardShortcut("n")
            Menu("Open Recent") {
                if menu.recent.isEmpty { Text("No recent media") }
                ForEach(menu.recent, id: \.self) { path in
                    Button(URL(fileURLWithPath: path).lastPathComponent) {
                        openWindow(id: "player")
                        model.open(URL(fileURLWithPath: path))
                    }
                }
            }
        }
    }
}

struct PlayerViewCommands: Commands {
    let model: PlayerModel
    @ObservedObject var menu: PlayerMenuState
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Group {
                Button(menu.fullScreen ? String(localized: "Exit Full Screen") : String(localized: "Enter Full Screen")) { model.toggleFullScreen() }
                    .keyboardShortcut("f", modifiers: [.control, .command])
                Button(menu.miniPlayer ? String(localized: "Restore Player") : String(localized: "Mini Player")) { model.toggleMiniPlayer() }
                    .keyboardShortcut("p", modifiers: [.option, .command])
                Toggle("Enable Enhancements", isOn: Binding(get: { menu.master }, set: { model.master = $0 }))
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Toggle("Summary Card", isOn: Binding(get: { menu.showSummaryCard }, set: { model.showSummaryCard = $0 }))
                Toggle("Video Information", isOn: Binding(get: { menu.showVideoInfo }, set: { model.showVideoInfo = $0 }))
                    .keyboardShortcut("i")
                Toggle("Timeline Hover Preview", isOn: Binding(get: { menu.showTimelinePreview }, set: { model.showTimelinePreview = $0 }))
                Button(menu.fullScreen ? String(localized: "Enhancement Settings") : String(localized: "Sidebar")) {
                    if menu.inspector && !menu.fullScreen { model.inspector = false }
                    else { model.showSidebar("enhance") }
                }.keyboardShortcut("i", modifiers: [.option, .command])
                Divider()
                Button(menu.recordingMetrics ? String(localized: "Stop Performance Recording") : String(localized: "Start Performance Recording")) {
                    model.toggleMetricsRecording()
                }.keyboardShortcut("r", modifiers: [.option, .command])
                Button("Export Performance Recording…") {
                    model.exportMetricsRecording()
                }.disabled(!menu.recordingMetrics && !menu.hasMetricsRecording)
            }.disabled(!menu.playerWindowCommandsEnabled)
        }
    }
}

struct PlayerPlaybackCommands: Commands {
    let model: PlayerModel
    @ObservedObject var menu: PlayerMenuState
    var body: some Commands {
        let singleKeyDisabled = !menu.playerWindowCommandsEnabled
        CommandMenu("Playback") {
            Group {
                Button(menu.paused ? String(localized: "Play") : String(localized: "Pause")) { model.performPlaybackShortcut(.pause) }
                    .playbackShortcut(.space, modifiers: [], enabled: menu.playbackShortcutsEnabled)
                    .disabled(singleKeyDisabled)
                Button("Back \(Int(menu.seekSeconds)) Seconds") { model.performPlaybackShortcut(.seek(backward: true, long: false)) }
                    .playbackShortcut(.leftArrow, modifiers: [], enabled: menu.playbackShortcutsEnabled)
                    .disabled(!menu.loaded || singleKeyDisabled)
                Button("Forward \(Int(menu.seekSeconds)) Seconds") { model.performPlaybackShortcut(.seek(backward: false, long: false)) }
                    .playbackShortcut(.rightArrow, modifiers: [], enabled: menu.playbackShortcutsEnabled)
                    .disabled(!menu.loaded || singleKeyDisabled)
                Button("Back \(Int(menu.longSeekSeconds)) Seconds") { model.performPlaybackShortcut(.seek(backward: true, long: true)) }
                    .playbackShortcut(.leftArrow, modifiers: [.shift], enabled: menu.playbackShortcutsEnabled)
                    .disabled(!menu.loaded || singleKeyDisabled)
                Button("Forward \(Int(menu.longSeekSeconds)) Seconds") { model.performPlaybackShortcut(.seek(backward: false, long: true)) }
                    .playbackShortcut(.rightArrow, modifiers: [.shift], enabled: menu.playbackShortcutsEnabled)
                    .disabled(!menu.loaded || singleKeyDisabled)
                Button("Previous Frame") { model.performPlaybackShortcut(.frame(backward: true)) }
                    .playbackShortcut(.leftArrow, modifiers: [.command], enabled: menu.playbackShortcutsEnabled)
                    .disabled(!menu.hasVideo || singleKeyDisabled)
                Button("Next Frame") { model.performPlaybackShortcut(.frame(backward: false)) }
                    .playbackShortcut(.rightArrow, modifiers: [.command], enabled: menu.playbackShortcutsEnabled)
                    .disabled(!menu.hasVideo || singleKeyDisabled)
                Button("Previous Item") { model.performPlaybackShortcut(.previousItem) }
                    .playbackShortcut(.leftArrow, modifiers: [.option, .command], enabled: menu.playbackShortcutsEnabled)
                    .disabled((!menu.canPrevious && !menu.loaded) || singleKeyDisabled)
                Button("Next Item") { model.performPlaybackShortcut(.nextItem) }
                    .playbackShortcut(.rightArrow, modifiers: [.option, .command], enabled: menu.playbackShortcutsEnabled)
                    .disabled(!menu.canNext || singleKeyDisabled)
                Button("Step Forward One Frame") { model.performPlaybackShortcut(.frame(backward: false)) }
                    .playbackShortcut(".", modifiers: [], enabled: menu.playbackShortcutsEnabled)
                    .disabled(!menu.hasVideo || singleKeyDisabled)
                Button("Step Back One Frame") { model.performPlaybackShortcut(.frame(backward: true)) }
                    .playbackShortcut(",", modifiers: [], enabled: menu.playbackShortcutsEnabled)
                    .disabled(!menu.hasVideo || singleKeyDisabled)
                Button("Volume Up") { model.performPlaybackShortcut(.volume(up: true)) }
                    .playbackShortcut(.upArrow, modifiers: [], enabled: menu.playbackShortcutsEnabled)
                    .disabled(singleKeyDisabled)
                Button("Volume Down") { model.performPlaybackShortcut(.volume(up: false)) }
                    .playbackShortcut(.downArrow, modifiers: [], enabled: menu.playbackShortcutsEnabled)
                    .disabled(singleKeyDisabled)
                Divider()
                Menu("Chapters") {
                    if menu.chapters.isEmpty { Text("No chapters available") }
                    ForEach(menu.chapters) { chapter in Button(chapter.title) { model.seek(chapter.time) } }
                }
                Picker("Repeat", selection: Binding(get: { menu.repeatMode }, set: { model.repeatMode = $0 })) {
                    Text("Off").tag("off"); Text("Current Video").tag("file"); Text("Play Queue").tag("queue")
                }
                ABLoopMenu(model: model)
                Button(menu.muted ? String(localized: "Unmute") : String(localized: "Mute")) { model.performPlaybackShortcut(.mute) }
                    .playbackShortcut("m", modifiers: [], enabled: menu.playbackShortcutsEnabled)
                    .disabled(singleKeyDisabled)
                Button("Stop") { model.stop() }
                    .disabled(!menu.hasPath)
                Divider()
                Button("Save Screenshot") { model.saveScreenshot() }
                    .playbackShortcut("s", modifiers: [.command, .option], enabled: menu.playbackShortcutsEnabled)
                    .disabled(!menu.loaded)
                Button("Save Screenshot As…") { model.saveScreenshotAs() }
                    .playbackShortcut("s", modifiers: [.command, .option, .shift], enabled: menu.playbackShortcutsEnabled)
                    .disabled(!menu.loaded)
                Button("Copy Frame") { model.frameActions.copyFrame() }
                    .disabled(!menu.loaded || !menu.hasVideo)
                Button("Add Time Marker") { model.frameActions.addMarker() }
                    .playbackShortcut("b", modifiers: [.command], enabled: menu.playbackShortcutsEnabled)
                    .disabled(!menu.loaded)
                Button("Show in Finder") { model.showInFinder() }
                    .disabled(!menu.hasPath)
                Button("Normal Speed") { model.setSpeed(1) }
                    .playbackShortcut("0", enabled: menu.playbackShortcutsEnabled)
                Button("Load Subtitles…") { model.openPanel(subtitle: true) }
                    .playbackShortcut("s", modifiers: [.command, .shift], enabled: menu.playbackShortcutsEnabled)
                Button("Copy Current Subtitle") { model.copyCurrentSubtitle() }
                    .playbackShortcut("c", modifiers: [.command, .shift], enabled: menu.playbackShortcutsEnabled)
                    .disabled(!menu.loaded)
            }.disabled(!menu.playerWindowCommandsEnabled)
        }
    }
}

private extension View {
    func playbackShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command, enabled: Bool) -> some View {
        keyboardShortcut(enabled ? KeyboardShortcut(key, modifiers: modifiers) : nil)
    }
}

// MARK: - Native macOS App Intents (Spotlight, Siri & Shortcuts Integration)

struct LumaPlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Play / Pause Video"
    static let description = IntentDescription("Toggle playback in Luma Player.")
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult {
        if let model = PlayerAppDelegate.sharedModel, model.loaded || !model.path.isEmpty {
            model.togglePause()
        }
        return .result()
    }
}

struct LumaNextVideoIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Video"
    static let description = IntentDescription("Skip to the next video in Luma Player's play queue.")
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult {
        if let model = PlayerAppDelegate.sharedModel, model.canNext {
            model.nextFile()
        }
        return .result()
    }
}

struct LumaPreviousVideoIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Video"
    static let description = IntentDescription("Return to the previous video or restart in Luma Player.")
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult {
        if let model = PlayerAppDelegate.sharedModel, model.loaded || model.canPrevious {
            model.previousOrRestart()
        }
        return .result()
    }
}

struct LumaToggleEnhancementsIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Video Enhancements"
    static let description = IntentDescription("Enable or disable AI Super Resolution and Frame Interpolation in Luma Player.")
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult {
        if let model = PlayerAppDelegate.sharedModel {
            model.master.toggle()
        }
        return .result()
    }
}

struct LumaSaveScreenshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Video Screenshot"
    static let description = IntentDescription("Capture and save the current video frame in Luma Player.")
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult {
        if let model = PlayerAppDelegate.sharedModel, model.loaded {
            model.saveScreenshot()
        }
        return .result()
    }
}

struct LumaToggleMiniPlayerIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Mini Player"
    static let description = IntentDescription("Switch Luma Player between the main window and floating Mini Player.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        if let model = PlayerAppDelegate.sharedModel {
            model.toggleMiniPlayer()
        }
        return .result()
    }
}

struct LumaAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LumaPlayPauseIntent(),
            phrases: ["Play or pause in \(.applicationName)", "Toggle playback in \(.applicationName)"],
            shortTitle: "Play / Pause",
            systemImageName: "playpause.fill"
        )
        AppShortcut(
            intent: LumaNextVideoIntent(),
            phrases: ["Next video in \(.applicationName)", "Skip video in \(.applicationName)"],
            shortTitle: "Next Video",
            systemImageName: "forward.end.fill"
        )
        AppShortcut(
            intent: LumaPreviousVideoIntent(),
            phrases: ["Previous video in \(.applicationName)"],
            shortTitle: "Previous Video",
            systemImageName: "backward.end.fill"
        )
        AppShortcut(
            intent: LumaToggleEnhancementsIntent(),
            phrases: ["Toggle enhancements in \(.applicationName)", "Enhance video in \(.applicationName)"],
            shortTitle: "Toggle Enhancements",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: LumaSaveScreenshotIntent(),
            phrases: ["Save screenshot in \(.applicationName)", "Capture frame in \(.applicationName)"],
            shortTitle: "Save Screenshot",
            systemImageName: "camera.fill"
        )
        AppShortcut(
            intent: LumaToggleMiniPlayerIntent(),
            phrases: ["Toggle Mini Player in \(.applicationName)"],
            shortTitle: "Mini Player",
            systemImageName: "pip.enter"
        )
    }
}
