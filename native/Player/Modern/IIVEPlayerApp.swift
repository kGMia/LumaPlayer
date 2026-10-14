// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@MainActor final class PlayerAppDelegate: NSObject, NSApplicationDelegate {
    let model = PlayerModel()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Hiding the main window can invoke this callback even while the mini
        // NSPanel is visible. It is a presentation change, not the end of playback.
        !model.miniPlayer && !model.windowTransition && !model.windowModes.hasMiniPlayerWindow
    }
    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }
}

@main struct IIVEPlayerApp: App {
    @NSApplicationDelegateAdaptor(PlayerAppDelegate.self) private var delegate
    var body: some Scene {
        let model = delegate.model
        let menu = model.menuState
        Window("IIVE Player", id: "player") {
            PlayerView(model: model).onOpenURL { model.open($0) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .defaultLaunchBehavior(.presented)
        .commands {
            PlayerWindowCommands(model: model)
            PlayerFileCommands(model: model, menu: menu)
            PlayerViewCommands(model: model, menu: menu)
            PlayerPlaybackCommands(model: model, menu: menu)
        }
        Settings { PlayerSettings(model: model) }
    }
}

struct PlayerWindowCommands: Commands {
    let model: PlayerModel
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Player") { openWindow(id: "player") }
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
            Button("Open Video…") { openWindow(id: "player"); model.openPanel() }
                .keyboardShortcut("o")
            Button("Add to Play Queue…") { openWindow(id: "player"); model.openPanel(append: true) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Menu("Open Recent") {
                if menu.recent.isEmpty { Text("No recent videos") }
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
            Button(menu.fullScreen ? "Exit Full Screen" : "Enter Full Screen") { model.toggleFullScreen() }
                .keyboardShortcut("f", modifiers: [.control, .command])
            Button(menu.miniPlayer ? "Restore Player" : "Mini Player") { model.toggleMiniPlayer() }
                .keyboardShortcut("p", modifiers: [.option, .command])
            Toggle("Enable Enhancements", isOn: Binding(get: { menu.master }, set: { model.master = $0 }))
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Toggle("Video Information", isOn: Binding(get: { menu.showVideoInfo }, set: { model.showVideoInfo = $0 }))
                .keyboardShortcut("i")
            Button(menu.fullScreen ? "Enhancement Settings" : "Sidebar") {
                if menu.inspector && !menu.fullScreen { model.inspector = false }
                else { model.showSidebar("enhance") }
            }.keyboardShortcut("i", modifiers: [.option, .command])
        }
    }
}

struct PlayerPlaybackCommands: Commands {
    let model: PlayerModel
    @ObservedObject var menu: PlayerMenuState
    var body: some Commands {
        let singleKeyDisabled = menu.modalPanelActive
        CommandMenu("Playback") {
            Button(menu.paused ? "Play" : "Pause") { model.togglePause() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(singleKeyDisabled)
            Button("Back \(Int(menu.seekSeconds)) Seconds") { model.skip(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!menu.loaded || singleKeyDisabled)
            Button("Forward \(Int(menu.seekSeconds)) Seconds") { model.skip(1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!menu.loaded || singleKeyDisabled)
            Button("Back \(Int(menu.longSeekSeconds)) Seconds") { model.skip(-1, long: true) }
                .keyboardShortcut(.leftArrow, modifiers: [.shift])
                .disabled(!menu.loaded || singleKeyDisabled)
            Button("Forward \(Int(menu.longSeekSeconds)) Seconds") { model.skip(1, long: true) }
                .keyboardShortcut(.rightArrow, modifiers: [.shift])
                .disabled(!menu.loaded || singleKeyDisabled)
            Button("Previous Frame") { model.stepFrame(backward: true) }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(!menu.loaded)
            Button("Next Frame") { model.stepFrame() }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .disabled(!menu.loaded)
            Button("Previous Video") { model.previousFile() }
                .keyboardShortcut(.leftArrow, modifiers: [.option, .command])
                .disabled(!menu.canPrevious)
            Button("Next Video") { model.nextFile() }
                .keyboardShortcut(.rightArrow, modifiers: [.option, .command])
                .disabled(!menu.canNext)
            Button("Step Forward One Frame") { model.stepFrame() }
                .keyboardShortcut(".", modifiers: [])
                .disabled(!menu.loaded || singleKeyDisabled)
            Button("Step Back One Frame") { model.stepFrame(backward: true) }
                .keyboardShortcut(",", modifiers: [])
                .disabled(!menu.loaded || singleKeyDisabled)
            Button("Volume Up") { model.changeVolume(1) }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(singleKeyDisabled)
            Button("Volume Down") { model.changeVolume(-1) }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(singleKeyDisabled)
            Divider()
            Menu("Chapters") {
                if menu.chapters.isEmpty { Text("No chapters available") }
                ForEach(menu.chapters) { chapter in Button(chapter.title) { model.seek(chapter.time) } }
            }
            Picker("Repeat", selection: Binding(get: { menu.repeatMode }, set: { model.repeatMode = $0 })) {
                Text("Off").tag("off"); Text("Current Video").tag("file"); Text("Play Queue").tag("queue")
            }
            Button(menu.muted ? "Unmute" : "Mute") { model.toggleMute() }
                .keyboardShortcut("m", modifiers: [])
                .disabled(singleKeyDisabled)
            Button("Stop") { model.stop() }
                .disabled(!menu.hasPath)
            Divider()
            Button("Save Screenshot…") { model.saveScreenshot() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(!menu.loaded)
            Button("Show in Finder") { model.showInFinder() }
                .disabled(!menu.hasPath)
            Button("Normal Speed") { model.setSpeed(1) }
                .keyboardShortcut("0")
            Button("Load Subtitles…") { model.openPanel(subtitle: true) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }
}
