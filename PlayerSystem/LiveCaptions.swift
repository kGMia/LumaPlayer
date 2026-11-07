// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Observation
import Speech
import AVFoundation

private struct CaptionPacket: Sendable {
    let data: Data
    let pts: Double
    let identity: String
    let state: String
}
private struct CaptionCue: Sendable {
    let start: Double
    let end: Double
    let text: String
}
private enum CaptionFailure: LocalizedError, Equatable {
    case unavailable, language, modelRequired, format, overrun, tap
    var errorDescription: String? {
        switch self {
        case .unavailable: return String(localized: "Apple SpeechTranscriber is unavailable on this Mac.")
        case .language: return String(localized: "This language is not supported by Apple SpeechTranscriber.")
        case .modelRequired: return String(localized: "Download the Apple speech model for this language to begin.")
        case .format: return String(localized: "Could not prepare the speech audio format.")
        case .overrun: return String(localized: "Recognition fell behind. Select Live Captions again to retry.")
        case .tap: return String(localized: "The audio tap is unavailable for this track.")
        }
    }
}

/// Audio conversion and analysis stay off the UI actor. Queues are bounded and a
/// discontinuity starts a new analysis epoch rather than splicing unrelated speech.
private actor CaptionRecognizer {
    private var analyzer: SpeechAnalyzer?
    private var resultTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AnalyzerInputConverter?
    private var locale: Locale?
    private var identity = ""
    private var expected: Double?
    private var origin = 0.0
    private var epoch = UUID()
    private var failure: Error?
    private var finalized = false
    private let emit: @Sendable (CaptionCue?) async -> Void
    init(emit: @escaping @Sendable (CaptionCue?) async -> Void) { self.emit = emit }

    func prepare(language: String, download: Bool) async throws {
        guard SpeechTranscriber.isAvailable else { throw CaptionFailure.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw CaptionFailure.language
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            guard download else { throw CaptionFailure.modelRequired }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }
        try Task.checkCancellation()
        self.locale = locale
        // Preheat before enabling the tap so model setup cannot fill its bounded queue.
        try await begin(at: 0)
    }
    private func begin(at pts: Double) async throws {
        await endSegment()
        try Task.checkCancellation()
        guard let locale else { throw CaptionFailure.language }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw CaptionFailure.format
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .utility, modelRetention: .lingering))
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        converter = AnalyzerInputConverter(analyzerFormat: format) { $0.primeMethod = .none }
        origin = pts
        let stream = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(24))
        continuation = stream.continuation
        let currentEpoch = epoch, base = pts, emit = emit
        resultTask = Task {
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled, currentEpoch == self.epoch else { break }
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    let start = base + result.range.start.seconds
                    let end = base + CMTimeRangeGetEnd(result.range).seconds
                    if !text.isEmpty, start.isFinite, end.isFinite {
                        await emit(CaptionCue(start: start, end: end, text: text))
                    }
                }
            } catch { if !Task.isCancelled, currentEpoch == self.epoch { self.failure = error } }
        }
        analysisTask = Task {
            do { try await analyzer.start(inputSequence: stream.stream) }
            catch { if !Task.isCancelled, currentEpoch == self.epoch { self.failure = error } }
        }
    }
    func consume(_ packets: AsyncStream<CaptionPacket>) async throws {
        for await packet in packets {
            try Task.checkCancellation()
            if let failure { throw failure }
            if ["tap-unavailable", "unsupported-audio", "conversion-unavailable", "conversion-error"].contains(packet.state) {
                throw CaptionFailure.tap
            }
            if packet.data.isEmpty {
                if packet.state == "finished" { try await finishInput() }
                continue
            }
            guard packet.data.count % 4 == 0, packet.pts.isFinite, packet.pts >= 0 else { continue }
            if identity.isEmpty { identity = packet.identity }
            if packet.identity != identity || expected.map({ abs(packet.pts - $0) > 0.1 }) == true || analyzer == nil {
                await emit(nil)
                try await begin(at: packet.pts)
                identity = packet.identity
            }
            let frames = packet.data.count / 4
            guard frames <= 32_000,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let channel = buffer.floatChannelData?[0] else { throw CaptionFailure.format }
            buffer.frameLength = AVAudioFrameCount(frames)
            packet.data.copyBytes(to: UnsafeMutableRawBufferPointer(start: channel, count: packet.data.count))
            expected = packet.pts + Double(frames) / 16_000
            // Sample-clock timestamps are relative to this epoch, mapped back to media PTS in results.
            let time = AVAudioTime(sampleTime: AVAudioFramePosition(((packet.pts - origin) * 16_000).rounded()), atRate: 16_000)
            for input in try converter?.convert(buffer, at: time) ?? [] {
                if case .dropped = continuation?.yield(input) { throw CaptionFailure.overrun }
            }
            if packet.state == "finished" { try await finishInput() }
        }
    }
    private func finishInput() async throws {
        guard let analyzer, !finalized else { return }
        finalized = true
        for input in try converter?.flush() ?? [] {
            if case .dropped = continuation?.yield(input) { throw CaptionFailure.overrun }
        }
        continuation?.finish(); continuation = nil
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    }
    private func endSegment() async {
        epoch = UUID()
        continuation?.finish(); continuation = nil
        resultTask?.cancel(); resultTask = nil
        analysisTask?.cancel(); analysisTask = nil
        let old = analyzer; analyzer = nil; converter = nil; failure = nil; finalized = false
        await old?.cancelAndFinishNow()
    }
    func stop() async { await endSegment(); expected = nil; identity = "" }
}

@MainActor @Observable final class LiveCaptionController {
    private(set) var text = ""
    private(set) var status = String(localized: "Off")
    private(set) var needsDownload = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var worker: CaptionRecognizer?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var key = ""
    @ObservationIgnored private var cues: [CaptionCue] = []
    @ObservationIgnored private weak var session: MPVSession?
    @ObservationIgnored private var lastPosition = 0.0
    @ObservationIgnored private var lastClock = 0.0
    @ObservationIgnored private var recognizing = false

    func update(session: MPVSession?, path: String, audio: String, language: String,
                enabled: Bool, position: Double, paused: Bool, seeking: Bool, download: Bool = false) {
        let desired = enabled && !path.isEmpty && audio != "no" ? path + "|" + audio + "|" + language : ""
        if desired != key || download {
            stop()
            key = desired
            if !desired.isEmpty, let session { start(session: session, language: language, download: download) }
            else if enabled { status = String(localized: "Waiting for an audio track") }
        }
        if enabled && desired.isEmpty && status != String(localized: "Waiting for an audio track") { status = String(localized: "Waiting for an audio track") }
        if recognizing {
            let phase = paused ? String(localized: "Paused · On-device") : String(localized: "Listening · On-device")
            if status != phase { status = phase }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if seeking || (lastClock > 0 && abs(position - lastPosition) > max(2, (now - lastClock) * 4)) {
            cues.removeAll(); text = ""
        }
        lastClock = now; lastPosition = position
        cues.removeAll { $0.end < position - 5 }
        // Never show decode-ahead text before its media timestamp. Late partial
        // results can remain readable briefly; this is live ASR, not zero-latency subtitles.
        let current = cues.last { $0.start <= position + 0.15 && $0.end + 3 >= position }
        let next = seeking ? "" : current?.text ?? ""
        if text != next { text = next }
    }
    private func start(session: MPVSession, language: String, download: Bool) {
        self.session = session
        let token = generation
        status = download ? String(localized: "Downloading Apple speech model…") : String(localized: "Preparing Apple Speech…")
        let worker = CaptionRecognizer { [weak self] cue in
            await self?.receive(cue, generation: token)
        }
        self.worker = worker
        task = Task { [weak self, weak session] in
            defer {
                await withTaskCancellationShield {
                    await worker.stop()
                }
            }
            do {
                try await worker.prepare(language: language, download: download)
                try Task.checkCancellation()
                guard let self, let session, self.generation == token else { return }
                let stream = AsyncStream<CaptionPacket>.makeStream(bufferingPolicy: .bufferingNewest(8))
                session.setCaptionAudioEnabled(true) { packet in
                    let data = packet["data"] as? Data ?? Data()
                    let pts = Double(packet["pts"] as? String ?? "") ?? .nan
                    let identity = "\(packet["epoch"] ?? "")|\(packet["serial"] ?? "")"
                    stream.continuation.yield(CaptionPacket(data: data, pts: pts, identity: identity,
                                                           state: packet["state"] as? String ?? "waiting"))
                }
                self.recognizing = true
                self.status = String(localized: "Listening · On-device")
                try await worker.consume(stream.stream)
            } catch {
                if !Task.isCancelled, let self, self.generation == token {
                    self.recognizing = false; self.cues.removeAll(); self.text = ""
                    self.needsDownload = (error as? CaptionFailure) == .modelRequired
                    self.status = error.localizedDescription
                    session?.setCaptionAudioEnabled(false, handler: nil)
                }
            }
        }
    }
    private func receive(_ cue: CaptionCue?, generation token: UUID) {
        guard token == generation else { return }
        guard let cue else { cues.removeAll(); text = ""; return }
        // Progressive results replace overlapping volatile phrases.
        cues.removeAll { $0.start >= cue.start - 0.05 || ($0.end > cue.start && $0.start <= cue.start) }
        cues.append(cue)
        if cues.count > 24 { cues.removeFirst(cues.count - 24) }
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil
        if let worker { Task { await worker.stop() } }; worker = nil
        session?.setCaptionAudioEnabled(false, handler: nil); session = nil
        key = ""; cues.removeAll(); text = ""; status = String(localized: "Off"); needsDownload = false
        lastClock = 0; recognizing = false
    }
}

struct SubtitleAppearance {
    struct Option: Identifiable, Equatable {
        let id: String
        let title: String
    }

    static var colorPresets: [Option] {
        [
            Option(id: "#FFFFFFFF", title: String(localized: "White")),
            Option(id: "#FFFFE14A", title: String(localized: "Yellow")),
            Option(id: "#FF5CE1FF", title: String(localized: "Cyan")),
            Option(id: "#FF7CFC8A", title: String(localized: "Green")),
            Option(id: "#FFF5E6C8", title: String(localized: "Warm Paper")),
            Option(id: "#FFD8DCE3", title: String(localized: "Soft Gray"))
        ]
    }

    static var fontPresets: [Option] {
        [
            Option(id: "sans-serif", title: String(localized: "System Sans-Serif")),
            Option(id: "PingFang TC", title: "PingFang TC"),
            Option(id: "PingFang SC", title: "PingFang SC"),
            Option(id: "Heiti TC", title: "Heiti TC"),
            Option(id: "Songti TC", title: "Songti TC"),
            Option(id: "Kaiti TC", title: "Kaiti TC"),
            Option(id: "Hiragino Sans", title: "Hiragino Sans"),
            Option(id: "Helvetica Neue", title: "Helvetica Neue"),
            Option(id: "Avenir Next", title: "Avenir Next"),
            Option(id: "Menlo", title: "Menlo")
        ]
    }

    static let sizePresets: [Int] = [28, 34, 38, 44, 52, 64]

    static func parseRGBA(_ hex: String) -> (r: Double, g: Double, b: Double, a: Double) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard let value = UInt64(cleaned, radix: 16) else { return (1, 1, 1, 1) }
        if cleaned.count == 8 {
            let a = Double((value >> 24) & 0xFF) / 255.0
            let r = Double((value >> 16) & 0xFF) / 255.0
            let g = Double((value >> 8) & 0xFF) / 255.0
            let b = Double(value & 0xFF) / 255.0
            return (r, g, b, a)
        } else if cleaned.count == 6 {
            let r = Double((value >> 16) & 0xFF) / 255.0
            let g = Double((value >> 8) & 0xFF) / 255.0
            let b = Double(value & 0xFF) / 255.0
            return (r, g, b, 1.0)
        }
        return (1, 1, 1, 1)
    }

    static func color(from hex: String) -> Color {
        let rgba = parseRGBA(hex)
        return Color(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }

    static func hex(from color: Color) -> String {
        guard let nsColor = NSColor(color).usingColorSpace(.sRGB) else { return "#FFFFFFFF" }
        let a = Int((min(1, max(0, nsColor.alphaComponent)) * 255.0).rounded())
        let r = Int((min(1, max(0, nsColor.redComponent)) * 255.0).rounded())
        let g = Int((min(1, max(0, nsColor.greenComponent)) * 255.0).rounded())
        let b = Int((min(1, max(0, nsColor.blueComponent)) * 255.0).rounded())
        return String(format: "#%02X%02X%02X%02X", a, r, g, b)
    }
}

struct LiveCaptionOverlay: View {
    @ObservedObject var model: PlayerModel
    let captions: LiveCaptionController
    var compact = false

    private var isSecondarySlot: Bool {
        model.liveCaptionPlacement == "top"
    }

    private var isTop: Bool {
        isSecondarySlot && model.secondarySubtitlePosition == "top"
    }

    private var bottomPadding: CGFloat {
        if isTop { return compact ? 58 : 96 }
        let scale = max(0.5, min(2.5, model.number("sub-scale") ?? 1.0))
        let gap: CGFloat = model.bilingualSubtitleSpacing == "standard" ? (compact ? 6 : 10) : (compact ? 1 : 2)
        // When Primary is Live Captions (upper) and Secondary mpv track is below it,
        // offset by the lower subtitle's rendered height + constant gap so the gap stays invariant when lower size changes.
        if !isSecondarySlot && model.secondarySubtitlePosition == "below" && model.secondarySubtitleID != "no" {
            let lowerDisplayHeight = CGFloat(max(18.0, min(96.0, model.secondarySubtitleFontSize)) * scale * (compact ? 0.48 : 0.72)) + 10
            return (compact ? 42 : 68) + lowerDisplayHeight + gap
        }
        // When Secondary is Live Captions (lower) placed below Primary mpv track.
        if isSecondarySlot && model.secondarySubtitlePosition == "below" && model.subtitleID != "no" {
            return compact ? 38 : 62
        }
        return compact ? 58 : 96
    }

    private var activeFontSize: Double {
        isSecondarySlot ? model.secondarySubtitleFontSize : model.subtitleFontSize
    }

    private var activeColorHex: String {
        isSecondarySlot ? model.secondarySubtitleColor : model.subtitleColor
    }

    private var captionFont: Font {
        let scale = max(0.5, min(2.5, model.number("sub-scale") ?? 1.0))
        let base = max(18.0, min(96.0, activeFontSize)) * scale
        let size = CGFloat(compact ? base * 0.42 : base * 0.63)
        let family = model.subtitleFont.trimmingCharacters(in: .whitespacesAndNewlines)
        if family.isEmpty || family == "sans-serif" {
            return .system(size: size, weight: .medium)
        }
        return .custom(family, size: size)
    }

    var body: some View {
        VStack {
            if !isTop { Spacer(minLength: 0) }
            if !captions.text.isEmpty {
                let isBox = model.subtitleBorderStyle == "box"
                let shadowRadius: CGFloat = model.subtitleOutlineSize == "bold" ? 4.5 : model.subtitleOutlineSize == "thin" ? 1.5 : 3.0
                let boxShape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                Text(captions.text)
                    .font(captionFont)
                    .foregroundStyle(SubtitleAppearance.color(from: activeColorHex))
                    .multilineTextAlignment(.center)
                    .lineLimit(3).truncationMode(.head)
                    .padding(.horizontal, isBox ? 14 : 6)
                    .padding(.vertical, isBox ? 6 : 2)
                    .shadow(color: isBox ? .clear : .black.opacity(0.95), radius: shadowRadius, x: 0, y: 1)
                    .shadow(color: isBox ? .clear : .black.opacity(0.85), radius: shadowRadius * 0.6, x: 0, y: 0)
                    .background {
                        if isBox {
                            boxShape
                                .fill(Color.black.opacity(0.42))
                                .glassEffect(.regular, in: boxShape)
                        }
                    }
                    .padding(.horizontal, compact ? 20 : 54)
                    .accessibilityLabel("Live captions: " + captions.text)
            }
            if isTop { Spacer(minLength: 0) }
        }
        .padding(.top, compact ? 32 : 52)
        .padding(.bottom, bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

struct SubtitleStyleControls: View {
    @ObservedObject var model: PlayerModel

    private var primaryColorBinding: Binding<Color> {
        Binding(
            get: { SubtitleAppearance.color(from: model.subtitleColor) },
            set: { model.subtitleColor = SubtitleAppearance.hex(from: $0) }
        )
    }

    private var secondaryColorBinding: Binding<Color> {
        Binding(
            get: { SubtitleAppearance.color(from: model.secondarySubtitleColor) },
            set: { model.secondarySubtitleColor = SubtitleAppearance.hex(from: $0) }
        )
    }

    private func matchingPresetColor(_ hex: String) -> String {
        let current = hex.uppercased()
        if SubtitleAppearance.colorPresets.contains(where: { $0.id.uppercased() == current }) {
            return current
        }
        return "custom"
    }

    var body: some View {
        Picker("Second Subtitle Position", selection: $model.secondarySubtitlePosition) {
            Text("Below Primary Subtitles").tag("below")
            Text("Top of Video").tag("top")
        }
        if model.secondarySubtitlePosition == "below" {
            Picker("Bilingual Subtitle Spacing", selection: $model.bilingualSubtitleSpacing) {
                Text("Compact").tag("compact")
                Text("Standard").tag("standard")
            }
        }
        Picker("Subtitle Font", selection: $model.subtitleFont) {
            ForEach(SubtitleAppearance.fontPresets) { preset in
                Text(preset.title).tag(preset.id)
            }
            if !SubtitleAppearance.fontPresets.contains(where: { $0.id == model.subtitleFont }) {
                Text(model.subtitleFont).tag(model.subtitleFont)
            }
            Divider()
            ForEach(NSFontManager.shared.availableFontFamilies.filter { family in
                !SubtitleAppearance.fontPresets.contains(where: { $0.id == family })
            }, id: \.self) { family in
                Text(family).tag(family)
            }
        }
        Picker("Subtitle Background", selection: $model.subtitleBorderStyle) {
            Text("Outline & Shadow").tag("outline")
            Text("Translucent Box").tag("box")
        }
        if model.subtitleBorderStyle != "box" {
            Picker("Outline Thickness", selection: $model.subtitleOutlineSize) {
                Text("Thin").tag("thin")
                Text("Standard").tag("standard")
                Text("Bold").tag("bold")
            }
        }
        LabeledContent("Primary Subtitle Size") {
            HStack(spacing: 8) {
                Slider(value: $model.subtitleFontSize, in: 18...96, step: 2)
                    .frame(width: 150)
                    .accessibilityLabel("Primary Subtitle Size")
                Text("\(Int(model.subtitleFontSize.rounded())) pt")
                    .monospacedDigit()
                    .frame(minWidth: 42, alignment: .trailing)
            }
        }
        HStack(spacing: 10) {
            let currentPrimary = matchingPresetColor(model.subtitleColor)
            Picker("Primary Subtitle Color", selection: Binding(
                get: { currentPrimary },
                set: { newValue in
                    if newValue != "custom" { model.subtitleColor = newValue }
                }
            )) {
                ForEach(SubtitleAppearance.colorPresets) { preset in
                    Text(preset.title).tag(preset.id)
                }
                if currentPrimary == "custom" {
                    Text("Custom").tag("custom")
                }
            }
            ColorPicker("", selection: primaryColorBinding, supportsOpacity: true)
                .labelsHidden()
                .help("Choose custom subtitle color")
        }
        LabeledContent("Second Subtitle Size") {
            HStack(spacing: 8) {
                Slider(value: $model.secondarySubtitleFontSize, in: 18...96, step: 2)
                    .frame(width: 150)
                    .accessibilityLabel("Second Subtitle Size")
                Text("\(Int(model.secondarySubtitleFontSize.rounded())) pt")
                    .monospacedDigit()
                    .frame(minWidth: 42, alignment: .trailing)
            }
        }
        HStack(spacing: 10) {
            let currentSecondary = matchingPresetColor(model.secondarySubtitleColor)
            Picker("Second Subtitle Color", selection: Binding(
                get: { currentSecondary },
                set: { newValue in
                    if newValue != "custom" { model.secondarySubtitleColor = newValue }
                }
            )) {
                ForEach(SubtitleAppearance.colorPresets) { preset in
                    Text(preset.title).tag(preset.id)
                }
                if currentSecondary == "custom" {
                    Text("Custom").tag("custom")
                }
            }
            ColorPicker("", selection: secondaryColorBinding, supportsOpacity: true)
                .labelsHidden()
                .help("Choose custom subtitle color")
        }
        Toggle("Apply Style to ASS / Styled Subtitles", isOn: $model.subtitleOverrideASS)
    }
}

struct SubtitleControls: View {
    @ObservedObject var model: PlayerModel
    let captions: LiveCaptionController
    init(model: PlayerModel) { self.model = model; self.captions = model.liveCaptions }
    var body: some View {
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
        Button("Load Subtitles…", systemImage: "doc.badge.plus") { model.openPanel(subtitle: true) }
        Button("Load Second Subtitles…", systemImage: "captions.bubble") { model.openPanel(subtitle: true, secondary: true) }
        SubtitleStyleControls(model: model)
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
            Label(captions.status, systemImage: "waveform")
                .font(.caption).foregroundStyle(.secondary)
            if captions.needsDownload {
                Button("Download Apple Speech Model", systemImage: "arrow.down.circle") { model.updateLiveCaptions(download: true) }
            } else {
                Button("Restart Live Captions", systemImage: "arrow.clockwise") { model.liveCaptions.stop(); model.updateLiveCaptions() }
            }
        }
        Text("Live captions use the selected audio track on this Mac; no microphone is recorded. Recognition has a delay and does not translate. Apple language support varies. Bitmap second subtitles may keep their original position.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
