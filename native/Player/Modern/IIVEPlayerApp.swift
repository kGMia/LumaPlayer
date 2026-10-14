// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@MainActor final class PlayerAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: PlayerModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Hiding the main window can invoke this callback even while the mini
        // NSPanel is visible. It is a presentation change, not the end of playback.
        guard let model else { return true }
        return !model.miniPlayer && !model.windowTransition && !model.windowModes.hasMiniPlayerWindow
    }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }

}
@main struct IIVEPlayerApp: App {
    @NSApplicationDelegateAdaptor(PlayerAppDelegate.self) private var delegate
    @StateObject private var model = PlayerModel()
    var body: some Scene {
        Window("IIVE Player", id: "player") {
            PlayerView(model: model).onAppear { delegate.model = model }.onOpenURL { model.open($0) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .defaultLaunchBehavior(.presented)
        .commands {
            PlayerWindowCommands(model: model)
            PlayerFileCommands(model: model)
            CommandGroup(after: .toolbar) {
                Button(model.fullScreen ? "Exit Full Screen" : "Enter Full Screen") { model.toggleFullScreen() }
                    .keyboardShortcut("f", modifiers: [.control, .command])
                Button(model.miniPlayer ? "Restore Player" : "Mini Player") { model.toggleMiniPlayer() }.keyboardShortcut("p", modifiers: [.option, .command])
                Toggle("Enable Enhancements", isOn: $model.master).keyboardShortcut("e", modifiers: [.command, .shift])
                Toggle("Video Information", isOn: $model.showVideoInfo).keyboardShortcut("i")
                Button(model.fullScreen ? "Enhancement Settings" : "Sidebar") { if model.inspector && !model.fullScreen { model.inspector = false } else { model.showSidebar("enhance") } }.keyboardShortcut("i", modifiers: [.option, .command])
            }
            CommandMenu("Playback") {
                Button(model.paused ? "Play" : "Pause") { model.togglePause() }.keyboardShortcut(.space, modifiers: [])
                Button("Back \(Int(model.seekSeconds)) Seconds") { model.skip(-1) }.keyboardShortcut(.leftArrow, modifiers: []).disabled(!model.loaded)
                Button("Forward \(Int(model.seekSeconds)) Seconds") { model.skip(1) }.keyboardShortcut(.rightArrow, modifiers: []).disabled(!model.loaded)
                Button("Back \(Int(model.longSeekSeconds)) Seconds") { model.skip(-1, long: true) }.keyboardShortcut(.leftArrow, modifiers: [.shift]).disabled(!model.loaded)
                Button("Forward \(Int(model.longSeekSeconds)) Seconds") { model.skip(1, long: true) }.keyboardShortcut(.rightArrow, modifiers: [.shift]).disabled(!model.loaded)
                Button("Previous Frame") { model.stepFrame(backward: true) }.keyboardShortcut(.leftArrow, modifiers: [.command]).disabled(!model.loaded)
                Button("Next Frame") { model.stepFrame() }.keyboardShortcut(.rightArrow, modifiers: [.command]).disabled(!model.loaded)
                Button("Previous Video") { model.previousFile() }.keyboardShortcut(.leftArrow, modifiers: [.option, .command]).disabled(!model.canPrevious)
                Button("Next Video") { model.nextFile() }.keyboardShortcut(.rightArrow, modifiers: [.option, .command]).disabled(!model.canNext)
                Button("Step Forward One Frame") { model.stepFrame() }.keyboardShortcut(".", modifiers: []).disabled(!model.loaded)
                Button("Step Back One Frame") { model.stepFrame(backward: true) }.keyboardShortcut(",", modifiers: []).disabled(!model.loaded)
                Button("Volume Up") { model.changeVolume(1) }.keyboardShortcut(.upArrow, modifiers: [])
                Button("Volume Down") { model.changeVolume(-1) }.keyboardShortcut(.downArrow, modifiers: [])
                Divider()
                Menu("Chapters") {
                    if model.chapters.isEmpty { Text("No chapters available") }
                    ForEach(model.chapters) { chapter in Button(chapter.title) { model.seek(chapter.time) } }
                }
                Picker("Repeat", selection: $model.repeatMode) {
                    Text("Off").tag("off"); Text("Current Video").tag("file"); Text("Play Queue").tag("queue")
                }
                Button(model.muted ? "Unmute" : "Mute") { model.toggleMute() }.keyboardShortcut("m", modifiers: [])
                Button("Stop") { model.stop() }.disabled(model.path.isEmpty)
                Divider()
                Button("Save Screenshot…") { model.saveScreenshot() }.keyboardShortcut("s", modifiers: [.command, .option]).disabled(!model.loaded)
                Button("Show in Finder") { model.showInFinder() }.disabled(model.path.isEmpty)
                Button("Normal Speed") { model.setSpeed(1) }.keyboardShortcut("0")
                Button("Load Subtitles…") { model.openPanel(subtitle: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
        Settings { PlayerSettings(model: model) }
    }
}

struct PlayerWindowCommands: Commands {
    @ObservedObject var model: PlayerModel
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Player") { openWindow(id: "player") }
            Button("Play Queue") { openWindow(id: "player"); model.showSidebar("queue") }.keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}

struct PlayerFileCommands: Commands {
    @ObservedObject var model: PlayerModel
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video…") { openWindow(id: "player"); model.openPanel() }.keyboardShortcut("o")
                Button("Add to Play Queue…") { openWindow(id: "player"); model.openPanel(append: true) }.keyboardShortcut("o", modifiers: [.command, .shift])
                Menu("Open Recent") {
                    ForEach(model.recent, id: \.self) { path in
                        Button(URL(fileURLWithPath: path).lastPathComponent) { openWindow(id: "player"); model.open(URL(fileURLWithPath: path)) }
                    }
                }
            }
    }
}
