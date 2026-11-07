// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct PlayerSettings: View {
    @ObservedObject var model: PlayerModel
    let telemetry: PlayerTelemetryState
    @AppStorage("browser.defaultFolderPath") private var defaultFolderPath = ""
    @AppStorage("library.spotlightEnabled") private var spotlightEnabled = false
    @State private var defaultFolderError = ""
    @State private var confirmClearHistory = false
    @State private var selectedDestination: String? = "general"
    private var selectedPage: PlayerSettingsPage {
        PlayerSettingsDestination.find(selectedDestination)?.page ?? .general
    }
    private var searchResults: [PlayerSettingsDestination] {
        PlayerSettingsDestination.results(for: searchText)
    }
    @State private var searchText = ""
    init(model: PlayerModel) {
        self.model = model
        self.telemetry = model.telemetry
    }
    var body: some View {
        let _ = telemetry.revision
        NavigationSplitView {
            List(selection: $selectedDestination) {
                ForEach(searchResults) { destination in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(destination.title, systemImage: destination.page.symbol)
                        if destination.section != nil {
                            Text(destination.page.title).font(.caption).foregroundStyle(.secondary)
                        }
                    }.tag(destination.id)
                }
            }
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .searchable(text: $searchText, prompt: "Find Settings")
            .overlay {
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && searchResults.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .allowsHitTesting(false)
                }
            }
        } detail: {
            ScrollViewReader { proxy in
                settingsContent(selectedPage)
                    .navigationTitle(selectedPage.title)
                    .frame(minWidth: 460)
                    .task(id: selectedDestination) {
                        // Let the newly selected Form mount before resolving its section anchor.
                        await Task.yield()
                        guard !Task.isCancelled,
                              let destination = PlayerSettingsDestination.find(selectedDestination),
                              destination.section != nil else { return }
                        proxy.scrollTo(destination.id, anchor: .top)
                    }
            }
            .id(selectedPage)
        }
        .frame(minWidth: 700, idealWidth: 820, minHeight: 560, idealHeight: 650)
        .confirmationDialog("Clear Recent Videos & Saved Positions?", isPresented: $confirmClearHistory,
                            titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { model.clearRecent() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Local playback history and saved positions will be removed. Your media files will not be changed.")
        }
    }
    @ViewBuilder
    private func settingsContent(_ page: PlayerSettingsPage) -> some View {
        switch page {
        case .general:
                Form {
                    OnlineMovieSettings()
                    Section("Viewing") {
                        Picker("Controls Theme", selection: $model.chromeTheme) {
                            Text("Dark Glass").tag("dark")
                            Text("Adaptive to Video").tag("adaptive")
                            Text("System Theme").tag("system")
                        }
                        .pickerStyle(.tabs)
                        .buttonBorderShape(.capsule)
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
                        LabeledContent("Hide controls after", value: String(localized: "\(Int(model.controlsHideDelay)) seconds"))
                    }.disabled(!model.autoHideControls)
                    Picker("Double-click video", selection: $model.doubleClickAction) {
                        Text("Toggle Full Screen").tag("fullscreen")
                        Text("Play / Pause").tag("pause")
                        Text("Do Nothing").tag("none")
                    }
                    Toggle("Resume Videos Where You Left Off", isOn: $model.resumePlayback)
                    Toggle("Remember Speed, Audio & Subtitles per File", isOn: $model.rememberMediaSelections)
                    Text("Remembers up to 100 local files. Restores embedded tracks before playback; external subtitles and live captions are not reopened automatically. Clear Recent also clears these records.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Add Media from the Same Folder", isOn: $model.autoQueueFolder)
                    Text("Enabling this also scans the current folder immediately. Adds missing local or supported WebDAV media; subfolders and hidden files are excluded. Choose playback order in the queue menu.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Float on Top", isOn: $model.mainWindowFloatOnTop)
                }.id("general.Viewing")
                Section("File Browser") {
                    LabeledContent("Default Folder", value: defaultFolderPath.isEmpty ? String(localized: "Not Set") : defaultFolderPath)
                    Button("Choose Default Folder…", systemImage: "folder.badge.plus") {
                        model.fileDialogs.importFiles(title: "Choose Default Folder", types: [.folder]) { result in
                            if case .success(let urls) = result, let url = urls.first {
                                do { try model.fileDialogs.saveDefaultBrowserFolder(url); defaultFolderError = "" }
                                catch { defaultFolderError = error.localizedDescription }
                            }
                        }
                    }
                    Button("Clear Default Folder", role: .destructive) { model.fileDialogs.clearDefaultBrowserFolder() }
                        .disabled(defaultFolderPath.isEmpty)
                    Text("Folder access is remembered across launches. If macOS revokes access or the folder moves, choose it again.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !defaultFolderError.isEmpty { Text(defaultFolderError).foregroundStyle(.red) }
                    Toggle("Include Default Folder in Spotlight", isOn: $spotlightEnabled)
                        .disabled(defaultFolderPath.isEmpty && !spotlightEnabled)
                        .onChange(of: spotlightEnabled) { _, value in PlayerSpotlightLibrary.shared.setEnabled(value) }
                    Text("Indexes up to 10,000 local media files and NFO titles, actors and tags. Network media is excluded. Refresh after external file changes.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Refresh Spotlight Index", systemImage: "arrow.clockwise") { PlayerSpotlightLibrary.shared.refresh() }
                            .disabled(!spotlightEnabled || defaultFolderPath.isEmpty || PlayerSpotlightLibrary.shared.busy)
                        if PlayerSpotlightLibrary.shared.busy { ProgressView().controlSize(.small) }
                    }
                    if spotlightEnabled {
                        Text("Indexed media: \(PlayerSpotlightLibrary.shared.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    if !PlayerSpotlightLibrary.shared.error.isEmpty {
                        Text(PlayerSpotlightLibrary.shared.error).font(.caption).foregroundStyle(.red)
                    }
                }.id("general.File Browser")
                Section("Background Performance") {
                    Text(PlayerEnergyPolicy.shared.constrained ? String(localized: "Energy Saving · 1 Background Task") : String(localized: "Normal · 2 Background Tasks"))
                    Text("Low Power Mode or high temperature reduces background concurrency. Playback and timeline seeking keep their own resources.")
                        .font(.caption).foregroundStyle(.secondary)
                }.id("general.Background Performance")
                Section("Play Queue") {
                    Picker("Sort", selection: $model.queueSort) {
                        Text("Custom / Added Order").tag("custom")
                        Text("Filename").tag("name")
                        Text("Date Created · Oldest First").tag("created")
                    }
                    Toggle("Show Covers and File Sizes", isOn: $model.queueDetailed)
                    Text("Title and duration are always shown. Drag rows to reorder in Custom mode. Unavailable metadata is shown as N/A.").font(.caption).foregroundStyle(.secondary)
                    if !model.folderQueueStatus.isEmpty { Text(model.folderQueueStatus).font(.caption).foregroundStyle(.secondary) }
                }.id("general.Play Queue")
                Section("Screenshots") {
                    LabeledContent("Save images to") {
                        Text(model.frameActions.folder.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    }
                    Button("Choose Screenshot Folder…", systemImage: "folder") { model.frameActions.chooseFolder() }
                    Text("Save Image writes a uniquely named PNG immediately. Save Image As lets you choose a location. Captures include displayed video and mpv subtitles, without controls or live-caption overlays. HDR is captured as displayed SDR.").font(.caption).foregroundStyle(.secondary)
                }.id("general.Screenshots")
                Section("History") {
                    LabeledContent("Recent videos", value: "\(model.recent.count)")
                    Button("Clear Recent Videos & Saved Positions", role: .destructive) { confirmClearHistory = true }
                    Text("Only local playback history is cleared. Media files are untouched.").font(.caption).foregroundStyle(.secondary)
                }.id("general.History")
                Section("Mini Player") {
                    Toggle("Always on Top", isOn: $model.miniAlwaysOnTop)
                    Toggle("Show on All Desktops", isOn: $model.miniAllSpaces)
                    Text("The main window hides while video plays in the floating window. Close the mini window or press Esc to restore it. Switching uses a short fade and respects Reduce Motion.").font(.caption).foregroundStyle(.secondary)
                    Text("Use ⌥⌘P to enter or restore. Double-click or Esc always restores the normal player. Controls hide according to the viewing preference above.").font(.caption).foregroundStyle(.secondary)
                }.id("general.Mini Player")
                }
                .formStyle(.grouped)
        case .enhancement:
                Form {
                    Section("Enhancement") { EnhancementControls(model: model) }.id("enhancement.Enhancement")
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
                    }.id("enhancement.Automatic Activation Limits")
                    Section {
                        Text("Changes apply immediately and are saved. RIFE Fast / 48 fps is the starting point; performance depends on the video and active effects.")
                        Text("Native effects currently require supported SDR input. Unsupported formats are bypassed and reported in the player inspector.")
                    }.font(.caption).foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
        case .playback:
                Form {
                    Section("Decoder") { DecoderSettings(model: model) }.id("playback.Decoder")
                    Section("Picture & Color") { PictureSettings(model: model) }.id("playback.Picture & Color")
                    Section("Playback") {
                        ABLoopMenu(model: model)
                        Text(model.playbackGeometry.loopDescription).font(.caption).foregroundStyle(.secondary)
                        Text("Set A, move forward, then set B to repeat the interval. Loop points reset when opening media. Seeking beyond B leaves the loop until playback crosses B again.")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("Repeat", selection: $model.repeatMode) {
                            Text("Off").tag("off"); Text("Current Video").tag("file"); Text("Play Queue").tag("queue")
                        }
                        .pickerStyle(.tabs)
                        .buttonBorderShape(.capsule)
                    }.id("playback.Playback")
                    Section("Audio · Current Session") {
                        Picker("Audio", selection: Binding(get: { model.audioID }, set: { model.selectTrack("aid", $0) })) {
                            Text("None").tag("no")
                            ForEach(model.audioTracks) { Text($0.title).tag(String($0.id)) }
                        }
                        Stepper(value: numberBinding("audio-delay", default: 0), in: -10...10, step: 0.1) {
                            LabeledContent("Audio delay", value: String(format: "%+.1f s", model.number("audio-delay") ?? 0))
                        }
                    }.id("playback.Audio · Current Session")
                    PlaybackPreferencesView(model: model).id("playback.Playback Preferences")
                }
                .formStyle(.grouped)
        case .subtitles:
                Form {
                Section("Tracks & Bilingual") {
                    Picker("Primary Subtitles", selection: Binding(get: {
                        !model.systemHDRActive && model.liveCaptionPlacement == "bottom" ? "live" : model.subtitleID
                    }, set: { model.selectSubtitle($0, secondary: false) })) {
                        Text(String(localized: "Off")).tag("no")
                        Label("Live Captions · Apple Speech", systemImage: "waveform").tag("live")
                        ForEach(model.subtitles) { Text($0.title).tag(String($0.id)) }
                    }
                    Picker(model.secondarySubtitlePosition == "below" ? String(localized: "Second Subtitles · Below") : String(localized: "Second Subtitles · Top"), selection: Binding(get: {
                        !model.systemHDRActive && model.liveCaptionPlacement == "top" ? "live" : model.secondarySubtitleID
                    }, set: { model.selectSubtitle($0, secondary: true) })) {
                        Text(String(localized: "Off")).tag("no")
                        Label("Live Captions · Apple Speech", systemImage: "waveform").tag("live")
                        ForEach(model.subtitles) { Text($0.title).tag(String($0.id)) }
                    }
                    Toggle("Automatically Load Matching External Subtitles", isOn: $model.autoLoadExternalSubtitles)
                    Text("Automatically discovers matching subtitle files in the video folder (or Subs / Subtitles subfolders) and pairs Chinese + English/foreign tracks for bilingual viewing.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button("Load Subtitles…", systemImage: "doc.badge.plus") { model.openPanel(subtitle: true) }
                        Button("Load Second Subtitles…", systemImage: "captions.bubble") { model.openPanel(subtitle: true, secondary: true) }
                        Spacer()
                        Button("Copy Current Subtitle", systemImage: "doc.on.doc") { model.copyCurrentSubtitle() }
                            .disabled(!model.hasActiveSubtitleText)
                    }
                }.id("subtitles.Tracks & Bilingual")
                Section("Layout & Appearance") {
                    SubtitleStyleControls(model: model)
                }.id("subtitles.Layout & Appearance")
                Section("Timing & Live Captions") {
                    Stepper(value: numberBinding("sub-delay", default: 0), in: -60...60, step: 0.1) {
                        LabeledContent("Subtitle delay", value: String(format: "%+.1f s", model.number("sub-delay") ?? 0))
                    }
                    Stepper(value: numberBinding("secondary-sub-delay", default: 0), in: -60...60, step: 0.1) {
                        LabeledContent("Second subtitle delay", value: String(format: "%+.1f s", model.number("secondary-sub-delay") ?? 0))
                    }
                    LabeledContent("Subtitle scale") {
                        Slider(value: numberBinding("sub-scale", default: 1), in: 0.5...2.5, step: 0.1)
                            .frame(width: 170).accessibilityLabel("Subtitle scale")
                        Text(String(format: "%.0f%%", (model.number("sub-scale") ?? 1) * 100)).monospacedDigit()
                    }
                    Picker("Speech Language", selection: $model.captionLanguage) {
                        Text("English (US)").tag("en-US")
                        Text("Chinese (Simplified)").tag("zh-CN")
                        Text("Chinese (Traditional)").tag("zh-TW")
                        Text("Japanese").tag("ja-JP")
                        Text("Korean").tag("ko-KR")
                        Text("French").tag("fr-FR")
                        Text("German").tag("de-DE")
                        Text("Spanish").tag("es-ES")
                    }
                    if model.liveCaptionPlacement != "off" {
                        Label(model.liveCaptions.status, systemImage: "waveform")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.liveCaptions.needsDownload {
                            Button("Download Apple Speech Model", systemImage: "arrow.down.circle") { model.updateLiveCaptions(download: true) }
                        } else {
                            Button("Restart Live Captions", systemImage: "arrow.clockwise") { model.liveCaptions.stop(); model.updateLiveCaptions() }
                        }
                    }
                    Button("Reset Timing & Subtitle Style") {
                        model.resetSubtitleAppearanceAndTiming()
                    }
                    Text("Positive delay presents subtitles later (use Z / X or ⇧Z / ⇧X during playback). Live captions use the selected audio track on this Mac; no microphone is recorded.")
                        .font(.caption).foregroundStyle(.secondary)
                    }.id("subtitles.Timing & Live Captions")
                }
                .formStyle(.grouped)
        case .controls:
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
                    }.id("controls.Seek & Volume")
                    Section("Keyboard Shortcuts") {
                        LabeledContent("Play / Pause", value: "Space")
                        LabeledContent("Previous / Next Frame", value: "⌘← / ⌘→ · , / .")
                        LabeledContent("Previous / Next Video", value: "⌥⌘← / ⌥⌘→")
                        LabeledContent("Full Screen", value: "⌃⌘F")
                        LabeledContent("Mini Player / Restore", value: "⌥⌘P · Esc to restore")
                        LabeledContent("Float on Top", value: "⌥⌘T")
                        LabeledContent("Play Queue", value: "⇧⌘P")
                        LabeledContent("Enhancement Panel", value: "⌥⌘I")
                        LabeledContent("Toggle Enhancements", value: "⇧⌘E")
                        LabeledContent("Video Information", value: "⌘I")
                        LabeledContent("Mute / Normal Speed", value: "M / ⌘0")
                        LabeledContent("Subtitle Delay", value: "Z / X · ⇧Z / ⇧X")
                        LabeledContent("Copy Current Subtitle", value: "⇧⌘C")
                        LabeledContent("Screenshot / Subtitles", value: "⌥⌘S / ⇧⌘S")
                        LabeledContent("Save Image", value: "⌥⌘S")
                        LabeledContent("Save Image As", value: "⇧⌥⌘S")
                        LabeledContent("Add Time Marker", value: "⌘B")
                        LabeledContent("Settings", value: "⌘,")
                        Text("Frame stepping pauses playback. Backward stepping seeks and decodes again; speed and precision depend on the media and active interpolation filters.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.id("controls.Keyboard Shortcuts")
                }
                .formStyle(.grouped)
        case .network:
                NetworkServerSettings(model: model)
        }
    }
    private func heightPicker(_ title: LocalizedStringKey, selection: Binding<Double>) -> some View {
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
            if key == "sub-scale" { model.applySubtitleAppearance() }
            model.telemetry.flush()
        })
    }
}

/// Search is category navigation; terms cover localized labels and common aliases.
enum PlayerSettingsPage: String, CaseIterable, Identifiable {
    case general, enhancement, playback, subtitles, controls, network
    var id: Self { self }
    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .enhancement: String(localized: "Enhancement")
        case .playback: String(localized: "Playback")
        case .subtitles: String(localized: "Subtitles")
        case .controls: String(localized: "Controls")
        case .network: String(localized: "Network")
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .enhancement: "sparkles"
        case .playback: "play.rectangle"
        case .subtitles: "captions.bubble"
        case .controls: "keyboard"
        case .network: "network"
        }
    }
    func matches(_ query: String) -> Bool {
        PlayerSettingsDestination.results(for: query).contains { $0.page == self }
    }
}

struct PlayerSettingsDestination: Identifiable {
    let page: PlayerSettingsPage
    let section: String?
    var terms: [String] = []
    var id: String { section.map { page.rawValue + "." + $0 } ?? page.rawValue }
    var title: String { section.map { String(localized: String.LocalizationValue($0)) } ?? page.title }
    static let sections: [Self] = [
        .init(page: .general, section: "Viewing", terms: ["Controls Theme", "Dark Glass", "Adaptive to Video", "System Theme", "Synchronizes the Liquid Glass appearance across the top window buttons, transport bar, sidebar, and fullscreen popovers.", "Show Live Video Information", "Resolution, cadence, decoder, video codec and packet bitrate. Toggle at any time with ⌘I or the information button in the playback bar.", "Show Timeline Hover Preview", "Displays a video frame thumbnail, chapter title, and timestamp bubble when hovering or dragging across the progress bar.", "Automatically Hide Playback Controls", "Hide controls after", "Double-click video", "Toggle Full Screen", "Play / Pause", "Do Nothing", "Resume Videos Where You Left Off", "Remember Speed, Audio & Subtitles per File", "Remembers up to 100 local files. Restores embedded tracks before playback; external subtitles and live captions are not reopened automatically. Clear Recent also clears these records.", "Add Media from the Same Folder", "Enabling this also scans the current folder immediately. Adds missing local or supported WebDAV media; subfolders and hidden files are excluded. Choose playback order in the queue menu.", "Float on Top", "appearance theme 主题 主題 预览 預覽 resume 续播 續播"]),
        .init(page: .general, section: "File Browser", terms: ["Default Folder", "Choose Default Folder…", "Clear Default Folder", "Folder access is remembered across launches. If macOS revokes access or the folder moves, choose it again.", "Include Default Folder in Spotlight", "Indexes up to 10,000 local media files and NFO titles, actors and tags. Network media is excluded. Refresh after external file changes.", "Refresh Spotlight Index", "folder 目录 目錄 默认 預設 Spotlight"]),
        .init(page: .general, section: "Background Performance", terms: ["Low Power Mode or high temperature reduces background concurrency. Playback and timeline seeking keep their own resources."]),
        .init(page: .general, section: "Play Queue", terms: ["Sort", "Custom / Added Order", "Filename", "Date Created · Oldest First", "Show Covers and File Sizes", "Title and duration are always shown. Drag rows to reorder in Custom mode. Unavailable metadata is shown as N/A.", "playlist 播放列表 播放清單 sort 排序"]),
        .init(page: .general, section: "Screenshots", terms: ["Save images to", "Choose Screenshot Folder…", "Save Image writes a uniquely named PNG immediately. Save Image As lets you choose a location. Captures include displayed video and mpv subtitles, without controls or live-caption overlays. HDR is captured as displayed SDR.", "screenshot 截图 截圖 image 图片 圖片"]),
        .init(page: .general, section: "History", terms: ["Recent videos", "Clear Recent Videos & Saved Positions", "Only local playback history is cleared. Media files are untouched.", "history 历史 歷史 记录 紀錄"]),
        .init(page: .general, section: "Mini Player", terms: ["Always on Top", "Show on All Desktops", "The main window hides while video plays in the floating window. Close the mini window or press Esc to restore it. Switching uses a short fade and respects Reduce Motion.", "Use ⌥⌘P to enter or restore. Double-click or Esc always restores the normal player. Controls hide according to the viewing preference above.", "mini 迷你 小窗 floating 悬浮 浮動"]),
        .init(page: .enhancement, section: "Enhancement", terms: ["Super Resolution", "Interpolation", "Model", "Target FPS", "Performance Fallback", "RIFE FSRCNNX fps Apple 超分 超解析度 插帧 超帧 補幀"]),
        .init(page: .enhancement, section: "Automatic Activation Limits", terms: ["Start SR above display scale", "SR maximum source height", "Interpolate sources up to", "Interpolation maximum source height", "Limits use the source video's resolution and container frame rate. Super resolution also compares the current viewport scale against the source display size.", "A limit bypasses the selected effect and explains why in its status. It does not lower inference resolution or change your chosen model.", "Reset Activation Limits", "threshold 阈值 門檻 分辨率 解析度"]),
        .init(page: .playback, section: "Decoder", terms: ["hardware software 解码 解碼 软解 軟解 硬解"]),
        .init(page: .playback, section: "Picture & Color", terms: ["HDR EDR ICC rotation 旋转 旋轉 色彩 color aspect ratio"]),
        .init(page: .playback, section: "Playback", terms: ["Set A, move forward, then set B to repeat the interval. Loop points reset when opening media. Seeking beyond B leaves the loop until playback crosses B again.", "Repeat", "Off", "Current Video", "Play Queue"]),
        .init(page: .playback, section: "Audio · Current Session", terms: ["Audio", "None", "Audio delay", "audio sound 音频 音訊 delay 延迟 延遲"]),
        .init(page: .subtitles, section: "Tracks & Bilingual", terms: ["Primary Subtitles", "Automatically Load Matching External Subtitles", "Automatically discovers matching subtitle files in the video folder (or Subs / Subtitles subfolders) and pairs Chinese + English/foreign tracks for bilingual viewing.", "Load Subtitles…", "Load Second Subtitles…", "Copy Current Subtitle", "字幕 双语 雙語 external 外挂 外掛"]),
        .init(page: .subtitles, section: "Layout & Appearance", terms: ["font 字体 字型 样式 樣式"]),
        .init(page: .subtitles, section: "Timing & Live Captions", terms: ["Subtitle delay", "Second subtitle delay", "Subtitle scale", "Speech Language", "English (US)", "Chinese (Simplified)", "Chinese (Traditional)", "Japanese", "Korean", "French", "German", "Spanish", "Download Apple Speech Model", "Restart Live Captions", "Reset Timing & Subtitle Style", "Positive delay presents subtitles later (use Z / X or ⇧Z / ⇧X during playback). Live captions use the selected audio track on this Mac; no microphone is recorded.", "speech 语音 語音 live 实时 即時 delay 延迟 延遲"]),
        .init(page: .controls, section: "Seek & Volume", terms: ["← / → and transport buttons", "⇧← / ⇧→", "↑ / ↓ volume step", "seek 快进 快退 快進 快轉 音量 volume"]),
        .init(page: .controls, section: "Keyboard Shortcuts", terms: ["Play / Pause", "Previous / Next Frame", "Previous / Next Video", "Full Screen", "Mini Player / Restore", "Float on Top", "Play Queue", "Enhancement Panel", "Toggle Enhancements", "Video Information", "Mute / Normal Speed", "Subtitle Delay", "Copy Current Subtitle", "Screenshot / Subtitles", "Save Image", "Save Image As", "Add Time Marker", "Settings", "Frame stepping pauses playback. Backward stepping seeks and decodes again; speed and precision depend on the media and active interpolation filters.", "快捷键 快捷鍵 keyboard shortcut frame 逐帧 逐格"]),
        .init(page: .playback, section: "Playback Preferences", terms: ["Speed", "Equalizer", "倍速 均衡器 audio 音频 音訊"]),
        .init(page: .network, section: nil, terms: ["WebDAV", "OneDrive", "Server", "Account", "Cache", "服务器 伺服器 网盘 雲端 账号 帳號 缓存 快取"])
    ]
    static func find(_ id: String?) -> Self? {
        guard let id else { return nil }
        if let section = sections.first(where: { $0.id == id }) { return section }
        return PlayerSettingsPage(rawValue: id).map { Self(page: $0, section: nil) }
    }
    static func results(for query: String) -> [Self] {
        let tokens = query.split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty else { return PlayerSettingsPage.allCases.map { Self(page: $0, section: nil) } }
        return sections.filter { destination in
            let labels = destination.terms.flatMap { [$0, String(localized: String.LocalizationValue($0))] }
            let haystack = ([destination.page.rawValue, destination.page.title, destination.section ?? "", destination.title] + labels).joined(separator: " ")
            return tokens.allSatisfy { haystack.localizedStandardContains(String($0)) }
        }
    }
}
