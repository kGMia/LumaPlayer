// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct PlayerSettings: View {
    @ObservedObject var model: PlayerModel
    let telemetry: PlayerTelemetryState
    init(model: PlayerModel) {
        self.model = model
        self.telemetry = model.telemetry
    }
    var body: some View {
        let _ = telemetry.revision
        TabView {
            Form {
                Section("Viewing") {
                    Picker("Controls Theme", selection: $model.chromeTheme) {
                        Text("Dark Glass").tag("dark")
                        Text("Adaptive to Video").tag("adaptive")
                        Text("System Theme").tag("system")
                    }
                    Text("Synchronizes the Liquid Glass appearance across the top window buttons, transport bar, sidebar, and fullscreen popovers.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Show Live Video Information", isOn: $model.showVideoInfo)
                    Text("Resolution, cadence, decoder, video codec and packet bitrate. Toggle at any time with ⌘I or the information button in the playback bar.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Show Timeline Hover Preview", isOn: $model.showTimelinePreview)
                    Text("Displays a video frame thumbnail, chapter title, and timestamp bubble when hovering or dragging across the progress bar.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Automatically Hide Playback Controls", isOn: $model.autoHideControls)
                    Stepper(value: $model.controlsHideDelay, in: 1...15, step: 1) {
                        LabeledContent("Hide controls after", value: "\(Int(model.controlsHideDelay)) seconds")
                    }.disabled(!model.autoHideControls)
                    Picker("Double-click video", selection: $model.doubleClickAction) {
                        Text("Toggle Full Screen").tag("fullscreen")
                        Text("Play / Pause").tag("pause")
                        Text("Do Nothing").tag("none")
                    }
                    Toggle("Resume Videos Where You Left Off", isOn: $model.resumePlayback)
                    Toggle("Add Media from the Same Folder", isOn: $model.autoQueueFolder)
                    Text("Enabling this also scans the current folder immediately. Adds missing local media only; subfolders and hidden files are excluded. Choose playback order in the queue menu.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Play Queue") {
                    Picker("Sort", selection: $model.queueSort) {
                        Text("Custom / Added Order").tag("custom")
                        Text("Filename").tag("name")
                        Text("Date Created · Oldest First").tag("created")
                    }
                    Toggle("Show Covers and File Sizes", isOn: $model.queueDetailed)
                    Text("Title and duration are always shown. Drag rows to reorder in Custom mode. Unavailable metadata is shown as N/A.").font(.caption).foregroundStyle(.secondary)
                    if !model.folderQueueStatus.isEmpty { Text(model.folderQueueStatus).font(.caption).foregroundStyle(.secondary) }
                }
                Section("Screenshots") {
                    LabeledContent("Save images to") {
                        Text(model.frameActions.folder.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    }
                    Button("Choose Screenshot Folder…", systemImage: "folder") { model.frameActions.chooseFolder() }
                    Text("Save Image writes a uniquely named PNG immediately. Save Image As lets you choose a location. Captures include displayed video and mpv subtitles, without controls or live-caption overlays. HDR is captured as displayed SDR.").font(.caption).foregroundStyle(.secondary)
                }
                Section("History") {
                    LabeledContent("Recent videos", value: "\(model.recent.count)")
                    Button("Clear Recent Videos & Saved Positions") { model.clearRecent() }
                    Text("Only local playback history is cleared. Media files are untouched.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Mini Player") {
                    Toggle("Always on Top", isOn: $model.miniAlwaysOnTop)
                    Toggle("Show on All Desktops", isOn: $model.miniAllSpaces)
                    Text("The main window hides while video plays in the floating window. Close the mini window or press Esc to restore it. Switching uses a short fade and respects Reduce Motion.").font(.caption).foregroundStyle(.secondary)
                    Text("Use ⌥⌘P to enter or restore. Double-click or Esc always restores the normal player. Controls hide according to the viewing preference above.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }
            Form {
                Section("Enhancement") { EnhancementControls(model: model) }
                Section("Automatic Activation Limits") {
                    Stepper(value: $model.srMinimumScale, in: 1.05...2, step: 0.05) {
                        LabeledContent("Start SR above display scale", value: String(format: "%.2f×", model.srMinimumScale))
                    }
                    heightPicker("SR maximum source height", selection: $model.srMaximumHeight)
                    Stepper(value: $model.fiMaximumFPS, in: 24...60, step: 1) {
                        LabeledContent("Interpolate sources up to", value: "\(Int(model.fiMaximumFPS)) fps")
                    }
                    heightPicker("Interpolation maximum source height", selection: $model.fiMaximumHeight)
                    Text("Limits use the source video's resolution and container frame rate. Super resolution also compares the current viewport scale against the source display size.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("A limit bypasses the selected effect and explains why in its status. It does not lower inference resolution or change your chosen model.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Reset Activation Limits") { model.resetActivationLimits() }
                }
                Section {
                    Text("Changes apply immediately and are saved. RIFE Fast / 48 fps is the starting point; performance depends on the video and active effects.")
                    Text("Native effects currently require supported SDR input. Unsupported formats are bypassed and reported in the player inspector.")
                }.font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped).tabItem { Label("Enhancement", systemImage: "sparkles") }
            Form {
                Section("Decoder") { DecoderSettings(model: model) }
                Section("Picture & Color") { PictureSettings(model: model) }
                Section("Playback") {
                    Picker("Repeat", selection: $model.repeatMode) {
                        Text("Off").tag("off"); Text("Current Video").tag("file"); Text("Play Queue").tag("queue")
                    }
                }
                Section("Audio & Subtitles · Current Session") {
                    Picker("Audio", selection: Binding(get: { model.audioID }, set: { model.selectTrack("aid", $0) })) {
                        Text("None").tag("no")
                        ForEach(model.audioTracks) { Text($0.title).tag(String($0.id)) }
                    }
                    SubtitleControls(model: model)
                    Stepper(value: numberBinding("audio-delay", default: 0), in: -10...10, step: 0.1) {
                        LabeledContent("Audio delay", value: String(format: "%+.1f s", model.number("audio-delay") ?? 0))
                    }
                    Stepper(value: numberBinding("sub-delay", default: 0), in: -60...60, step: 0.1) {
                        LabeledContent("Subtitle delay", value: String(format: "%+.1f s", model.number("sub-delay") ?? 0))
                    }
                    Stepper(value: numberBinding("secondary-sub-delay", default: 0), in: -60...60, step: 0.1) {
                        LabeledContent("Second subtitle delay", value: String(format: "%+.1f s", model.number("secondary-sub-delay") ?? 0))
                    }
                    LabeledContent("Subtitle size") {
                        Slider(value: numberBinding("sub-scale", default: 1), in: 0.5...2.5, step: 0.1)
                            .frame(width: 170).accessibilityLabel("Subtitle size")
                        Text(String(format: "%.0f%%", (model.number("sub-scale") ?? 1) * 100)).monospacedDigit()
                    }
                    Button("Reset Timing & Subtitle Size") {
                        model.command(["set", "audio-delay", "0"]); model.command(["set", "sub-delay", "0"])
                        model.command(["set", "sub-scale", "1"])
                    }
                    Text("Positive delay presents audio or subtitles later. Subtitle scaling depends on the subtitle format.")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(!model.loaded)
            }.formStyle(.grouped).tabItem { Label("Playback", systemImage: "play.rectangle") }
            Form {
                Section("Seek & Volume") {
                    Stepper(value: $model.seekSeconds, in: 1...120, step: 1) {
                        LabeledContent("← / → and transport buttons", value: "\(Int(model.seekSeconds)) seconds")
                    }
                    Stepper(value: $model.longSeekSeconds, in: 1...600, step: 5) {
                        LabeledContent("⇧← / ⇧→", value: "\(Int(model.longSeekSeconds)) seconds")
                    }
                    Stepper(value: $model.volumeStep, in: 1...20, step: 1) {
                        LabeledContent("↑ / ↓ volume step", value: "\(Int(model.volumeStep))%")
                    }
                }
                Section("Keyboard Shortcuts") {
                    LabeledContent("Play / Pause", value: "Space")
                    LabeledContent("Previous / Next Frame", value: "⌘← / ⌘→ · , / .")
                    LabeledContent("Previous / Next Video", value: "⌥⌘← / ⌥⌘→")
                    LabeledContent("Full Screen", value: "⌃⌘F")
                    LabeledContent("Mini Player / Restore", value: "⌥⌘P · Esc to restore")
                    LabeledContent("Play Queue", value: "⇧⌘P")
                    LabeledContent("Enhancement Panel", value: "⌥⌘I")
                    LabeledContent("Toggle Enhancements", value: "⇧⌘E")
                    LabeledContent("Video Information", value: "⌘I")
                    LabeledContent("Mute / Normal Speed", value: "M / ⌘0")
                    LabeledContent("Screenshot / Subtitles", value: "⌥⌘S / ⇧⌘S")
                    LabeledContent("Save Image", value: "⌥⌘S")
                    LabeledContent("Save Image As", value: "⇧⌥⌘S")
                    LabeledContent("Add Time Marker", value: "⌘B")
                    LabeledContent("Settings", value: "⌘,")
                    Text("Frame stepping pauses playback. Backward stepping seeks and decodes again; speed and precision depend on the media and active interpolation filters.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("Controls", systemImage: "keyboard") }
        }.frame(width: 640, height: 650)
    }
    private func heightPicker(_ title: String, selection: Binding<Double>) -> some View {
        Picker(title, selection: selection) {
            Text("No Limit").tag(0.0)
            Text("720p").tag(720.0)
            Text("1080p").tag(1080.0)
            Text("1440p").tag(1440.0)
            Text("2160p (4K)").tag(2160.0)
        }
    }
    private func numberBinding(_ key: String, default value: Double) -> Binding<Double> {
        Binding(get: { model.number(key) ?? value }, set: {
            model.command(["set", key, String($0)])
            model.telemetry.flush()
        })
    }
}
