// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

extension PlayerModel {
    var outputDescription: String {
        let output = snapshot["video-out-params"] as? [String: Any] ?? [:]
        guard let w = output["w"] as? NSNumber, let h = output["h"] as? NSNumber else { return "N/A" }
        return "\(w) × \(h)"
    }
    func fps(_ key: String) -> String {
        guard let value = number(key), value.isFinite, value > 0 else { return "N/A" }
        return String(format: "%.3f fps", value)
    }
    var viewportDescription: String {
        guard let w = number("viewport-width"), let h = number("viewport-height"), w > 0, h > 0 else { return "N/A" }
        return "\(Int(w)) × \(Int(h)) px"
    }
    var pictureDescription: String {
        guard let dims = snapshot["osd-dimensions"] as? [String: NSNumber],
              let w = dims["w"], let h = dims["h"], let ml = dims["ml"], let mr = dims["mr"],
              let mt = dims["mt"], let mb = dims["mb"], w.doubleValue > 0, h.doubleValue > 0 else { return "N/A" }
        let width = w.doubleValue - ml.doubleValue - mr.doubleValue
        let height = h.doubleValue - mt.doubleValue - mb.doubleValue
        guard width > 0, height > 0 else { return "N/A" }
        return "\(Int(width.rounded())) × \(Int(height.rounded())) px"
    }
    func selectedTrack(_ type: String) -> [String: Any] {
        let tracks = snapshot["track-list"] as? [[String: Any]] ?? []
        return tracks.first { $0["type"] as? String == type && $0["selected"] as? Bool == true } ?? [:]
    }
    var sourceCodec: String {
        let video = selectedTrack("video")
        return [video["codec"] as? String, video["codec-profile"] as? String].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "N/A"
    }
    var audioCodec: String { selectedTrack("audio")["codec"] as? String ?? "N/A" }
    func bitrate(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else { return "N/A" }
        return value >= 1_000_000 ? String(format: "%.2f Mbps", value / 1_000_000) : String(format: "%.0f kbps", value / 1_000)
    }
    var videoBitrate: String { bitrate(number("video-bitrate")) }
    var declaredVideoBitrate: String { bitrate((selectedTrack("video")["demux-bitrate"] as? NSNumber)?.doubleValue) }
    var sourceColor: String {
        ["primaries", "gamma", "colormatrix", "colorlevels"].map { source[$0] as? String ?? "N/A" }.joined(separator: " · ")
    }
    var hudDecoderDescription: String {
        let raw = (snapshot["hwdec-current"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let active: String
        switch raw {
        case "", "no": active = "Software"
        case "videotoolbox": active = "VideoToolbox (HW)"
        case "videotoolbox-copy": active = "VideoToolbox Copy"
        default: active = raw
        }
        return "\(active) · req \(effectiveDecoderOption)"
    }
    func jobTime(_ label: String) -> String {
        guard let value = Double(meta(label)["processing_ms"] ?? ""), value.isFinite else { return "N/A" }
        return String(format: "%.2f ms", value)
    }
}

struct VideoInformationHUD: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var telemetry: PlayerTelemetryState
    init(model: PlayerModel) {
        self.model = model
        self.telemetry = model.telemetry
    }
    var body: some View {
        let _ = telemetry.snapshot.count
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "film").foregroundStyle(.secondary)
                Text("Source").foregroundStyle(.secondary)
                Text(model.sourceDescription)
                Text(model.fps("container-fps")).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "display").foregroundStyle(.secondary)
                Text("Output").foregroundStyle(.secondary)
                Text(model.outputDescription)
                Text(model.fps("estimated-vf-fps")).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "cpu").foregroundStyle(.secondary)
                Text("Decoder").foregroundStyle(.secondary)
                Text(model.hudDecoderDescription)
            }
            Text("\(model.sourceCodec) · \(model.videoBitrate)").lineLimit(2)
            Text("CPU \(model.processCPU) · Memory \(model.memoryDescription("process-memory-bytes"))")
            Text("Video packet bitrate · Output cadence estimated from frame timestamps").font(.caption2).foregroundStyle(.secondary)
        }.font(.caption.monospacedDigit()).padding(14).modifier(PlaybackGlass())
        .allowsHitTesting(false)
    }
}

struct VideoInformationRows: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var telemetry: PlayerTelemetryState
    init(model: PlayerModel) {
        self.model = model
        self.telemetry = model.telemetry
    }
    var body: some View {
        let _ = telemetry.snapshot.count
        LabeledContent("Source", value: model.sourceDescription)
        LabeledContent("Source FPS (container)", value: model.fps("container-fps"))
        LabeledContent("Video codec / profile", value: model.sourceCodec)
        LabeledContent("Active hardware decoder", value: model.snapshot["hwdec-current"] as? String ?? "N/A")
        LabeledContent("Requested decoder", value: model.effectiveDecoderOption)
        LabeledContent("Video bitrate (packet estimate)", value: model.videoBitrate)
        LabeledContent("Declared video bitrate", value: model.declaredVideoBitrate)
        LabeledContent("Audio codec", value: model.audioCodec)
        LabeledContent("Audio bitrate (packet estimate)", value: model.bitrate(model.number("audio-bitrate")))
        Text("Packet bitrate is estimated between keyframes and may update slowly. It is not network speed or total file bitrate.").font(.caption).foregroundStyle(.secondary)
        LabeledContent("Source pixel format", value: model.source["pixelformat"] as? String ?? "N/A")
        Text(model.sourceColor).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        LabeledContent("Filter output", value: model.outputDescription)
        LabeledContent("Output FPS (estimated)", value: model.fps("estimated-vf-fps"))
        LabeledContent("Picture area", value: model.pictureDescription)
        LabeledContent("Render viewport", value: model.viewportDescription)
        LabeledContent("Render callbacks", value: model.renderRate)
        LabeledContent("Measured display FPS", value: "N/A")
        LabeledContent("Player CPU", value: model.processCPU)
        LabeledContent("Player memory footprint", value: model.memoryDescription("process-memory-bytes"))
        LabeledContent("Resident memory", value: model.memoryDescription("process-resident-bytes"))
        Text("CPU samples this process once per second; 100% equals one CPU core. Memory is this process, not system usage.").font(.caption).foregroundStyle(.secondary)
        LabeledContent("Added rotation", value: "\(Int(model.number("video-rotate") ?? Double(model.rotation)))°")
        Text(model.colorProfileStatus).font(.caption).foregroundStyle(.secondary)
        Text("Output FPS uses recent frame timestamps, not physical display measurements; it may fluctuate after seeks and does not include playback speed. Filter output precedes any display shader. Picture area includes final display scaling.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

extension PlayerModel {
    var effectiveDecoderOption: String {
        switch decoder {
        case "auto": return "auto"
        case "videotoolbox-copy": return "videotoolbox-copy"
        default: return "no"
        }
    }
    var decoderExplanation: String {
        let active = snapshot["hwdec-current"] as? String ?? "N/A"
        return "Requested: \(effectiveDecoderOption) · Active: \(active)"
    }
    func applyDecoder() {
        guard session != nil, lastDecoderOption != effectiveDecoderOption else { return }
        lastDecoderOption = effectiveDecoderOption
        command(["set", "hwdec", lastDecoderOption])
    }
    func setPictureValue(_ key: String, _ value: Double) {
        UserDefaults.standard.set(value, forKey: key)
        command(["set", key, String(value)])
    }
    func applyPictureSettings() {
        command(["set", "video-rotate", String(rotation)])
        for (key, value) in [("brightness", brightness), ("contrast", contrast), ("saturation", saturation), ("gamma", gamma), ("hue", hue)] { command(["set", key, String(value)]) }
        applyColorProfile()
    }
    func applyLook(_ name: String) {
        brightness = 0; contrast = 0; saturation = 0; gamma = 0; hue = 0
        switch name {
        case "vivid": contrast = 8; saturation = 12
        case "soft": contrast = -8; saturation = -5
        case "mono": saturation = -100
        default: break
        }
    }
    func chooseColorProfile() {
        let panel = NSOpenPanel()
        panel.title = "Choose RGB ICC Profile"
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        menuState.modalPanelActive = true
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuState.modalPanelActive = NSApp?.modalWindow != nil
                guard response == .OK, let url = panel.url else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let data = await Task.detached(priority: .utility) { () -> Data? in
                        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1024 * 1024 else { return nil }
                        return try? Data(contentsOf: url)
                    }.value
                    guard let data, NSColorSpace(iccProfileData: data)?.colorSpaceModel == .rgb else {
                        self.colorProfileStatus = "Invalid or unsupported RGB ICC profile (maximum 16 MB)."; return
                    }
                    // Keep a small validated copy so removing the original file does not break playback.
                    UserDefaults.standard.set(data, forKey: "customICCData")
                    UserDefaults.standard.set(url.lastPathComponent, forKey: "customICCName")
                    self.colorProfile = "custom"
                }
            }
        }
    }
    func applyColorProfile() {
        colorProfileTask?.cancel()
        guard let view = videoView, session != nil else { return }
        let mode = colorProfile
        let data: Data?
        let label: String
        switch mode {
        case "display": data = view.window?.screen?.colorSpace?.iccProfileData; label = "Current Display ICC"
        case "srgb": data = NSColorSpace.sRGB.iccProfileData; label = "sRGB ICC"
        case "p3": data = NSColorSpace.displayP3.iccProfileData; label = "Display P3 ICC"
        case "custom": data = UserDefaults.standard.data(forKey: "customICCData"); label = UserDefaults.standard.string(forKey: "customICCName") ?? "Custom ICC"
        default: data = nil; label = "Automatic · source metadata"
        }
        guard mode == "auto" || data != nil else {
            command(["set", "icc-profile-auto", "no"])
            colorProfileStatus = "Unavailable · ICC profile not provided"; return
        }
        // libmpv render clients must provide display ICC bytes explicitly.
        command(["set", "icc-profile-auto", "no"])
        colorProfileStatus = mode == "auto" ? label : "Loading \(label)…"
        colorProfileTask = Task { [weak self, weak view] in
            guard let self, let view else { return }
            let accepted = await view.setICCProfileData(data)
            guard !Task.isCancelled, self.videoView === view, self.colorProfile == mode else { return }
            if accepted {
                self.command(["set", "icc-profile-auto", mode == "auto" ? "no" : "yes"])
                self.colorProfileStatus = mode == "auto" ? label : "Configured · \(label)"
            } else { self.colorProfileStatus = "Unavailable · renderer rejected ICC profile" }
        }
    }
    var processCPU: String {
        number("process-cpu-percent").map { String(format: "%.1f%%", $0) } ?? "N/A"
    }
    func memoryDescription(_ key: String) -> String {
        guard let value = number(key), value.isFinite, value >= 0 else { return "N/A" }
        return ByteCountFormatter.string(fromByteCount: Int64(min(value, Double(Int64.max / 2))), countStyle: .memory)
    }
}

struct DecoderSettings: View {
    @ObservedObject var model: PlayerModel
    var body: some View {
        Picker("Decoder", selection: $model.decoder) {
            Label("Software", systemImage: "cpu").tag("no")
            Label("Auto · Hardware Enabled", systemImage: "bolt.circle").tag("auto")
            Label("Hardware · Copy", systemImage: "square.on.square").tag("videotoolbox-copy")
        }
        Text(model.decoderExplanation).font(.caption).foregroundStyle(.secondary)
        Text("Changes apply to the current video and are saved. Auto shares zero-copy VideoToolbox IOSurfaces with native enhancement filters when supported. Unsupported hardware formats fall back automatically; changing modes may briefly interrupt decoding.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
struct PictureSettings: View {
    @ObservedObject var model: PlayerModel
    var body: some View {
        Picker("Rotation · Added to File Orientation", selection: $model.rotation) {
            Text("0°").tag(0); Text("90° Clockwise").tag(90); Text("180°").tag(180); Text("270° Clockwise").tag(270)
        }
        HStack {
            Text("Looks")
            Spacer()
            Button("Neutral") { model.applyLook("neutral") }
            Button("Vivid") { model.applyLook("vivid") }
            Button("Soft") { model.applyLook("soft") }
            Button("Mono") { model.applyLook("mono") }
        }
        adjustment("Brightness", "sun.max", $model.brightness)
        adjustment("Contrast", "circle.lefthalf.filled", $model.contrast)
        adjustment("Saturation", "drop.halffull", $model.saturation)
        adjustment("Gamma", "circle.righthalf.filled", $model.gamma)
        adjustment("Hue", "paintpalette", $model.hue)
        Text("Display adjustments are non-destructive and saved. Looks replace these five adjustments. Rotation may bypass native enhancement on unsupported orientations.").font(.caption).foregroundStyle(.secondary)
        Picker("Output Color Profile", selection: $model.colorProfile) {
            Text("Automatic · Source Metadata").tag("auto")
            Text("Current Display ICC").tag("display")
            Text("sRGB ICC").tag("srgb")
            Text("Display P3 ICC").tag("p3")
            if UserDefaults.standard.data(forKey: "customICCData") != nil { Text("Custom ICC").tag("custom") }
        }
        Button("Load RGB ICC Profile…", systemImage: "doc.badge.plus") { model.chooseColorProfile() }
        Text(model.colorProfileStatus).font(.caption).foregroundStyle(.secondary)
        Text("ICC describes the output display, not the source. Choose a profile matching your display; sRGB/P3 are manual overrides, not HDR upgrades. Existing HDR enhancement restrictions still apply.").font(.caption).foregroundStyle(.secondary)
    }
    private func adjustment(_ title: String, _ symbol: String, _ value: Binding<Double>) -> some View {
        LabeledContent { HStack {
            Slider(value: value, in: -100...100, step: 1).accessibilityLabel(title)
            Text(String(format: "%+.0f", value.wrappedValue)).monospacedDigit().frame(width: 40)
        } } label: { Label(title, systemImage: symbol) }
    }
}
