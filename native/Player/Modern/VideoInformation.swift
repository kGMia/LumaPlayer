// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

extension PlayerModel {
    var audioFormatDescription: String {
        let parameters = snapshot["audio-params"] as? [String: Any] ?? [:]
        let rate = (parameters["samplerate"] as? NSNumber).map { String(format: "%.1f kHz", $0.doubleValue / 1000) } ?? "N/A"
        let channels = parameters["channels"] as? String ?? "N/A"
        let format = parameters["format"] as? String ?? "N/A"
        return "\(rate) · \(channels) · \(format)"
    }

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
    var dolbyVisionProfile: Int? { (selectedTrack("video")["dolby-vision-profile"] as? NSNumber)?.intValue }
    var isDolbyVision: Bool { dolbyVisionProfile != nil || source["colormatrix"] as? String == "dolbyvision" }
    var dolbyVisionStatus: String {
        let profile = dolbyVisionProfile.map { "Profile \($0) · " } ?? ""
        if !dolbyVisionMapping { return profile + "RPU mapping disabled · base layer only (Profile 5 colors may be incorrect)" }
        let mapped = (snapshot["vo-passes"] as? [String] ?? []).contains { $0.contains("IIVE Dolby Vision RPU mapping") }
        if mapped { return profile + "RPU mapping → SDR · experimental" }
        if dolbyVisionProfile == 5 { return profile + "RPU mapping unavailable · colors may be incorrect; try Software decoding" }
        return profile + "Base layer only · RPU mapping not confirmed; try Software decoding"
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
    func jobPercentiles(_ label: String) -> String {
        let metadata = meta(label)
        guard let count = Int(metadata["latency_samples"] ?? ""), count > 0,
              let p50 = Double(metadata["p50_processing_ms"] ?? ""),
              let p95 = Double(metadata["p95_processing_ms"] ?? ""),
              p50.isFinite, p95.isFinite, p50 >= 0, p95 >= p50 else { return "N/A" }
        return String(format: "%.2f / %.2f ms · %d samples", p50, p95, count)
    }
    func queueTimes(_ label: String) -> String {
        let values = ["p95_dispatch_ms", "p95_ready_ms", "p95_backpressure_ms"].compactMap { Double(meta(label)[$0] ?? "") }
        guard values.count == 3 else { return "N/A" }
        return values.map { String(format: "%.2f", $0) }.joined(separator: " / ") + " ms"
    }
    func queueBudget(_ label: String) -> String {
        let values = meta(label)
        guard let queued = Int(values["queued"] ?? ""),
              let limit = Int(values["prefetch_limit"] ?? ""),
              let bytes = Double(values["queue_frame_estimate_bytes"] ?? ""), bytes.isFinite, bytes > 0,
              let target = Double(values["queue_surface_target_bytes"] ?? ""), target.isFinite, target > 0 else { return "N/A" }
        return String(format: "%d queued · prefetch ≤%d · %.1f MiB/frame · %.0f MiB target",
                      queued, limit, bytes / 1_048_576, target / 1_048_576)
    }
    func renderTiming(_ key: String) -> String {
        guard let value = (snapshot["render-timing"] as? [String: Any])?[key] as? NSNumber else { return "N/A" }
        return String(format: "%.2f ms", value.doubleValue)
    }
    func modelTiming(_ label: String) -> String {
        let metadata = meta(label)
        guard let gpu = Double(metadata["gpu_span_ms"] ?? ""),
              let wait = Double(metadata["cpu_wait_ms"] ?? ""),
              gpu.isFinite, wait.isFinite, gpu >= 0, wait >= 0 else { return "N/A" }
        return String(format: "%.2f / %.2f ms", gpu, wait)
    }
    func stageTimes(_ label: String) -> String {
        let metadata = meta(label)
        let values = ["input_ms", "model_call_ms", "output_ms"].compactMap { Double(metadata[$0] ?? "") }
        guard values.count == 3, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return "N/A" }
        return values.map { String(format: "%.2f", $0) }.joined(separator: " / ") + " ms"
    }
}

/// Liquid Glass card background with adaptive artwork gradient tinting and higher translucency.
struct TintedLiquidGlass: ViewModifier {
    var cornerRadius: CGFloat = 24
    var theme: MediaArtworkTheme?
    var tintOpacity: Double = 0.28
    var scrimStrength: Double = 0.72
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if opaque || contrast == .increased {
            content.background {
                shape.fill(Color(nsColor: .windowBackgroundColor))
                if let theme {
                    LinearGradient(
                        colors: theme.colors(dark: dark),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .opacity(0.85)
                    .clipShape(shape)
                }
                shape.strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
            }
        } else {
            let baseScrim = dark ? Color.black.opacity(0.20 * scrimStrength) : Color.white.opacity(0.14 * scrimStrength)
            content.background {
                shape
                    .fill(baseScrim)
                    .glassEffect(.regular, in: shape)
                    .overlay {
                        LinearGradient(
                            colors: theme?.colors(dark: dark) ?? [.clear, .clear, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .opacity(theme == nil ? 0 : (dark ? tintOpacity + 0.04 : tintOpacity))
                        .clipShape(shape)
                        .allowsHitTesting(false)
                    }
            }
        }
    }
}

struct VideoInformationHUD: View {
    @ObservedObject var model: PlayerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let alignedCardWidth: CGFloat = 316
    init(model: PlayerModel) {
        self.model = model
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.showSummaryCard {
                VideoHUDMetadataSummaryCard(model: model)
                    .frame(width: Self.alignedCardWidth, alignment: .leading)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)).combined(with: .offset(y: -6))
                    )
            }
            if model.showVideoInfo {
                VideoHUDTechnicalCard(model: model, fullMode: true)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)).combined(with: .offset(y: -6))
                    )
            }
        }
        .frame(width: Self.alignedCardWidth, alignment: .leading)
        .animation(reduceMotion ? nil : .snappy(duration: 0.26, extraBounce: 0.04), value: model.showSummaryCard)
        .animation(reduceMotion ? nil : .snappy(duration: 0.26, extraBounce: 0.04), value: model.showVideoInfo)
    }
}

/// Isolates 4 Hz telemetry observation so `VideoHUDMetadataSummaryCard` is never re-evaluated on telemetry ticks.
private struct VideoHUDTechnicalCard: View {
    @ObservedObject var model: PlayerModel
    let telemetry: PlayerTelemetryState
    let fullMode: Bool
    init(model: PlayerModel, fullMode: Bool) {
        self.model = model
        self.telemetry = model.telemetry
        self.fullMode = fullMode
    }
    var body: some View {
        let _ = telemetry.revision
        VStack(alignment: .leading, spacing: 6) {
            if model.audioOnly {
                Label("Audio", systemImage: "waveform")
                Text(model.audioCodec + " · " + model.bitrate(model.number("audio-bitrate")))
                Text(model.audioFormatDescription)
            } else {
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
                if model.isDolbyVision { Text("Dolby Vision · " + model.dolbyVisionStatus).lineLimit(3) }
            }
            Text("CPU \(model.processCPU) · Memory \(model.memoryDescription("process-memory-bytes"))")
            if !model.audioOnly { Text("Video packet bitrate · Output cadence estimated from frame timestamps").font(.caption2).foregroundStyle(.secondary) }
        }
        .font(.caption.monospacedDigit())
        .frame(maxWidth: fullMode ? .infinity : nil, alignment: .leading)
        .padding(12)
        .modifier(PlaybackGlass(cornerRadius: 22))
        .allowsHitTesting(false)
    }
}

private struct VideoHUDMetadataSummaryCard: View {
    @ObservedObject private var onlineMovies = OnlineMovieLibrary.shared
    @StateObject private var onlineArtwork = OnlineSummaryArtwork()
    @ObservedObject var model: PlayerModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var nfo: MediaNFOMetadata? = nil
    @State private var resolvedNFOURL: URL? = nil
    @State private var nfoModification: Date? = nil
    @State private var nfoContents: Data? = nil
    @State private var savingNFO = false
    @State private var coverImage: NSImage? = nil
    @State private var artworkTheme: MediaArtworkTheme? = nil
    @State private var loadedCoverPath = ""

    init(model: PlayerModel) {
        self.model = model
        let path = model.path
        if !path.isEmpty {
            let dedicatedHit = QueueMetadataCache.cachedDedicatedArtwork(path)
            let immediateCover = dedicatedHit.image ?? ThumbnailImageCache.shared.lookup(path)?.image
            let immediateTheme = immediateCover.flatMap { MediaArtworkTheme.resolve(for: path, image: $0) } ?? MediaArtworkTheme.cached(for: path)
            let cachedNFO = MediaNFOCache.shared.lookup(path)
            _coverImage = State(initialValue: immediateCover)
            _artworkTheme = State(initialValue: immediateTheme)
            _loadedCoverPath = State(initialValue: (dedicatedHit.found && dedicatedHit.image != nil) ? path : "")
            _nfo = State(initialValue: cachedNFO.found ? cachedNFO.value : nil)
        }
    }

    private var canEditLocalNFO: Bool {
        model.path.hasPrefix("/")
    }

    private func splitList(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: "/,，、·;；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var displayMetadata: MediaNFOMetadata {
        CurrentMediaMetadataResolver.resolve(nfo: nfo,
            raw: model.snapshot["metadata"] as? [String: String] ?? [:],
            fallbackTitle: model.path.isEmpty ? "" : model.title, online: onlineMovies.movie(for: model.path))
    }

    private var metadataDuration: String {
        if let minutes = displayMetadata.runtimeMinutes { return String(localized: "\(minutes) min") }
        guard model.duration.isFinite, model.duration > 0 else { return "N/A" }
        let seconds = Int(min(model.duration, Double(Int32.max)))
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    private func toggleExpanded() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.26, extraBounce: 0.04)) {
            isExpanded.toggle()
        }
    }

    @ViewBuilder
    private func searchableLink(_ text: String) -> some View {
        Button {
            model.searchInCurrentFolder(text)
        } label: {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private func resolvedCoverSize(for image: NSImage, expanded: Bool) -> CGSize {
        let w = max(1, image.size.width)
        let h = max(1, image.size.height)
        let isLandscape = (w / h) > 1.05
        let maxW: CGFloat = expanded ? (isLandscape ? 116 : 64) : (isLandscape ? 176 : 94)
        let maxH: CGFloat = expanded ? (isLandscape ? 76 : 86) : (isLandscape ? 116 : 128)
        let scale = min(maxW / w, maxH / h)
        return CGSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))
    }

    var body: some View {
        let info = displayMetadata
        let dark = colorScheme == .dark
        let onlineImage = onlineArtwork.image(for: model.path, url: onlineMovies.movie(for: model.path)?.posterURL)
        let awaitingOnline = onlineArtwork.awaitingImage(path: model.path, url: onlineMovies.movie(for: model.path)?.posterURL)
        let coverImage = onlineImage ?? (awaitingOnline ? nil : self.coverImage)
        let artworkTheme = onlineImage != nil ? onlineArtwork.theme(for: model.path, url: onlineMovies.movie(for: model.path)?.posterURL) : (awaitingOnline ? nil : self.artworkTheme)
        let chip = artworkTheme?.chip(dark: dark) ?? Color.primary
        let titleText = info.title.isEmpty ? model.title : info.title
        let collapsedDirectors = info.directors.joined(separator: " / ")

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                if awaitingOnline {
                    ProgressView().frame(width: 60, height: 84)
                } else if let coverImage {
                    let coverSize = resolvedCoverSize(for: coverImage, expanded: isExpanded)
                    Image(nsImage: coverImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: coverSize.width, height: coverSize.height)
                        .fixedSize()
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(.primary.opacity(0.14), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
                        .transition(.opacity)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(titleText)
                        .font(.system(size: isExpanded ? 15 : 13, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if !collapsedDirectors.isEmpty {
                        Text(collapsedDirectors)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? 1 : 2)
                            .multilineTextAlignment(.leading)
                    }

                    if !info.year.isEmpty {
                        Text(info.year)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .padding(2)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleExpanded)

            if isExpanded {
                Divider().opacity(0.35)
                expandedDetails(info: info, dark: dark, chip: chip)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
                    )
            }
        }
        .labeledContentStyle(InformationValueStyle())
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(TintedLiquidGlass(cornerRadius: 22, theme: artworkTheme, tintOpacity: 0.28, scrimStrength: 0.65))
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: coverImage != nil)
        .animation(reduceMotion ? nil : .smooth(duration: 0.30), value: artworkTheme)
        .task(id: "online-hud|\(model.path)|\(onlineMovies.movie(for: model.path)?.posterURL?.absoluteString ?? "")") {
            await onlineArtwork.load(path: model.path, url: onlineMovies.movie(for: model.path)?.posterURL)
        }
        .task(id: "hud-cover|\(model.path)|\(model.path.hasPrefix("/") ? false : model.remoteMetadataDeferred)") {
            await loadCoverAndTheme(for: model.path)
        }
        .task(id: "hud-nfo|\(model.path)") {
            isExpanded = false
            await loadNFO(for: model.path)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaCoverDidChange)) { note in
            handleCoverDidChange(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaNFODidChange)) { note in
            handleNFODidChange(note)
        }
    }

    @ViewBuilder
    private func expandedDetails(info: MediaNFOMetadata, dark: Bool, chip: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if info.rating != nil || canEditLocalNFO {
                NFOStarRatingPicker(ratingOutOfTen: info.rating, editable: canEditLocalNFO) { newRating in
                    updateStarRatingDirectly(newRating)
                }
            }

            if !info.originalTitle.isEmpty && info.originalTitle != info.title {
                Text(info.originalTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Label(metadataDuration, systemImage: "clock")
                    .monospacedDigit()
                Spacer()
                if !info.mpaa.isEmpty {
                    Text(info.mpaa)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(.secondary.opacity(0.45), lineWidth: 0.5)
                        }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleExpanded)

            if !info.directors.isEmpty {
                LabeledContent("Director") {
                    MetadataFlowLayout(alignment: .trailing, spacing: 5, lineSpacing: 3) {
                        ForEach(Array(info.directors.enumerated()), id: \.offset) { index, director in
                            HStack(spacing: 3) {
                                searchableLink(director)
                                if index < info.directors.count - 1 {
                                    Text("/").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                .font(.caption)
            }

            if !info.actors.isEmpty {
                let castList = Array(info.actors.prefix(8))
                LabeledContent(model.audioOnly ? "Artist" : "Cast") {
                    MetadataFlowLayout(alignment: .trailing, spacing: 5, lineSpacing: 3) {
                        ForEach(Array(castList.enumerated()), id: \.offset) { index, actor in
                            HStack(spacing: 3) {
                                searchableLink(actor)
                                if index < castList.count - 1 {
                                    Text("·").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                .font(.caption)
            }

            if !info.studio.isEmpty {
                LabeledContent("Studio") {
                    searchableLink(info.studio)
                }
                .font(.caption)
            }

            if !info.genres.isEmpty || !info.tags.isEmpty {
                MetadataFlowLayout(spacing: 5, lineSpacing: 5) {
                    ForEach(Array((info.genres + info.tags).prefix(10).enumerated()), id: \.offset) { _, tag in
                        Button {
                            model.searchInCurrentFolder(tag)
                        } label: {
                            Text(tag)
                                .font(.caption2)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(chip.opacity(dark ? 0.25 : 0.15), in: Capsule())
                                .overlay(
                                    Capsule()
                                        .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !info.plot.isEmpty {
                Text(info.plot)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggleExpanded)
            }
        }
    }

    private func updateStarRatingDirectly(_ newRating: Double?) {
        guard canEditLocalNFO && !savingNFO else { return }
        var updated = displayMetadata
        if updated.title.isEmpty {
            updated.title = URL(fileURLWithPath: model.path).deletingPathExtension().lastPathComponent
        }
        updated.rating = newRating
        let path = model.path
        let target = resolvedNFOURL
        let revision = nfoModification
        let contents = nfoContents
        let expectsMissing = target == nil
        savingNFO = true
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
            nfo = updated
        }
        MediaNFOCache.shared.store(path, value: updated)
        Task {
            defer { savingNFO = false }
            guard let savedURL = try? await MediaNFOCache.shared.saveLocalMetadata(
                updated,
                forMediaPath: path,
                preferredNFOURL: target,
                expectedModification: revision,
                expectedContents: contents,
                expectsMissing: expectsMissing
            ) else { return }
            guard model.path == path else { return }
            resolvedNFOURL = savedURL
            let freshContents = await Task.detached(priority: .utility) { MediaNFOCache.readLocalNFO(savedURL) }.value
            guard model.path == path else { return }
            nfoContents = freshContents
            if let freshContents, let fresh = NFOParser.parse(freshContents) {
                nfo = fresh
                MediaNFOCache.shared.store(path, value: fresh)
            }
            nfoModification = (try? savedURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? ((try? FileManager.default.attributesOfItem(atPath: savedURL.path)[.modificationDate]) as? Date)
        }
    }

    private func loadCoverAndTheme(for path: String) async {
        guard !path.isEmpty else {
            loadedCoverPath = ""
            coverImage = nil
            artworkTheme = nil
            return
        }
        if loadedCoverPath == path, coverImage != nil { return }
        var hasImmediateForPath = false
        if loadedCoverPath != path {
            loadedCoverPath = path
            let dedicatedHit = QueueMetadataCache.cachedDedicatedArtwork(path)
            if let immediateImage = dedicatedHit.image ?? ThumbnailImageCache.shared.lookup(path)?.image {
                hasImmediateForPath = true
                coverImage = immediateImage
                artworkTheme = MediaArtworkTheme.resolve(for: path, image: immediateImage)
                if dedicatedHit.found && dedicatedHit.image != nil {
                    return
                }
            } else if let cachedTheme = MediaArtworkTheme.cached(for: path) {
                artworkTheme = cachedTheme
            }
        }

        if path.hasPrefix("/") {
            let posterAndTheme: (NSImage, MediaArtworkTheme?)? = await Task.detached(priority: .userInitiated) {
                guard let poster = QueueMetadataCache.detailArtwork(path) else { return nil }
                let theme = MediaArtworkTheme.resolve(for: path, image: poster)
                return (poster, theme)
            }.value
            guard !Task.isCancelled, model.path == path else { return }
            if let (poster, theme) = posterAndTheme {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                    coverImage = poster
                    artworkTheme = theme
                }
                return
            }
            if hasImmediateForPath { return }
            let metadata = await QueueMetadataCache.shared.read(path, cover: true, priority: .detail)
            guard !Task.isCancelled, model.path == path else { return }
            guard let data = metadata.cover else {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.20)) {
                    coverImage = nil
                    artworkTheme = nil
                }
                return
            }
            let decodedAndTheme: (NSImage, MediaArtworkTheme?)? = await Task.detached(priority: .userInitiated) {
                guard let image = ThumbnailImageCache.decodeImage(from: data, maxPixels: 900) else { return nil }
                let theme = MediaArtworkTheme.resolve(for: path, image: image)
                return (image, theme)
            }.value
            guard !Task.isCancelled, model.path == path, let (image, theme) = decodedAndTheme else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                coverImage = image
                artworkTheme = theme
            }
        } else if let entry = model.remoteEntries[path] {
            let metadata = await model.remoteMetadata.read(entry, cover: true,
                allowLoad: !model.remoteMetadataDeferred, priorityRevision: model.metadataPriorityRevision)
            guard !Task.isCancelled, model.path == path else { return }
            guard let data = metadata.cover else {
                if !hasImmediateForPath {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.20)) {
                        coverImage = nil
                        artworkTheme = nil
                    }
                }
                return
            }
            let decodedAndTheme: (NSImage, MediaArtworkTheme?)? = await Task.detached(priority: .userInitiated) {
                guard let image = ThumbnailImageCache.decodeImage(from: data, maxPixels: 900) else { return nil }
                let theme = MediaArtworkTheme.resolve(for: path, image: image)
                return (image, theme)
            }.value
            guard !Task.isCancelled, model.path == path, let (image, theme) = decodedAndTheme else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                coverImage = image
                artworkTheme = theme
            }
        }
    }

    private func loadNFO(for path: String) async {
        guard !path.isEmpty else {
            nfo = nil
            resolvedNFOURL = nil
            nfoModification = nil
            nfoContents = nil
            return
        }
        let cached = MediaNFOCache.shared.lookup(path)
        if cached.found, nfo == nil {
            nfo = cached.value
        }
        if path.hasPrefix("/") {
            let discovered = await MediaNFOCache.shared.localSnapshot(for: path)
            guard !Task.isCancelled, model.path == path else { return }
            let primaryMeta = discovered.metadata
            MediaNFOCache.shared.store(path, value: primaryMeta)
            nfo = primaryMeta
            resolvedNFOURL = discovered.nfoURL
            nfoModification = discovered.modification
            nfoContents = discovered.contents
        } else if let remote = model.remoteEntries[path], case .webDAV(let creds) = remote.origin {
            resolvedNFOURL = nil
            nfoModification = nil
            nfoContents = nil
            let nfoCandidate = remote.item.url.deletingPathExtension().appendingPathExtension("nfo")
            let loaded = await MediaNFOCache.shared.metadata(
                for: remote.item.id,
                localMediaURL: nil,
                nfoURL: nfoCandidate,
                isFolder: false,
                credentials: creds
            )
            guard !Task.isCancelled, model.path == path else { return }
            MediaNFOCache.shared.store(path, value: loaded)
            nfo = loaded
        } else {
            nfo = nil
            resolvedNFOURL = nil
            nfoModification = nil
            nfoContents = nil
        }
    }

    private func handleCoverDidChange(_ note: Notification) {
        guard let changedPath = note.object as? String,
              !model.path.isEmpty,
              changedPath == model.path || URL(fileURLWithPath: changedPath).standardizedFileURL == URL(fileURLWithPath: model.path).standardizedFileURL else { return }
        let path = model.path
        Task { await onlineArtwork.load(path: path, url: onlineMovies.movie(for: path)?.posterURL) }
        let updatedCover = QueueMetadataCache.cachedDedicatedArtwork(path).image ?? ThumbnailImageCache.shared.lookup(path)?.image
        let updatedTheme = updatedCover.flatMap { MediaArtworkTheme.resolve(for: path, image: $0) } ?? MediaArtworkTheme.cached(for: path)
        loadedCoverPath = path
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
            if let updatedCover { coverImage = updatedCover }
            if let updatedTheme { artworkTheme = updatedTheme }
        }
    }

    private func handleNFODidChange(_ note: Notification) {
        guard let changedPath = note.object as? String,
              !model.path.isEmpty,
              changedPath == model.path || URL(fileURLWithPath: changedPath).standardizedFileURL == URL(fileURLWithPath: model.path).standardizedFileURL else { return }
        Task {
            await loadNFO(for: model.path)
        }
    }
}

private struct NFOStarRatingPicker: View {
    let ratingOutOfTen: Double?
    let editable: Bool
    var onSelectRating: (Double?) -> Void
    @State private var hoverStar: Double? = nil
    private static let totalStripWidth: CGFloat = 5 * 22 + 4 * 3

    private var activeStarsOutOfFive: Double {
        if let hoverStar { return hoverStar }
        guard let ratingOutOfTen, ratingOutOfTen > 0 else { return 0 }
        return min(5.0, max(0.0, ratingOutOfTen / 2.0))
    }

    private func pointsForX(_ x: CGFloat) -> Int {
        let clamped = min(max(0, x), Self.totalStripWidth - 0.01)
        let slot = Int((clamped / Self.totalStripWidth) * 10.0)
        return min(10, max(1, slot + 1))
    }

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 3) {
                ForEach(1...5, id: \.self) { star in
                    let fillLevel = activeStarsOutOfFive - Double(star - 1)
                    let symbol: String = {
                        if fillLevel >= 0.75 { return "star.fill" }
                        if fillLevel >= 0.25 { return "star.leadinghalf.filled" }
                        return "star"
                    }()
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(fillLevel >= 0.25 ? Color.yellow : Color.secondary.opacity(0.45))
                        .frame(width: 22, height: 24)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard editable else { return }
                switch phase {
                case .active(let location):
                    let nextHover = Double(pointsForX(location.x)) * 0.5
                    if hoverStar != nextHover { hoverStar = nextHover }
                case .ended:
                    if hoverStar != nil { hoverStar = nil }
                }
            }
            .onTapGesture { location in
                guard editable else { return }
                onSelectRating(Double(pointsForX(location.x)))
            }

            if let ratingOutOfTen, ratingOutOfTen > 0 {
                Text(String(format: "%.1f / 10", ratingOutOfTen))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                if editable {
                    Button {
                        onSelectRating(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("Unrated")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct InformationValueStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.label.foregroundStyle(.primary)
            Spacer(minLength: 4)
            configuration.content.foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MetadataFlowLayout: Layout {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    struct RowItem {
        let index: Int
        let size: CGSize
    }

    struct Row {
        var items: [RowItem] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    struct CacheData {
        var lastMaxWidth: CGFloat = -1
        var subviewCount: Int = -1
        var rows: [Row] = []
        var maxRowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> CacheData {
        CacheData()
    }

    private func resolveLayout(maxWidth: CGFloat, subviews: Subviews, cache: inout CacheData) {
        let normalizedWidth = maxWidth.isFinite ? maxWidth.rounded(.toNearestOrAwayFromZero) : .infinity
        if cache.subviewCount == subviews.count && cache.lastMaxWidth == normalizedWidth {
            return
        }
        var rows: [Row] = []
        var currentRow = Row()

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: maxWidth.isFinite ? maxWidth : nil, height: nil))
            let nextWidth = currentRow.items.isEmpty ? size.width : currentRow.width + spacing + size.width
            if !currentRow.items.isEmpty && nextWidth > maxWidth {
                rows.append(currentRow)
                currentRow = Row(items: [RowItem(index: index, size: size)], width: size.width, height: size.height)
            } else {
                currentRow.items.append(RowItem(index: index, size: size))
                currentRow.width = nextWidth
                currentRow.height = max(currentRow.height, size.height)
            }
        }
        if !currentRow.items.isEmpty {
            rows.append(currentRow)
        }

        let maxRowWidth = rows.reduce(CGFloat(0)) { max($0, $1.width) }
        let totalHeight = rows.enumerated().reduce(CGFloat(0)) { partial, pair in
            partial + pair.element.height + (pair.offset > 0 ? lineSpacing : 0)
        }
        cache.lastMaxWidth = normalizedWidth
        cache.subviewCount = subviews.count
        cache.rows = rows
        cache.maxRowWidth = maxRowWidth
        cache.totalHeight = totalHeight
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        resolveLayout(maxWidth: maxWidth, subviews: subviews, cache: &cache)
        let fittedWidth = maxWidth.isFinite ? min(maxWidth, cache.maxRowWidth) : cache.maxRowWidth
        return CGSize(width: fittedWidth, height: cache.totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) {
        resolveLayout(maxWidth: bounds.width, subviews: subviews, cache: &cache)
        var currentY = bounds.minY

        for row in cache.rows {
            let startX: CGFloat
            switch alignment {
            case .trailing:
                startX = bounds.maxX - row.width
            case .center:
                startX = bounds.minX + (bounds.width - row.width) * 0.5
            default:
                startX = bounds.minX
            }

            var currentX = startX
            for item in row.items {
                guard item.index < subviews.count else { continue }
                subviews[item.index].place(
                    at: CGPoint(x: currentX, y: currentY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                currentX += item.size.width + spacing
            }
            currentY += row.height + lineSpacing
        }
    }
}

extension PlayerModel {
    func searchInCurrentFolder(_ rawTerm: String) {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        if miniPlayer {
            windowModes.restore(self) { [weak self] in
                self?.searchInCurrentFolder(term)
            }
            return
        }
        let folderURL: URL? = path.hasPrefix("/") ? URL(fileURLWithPath: path).deletingLastPathComponent() : nil
        withAnimation(.spring(duration: 0.34, bounce: 0.14)) {
            sidebarTab = "queue"
            quickSettings = false
            queuePopover = false
            inspector = true
        }
        NotificationCenter.default.post(
            name: .browserSearchCurrentFolder,
            object: nil,
            userInfo: ["query": term, "folderURL": folderURL as Any]
        )
    }

    func canRevealInFileBrowser(path targetPath: String? = nil) -> Bool {
        let resolved = targetPath ?? path
        guard !resolved.isEmpty else { return false }
        if resolved.hasPrefix("/") { return true }
        if let remote = remoteEntries[resolved], case .webDAV = remote.origin {
            return true
        }
        return false
    }

    func revealInFileBrowser(path targetPath: String? = nil) {
        let resolved = targetPath ?? path
        guard canRevealInFileBrowser(path: resolved) else { return }
        if miniPlayer {
            windowModes.restore(self) { [weak self] in
                self?.revealInFileBrowser(path: resolved)
            }
            return
        }
        var info: [String: Any] = [:]
        if resolved.hasPrefix("/") {
            let fileURL = URL(fileURLWithPath: resolved).standardizedFileURL
            info["fileURL"] = fileURL
            info["folderURL"] = fileURL.deletingLastPathComponent()
            info["entryID"] = fileURL.path
        } else if let remote = remoteEntries[resolved], case .webDAV(let credentials) = remote.origin {
            var folderURL = remote.item.url.deletingLastPathComponent()
            if !folderURL.path.hasSuffix("/") { folderURL.appendPathComponent("") }
            info["davItem"] = remote.item
            info["davCredentials"] = credentials
            info["davFolderURL"] = folderURL
            info["entryID"] = remote.item.id
        } else {
            return
        }
        withAnimation(.spring(duration: 0.34, bounce: 0.14)) {
            sidebarTab = "queue"
            quickSettings = false
            queuePopover = false
            inspector = true
        }
        NotificationCenter.default.post(
            name: .browserRevealMediaItem,
            object: nil,
            userInfo: info
        )
    }
}

struct InformationSectionCard<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content
    init(_ title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) { content() }
                .font(.callout)
                .labeledContentStyle(InformationValueStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.quaternary.opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
    }
}

struct MediaArtworkTheme: Equatable, Sendable {
    struct ThemeStop: Equatable, Sendable {
        let hue: CGFloat
        let saturation: CGFloat
        let brightness: CGFloat
    }

    let stops: [ThemeStop]
    let darkColors: [Color]
    let lightColors: [Color]
    let darkChip: Color
    let lightChip: Color

    init(stops: [ThemeStop]) {
        self.stops = stops
        self.darkColors = stops.enumerated().map { i, stop in
            let baseB = 0.34 + Double(i) * 0.045
            let adaptiveOffset = (Double(stop.brightness) - 0.55) * 0.06
            let targetBrightness = min(0.48, max(0.31, baseB + adaptiveOffset))
            let targetSaturation = min(0.86, Double(stop.saturation) * 1.02)
            return Color(hue: Double(stop.hue), saturation: targetSaturation, brightness: targetBrightness)
        }
        self.lightColors = stops.enumerated().map { i, stop in
            let baseB = 0.85 - Double(i) * 0.032
            let adaptiveOffset = (Double(stop.brightness) - 0.60) * 0.04
            let targetBrightness = min(0.88, max(0.75, baseB + adaptiveOffset))
            let targetSaturation = min(0.64, Double(stop.saturation) * 0.88)
            return Color(hue: Double(stop.hue), saturation: targetSaturation, brightness: targetBrightness)
        }
        if let primary = stops.first {
            let chipSat = min(0.88, Double(primary.saturation) * 1.05)
            self.darkChip = Color(hue: Double(primary.hue), saturation: chipSat, brightness: 0.78)
            self.lightChip = Color(hue: Double(primary.hue), saturation: chipSat, brightness: 0.46)
        } else {
            self.darkChip = Color.primary
            self.lightChip = Color.primary
        }
    }

    private static let cacheLock = NSLock()
    private struct CachedTheme {
        weak var image: NSImage?
        let theme: MediaArtworkTheme
    }
    private nonisolated(unsafe) static var pathCache: [String: CachedTheme] = [:]
    private nonisolated(unsafe) static var pathOrder: [String] = []
    private nonisolated(unsafe) static var imageCache: [ObjectIdentifier: CachedTheme] = [:]
    private nonisolated(unsafe) static var imageOrder: [ObjectIdentifier] = []

    nonisolated static func cached(for path: String) -> Self? {
        guard !path.isEmpty else { return nil }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return pathCache[path]?.theme
    }

    @discardableResult
    nonisolated static func update(for path: String, image: NSImage) -> Self? {
        cacheLock.lock()
        if !path.isEmpty {
            pathCache.removeValue(forKey: path)
            pathOrder.removeAll { $0 == path }
        }
        cacheLock.unlock()
        return resolve(for: path, image: image)
    }

    nonisolated static func resolve(for path: String, image: NSImage) -> Self? {
        let imgKey = ObjectIdentifier(image)
        cacheLock.lock()
        if !path.isEmpty, let hit = pathCache[path], hit.image === image {
            cacheLock.unlock()
            return hit.theme
        }
        if let hit = imageCache[imgKey], hit.image === image {
            if !path.isEmpty {
                pathCache[path] = hit
                pathOrder.removeAll { $0 == path }
                pathOrder.append(path)
                while pathOrder.count > 128 {
                    pathCache.removeValue(forKey: pathOrder.removeFirst())
                }
            }
            cacheLock.unlock()
            return hit.theme
        }
        cacheLock.unlock()

        guard let computed = extract(image) else { return nil }
        cacheLock.lock()
        let entry = CachedTheme(image: image, theme: computed)
        imageCache[imgKey] = entry
        imageOrder.removeAll { $0 == imgKey }
        imageOrder.append(imgKey)
        while imageOrder.count > 128 {
            let oldest = imageOrder.removeFirst()
            imageCache.removeValue(forKey: oldest)
        }
        if !path.isEmpty {
            pathCache[path] = entry
            pathOrder.removeAll { $0 == path }
            pathOrder.append(path)
            while pathOrder.count > 128 {
                let oldest = pathOrder.removeFirst()
                pathCache.removeValue(forKey: oldest)
            }
        }
        cacheLock.unlock()
        return computed
    }

    private static func hueDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let d = abs(a - b)
        return min(d, 1 - d)
    }

    private static func wrapHue(_ h: CGFloat) -> CGFloat {
        let r = h.truncatingRemainder(dividingBy: 1)
        return r < 0 ? r + 1 : r
    }

    nonisolated static func extract(_ image: NSImage) -> Self? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width > 0, cg.height > 0 else { return nil }

        let aspect = CGFloat(cg.width) / CGFloat(cg.height)
        let isWideSpreadCandidate = aspect >= 1.28
        let gridW = isWideSpreadCandidate ? 64 : 42
        let gridH = 42

        var pixels = [UInt8](repeating: 0, count: gridW * gridH * 4)
        guard let context = CGContext(
            data: &pixels,
            width: gridW,
            height: gridH,
            bitsPerComponent: 8,
            bytesPerRow: gridW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: gridW, height: gridH))

        struct Sample {
            let h: CGFloat
            let s: CGFloat
            let v: CGFloat
            let luma: CGFloat
            let alpha: UInt8
        }

        var samples = [Sample]()
        samples.reserveCapacity(gridW * gridH)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = pixels[i + 3]
            let divisor = CGFloat(max(1, Int(alpha)))
            let r = min(1, max(0, CGFloat(pixels[i]) / divisor))
            let g = min(1, max(0, CGFloat(pixels[i + 1]) / divisor))
            let b = min(1, max(0, CGFloat(pixels[i + 2]) / divisor))
            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let delta = maxC - minC
            let sat: CGFloat = maxC > 0.001 ? (delta / maxC) : 0
            var hue: CGFloat = 0
            if delta > 0.0001 {
                if maxC == r {
                    hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
                } else if maxC == g {
                    hue = ((b - r) / delta) + 2
                } else {
                    hue = ((r - g) / delta) + 4
                }
                hue /= 6
                if hue < 0 { hue += 1 }
            }
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            samples.append(Sample(h: hue, s: sat, v: maxC, luma: luma, alpha: alpha))
        }

        // Detect horizontal CD / DVD / BD full-spread jackets (front + spine + back)
        // and restrict sampling to the front cover half when a central division is present.
        var activeXRange = 0..<gridW
        if isWideSpreadCandidate {
            let midStart = gridW * 44 / 100
            let midEnd = gridW * 56 / 100
            var bestSeamStrength: CGFloat = 0
            for x in midStart...midEnd {
                var verticalContinuity: CGFloat = 0
                var horizontalStep: CGFloat = 0
                for y in 2..<(gridH - 2) {
                    let cur = samples[y * gridW + x]
                    let below = samples[(y + 1) * gridW + x]
                    let left = samples[y * gridW + max(0, x - 2)]
                    let right = samples[y * gridW + min(gridW - 1, x + 2)]
                    let vDiff = abs(cur.luma - below.luma) + hueDistance(cur.h, below.h) * min(cur.s, below.s)
                    let hDiff = abs(left.luma - right.luma) + hueDistance(left.h, right.h) * max(left.s, right.s)
                    verticalContinuity += max(0, 1 - vDiff * 3.2)
                    horizontalStep += min(1, hDiff * 2.2)
                }
                let count = CGFloat(gridH - 4)
                let seamScore = (verticalContinuity / count) * (0.45 + 0.55 * (horizontalStep / count))
                bestSeamStrength = max(bestSeamStrength, seamScore)
            }

            func panelBackCoverPenalty(xRange: Range<Int>) -> (penalty: CGFloat, salience: CGFloat) {
                var bins = [Int: Int]()
                var noisyTransitions: CGFloat = 0
                var barcodeScore: CGFloat = 0
                var chromaticSalience: CGFloat = 0
                var total = 0

                for y in 1..<(gridH - 1) {
                    var rowAlternations = 0
                    for x in xRange {
                        let idx = y * gridW + x
                        let s = samples[idx]
                        guard s.alpha > 128 else { continue }
                        total += 1
                        let hBin = s.s < 0.10 ? 12 : min(11, Int(s.h * 12))
                        let key = hBin * 16 + min(3, Int(s.s * 4)) * 4 + min(3, Int(s.v * 4))
                        bins[key, default: 0] += 1

                        if x + 1 < xRange.upperBound {
                            let next = samples[y * gridW + x + 1]
                            let lumaJump = abs(s.luma - next.luma)
                            let hueJump = hueDistance(s.h, next.h) * max(s.s, next.s)
                            if lumaJump > 0.22 || hueJump > 0.18 {
                                noisyTransitions += 1
                            }
                            // Barcode pattern: lower half, low saturation, sharp horizontal black/white jumps, vertical consistency
                            if y >= gridH / 2, s.s < 0.16, next.s < 0.16, lumaJump > 0.26 {
                                let below = samples[(y + 1) * gridW + x]
                                if abs(s.luma - below.luma) < 0.12 {
                                    rowAlternations += 1
                                }
                            }
                        }

                        if s.v >= 0.28, s.s >= 0.15, s.s * s.v >= 0.11 {
                            chromaticSalience += pow(s.s, 0.85) * pow(s.v, 0.75)
                        }
                    }
                    if rowAlternations >= 5 {
                        barcodeScore += CGFloat(rowAlternations)
                    }
                }

                let denom = CGFloat(max(1, total))
                let maxRectUniformity = CGFloat(bins.values.max() ?? 0) / denom
                let fragmentation = noisyTransitions / denom
                let normalizedBarcode = min(1, barcodeScore / (denom * 0.18))
                // Back covers have either a large flat solid area, high text/thumbnail fragmentation, or a barcode
                let flatPenalty = max(0, maxRectUniformity - 0.48) * 1.45
                let noisePenalty = max(0, fragmentation - 0.22) * 1.15
                let totalPenalty = flatPenalty + noisePenalty + normalizedBarcode * 0.65
                return (totalPenalty, chromaticSalience / denom)
            }

            let leftRange = 0..<(gridW * 47 / 100)
            let rightRange = (gridW * 53 / 100)..<gridW
            let leftEval = panelBackCoverPenalty(xRange: leftRange)
            let rightEval = panelBackCoverPenalty(xRange: rightRange)
            let panelAsymmetry = abs(leftEval.penalty - rightEval.penalty) + abs(leftEval.salience - rightEval.salience)

            if bestSeamStrength >= 0.36 || aspect >= 1.38 || panelAsymmetry >= 0.14 {
                // Standard DVD/BD/CD jacket spreads place the front cover on the right half;
                // choose the side with higher chromatic salience and lower back-cover penalty.
                let leftFrontScore = leftEval.salience - leftEval.penalty
                let rightFrontScore = rightEval.salience - rightEval.penalty + 0.06
                activeXRange = rightFrontScore >= leftFrontScore ? rightRange : leftRange
            }
        }

        let panelMinX = CGFloat(activeXRange.lowerBound)
        let panelSpanX = CGFloat(max(1, activeXRange.count - 1))
        let panelPixelCount = CGFloat(max(1, activeXRange.count * gridH))

        func isSalientChromatic(_ s: Sample) -> Bool {
            guard s.alpha > 128 else { return false }
            // Exclude dark hair / deep shadows (low V / low luma) even if HSV saturation is noisy
            if s.v < 0.28 || (s.luma < 0.13 && s.v < 0.50) { return false }
            if s.v < 0.38 && (s.s < 0.38 || s.s * s.v < 0.16) { return false }
            // Exclude white / light-gray backgrounds while preserving pastel pink / rose clothes
            if s.s < 0.13 || (s.v > 0.94 && s.s < 0.16) { return false }
            return s.s * s.v >= 0.105
        }

        struct CandidateCluster {
            let score: CGFloat
            let area: CGFloat
            let hue: CGFloat
            let saturation: CGFloat
            let brightness: CGFloat
        }

        var visited = Set<Int>()
        var clusters: [CandidateCluster] = []

        for y in 0..<gridH {
            for x in activeXRange {
                let origin = y * gridW + x
                let seed = samples[origin]
                guard !visited.contains(origin), isSalientChromatic(seed) else { continue }

                var pending = [origin]
                var region: [Int] = []
                visited.insert(origin)

                while let i = pending.popLast() {
                    region.append(i)
                    let cx = i % gridW, cy = i / gridW
                    for (nx, ny) in [(cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1)]
                    where activeXRange.contains(nx) && ny >= 0 && ny < gridH {
                        let n = ny * gridW + nx
                        let sample = samples[n]
                        guard !visited.contains(n), isSalientChromatic(sample),
                              hueDistance(sample.h, seed.h) < 0.085 else { continue }
                        visited.insert(n)
                        pending.append(n)
                    }
                }

                // Allow smaller salient features (like red hair or a vivid accessory, >= 5 pixels on 42x42)
                guard region.count >= 5 else { continue }

                var sine: CGFloat = 0, cosine: CGFloat = 0
                var weightedSatSum: CGFloat = 0, weightedValSum: CGFloat = 0, chromaWeightSum: CGFloat = 0
                var centralitySum: CGFloat = 0
                var regionSats: [CGFloat] = []
                regionSats.reserveCapacity(region.count)

                for i in region {
                    let s = samples[i]
                    let chromaW = max(0.05, pow(s.s, 1.45) * pow(s.v, 0.85))
                    sine += sin(s.h * 2 * .pi) * chromaW
                    cosine += cos(s.h * 2 * .pi) * chromaW
                    weightedSatSum += s.s * chromaW
                    weightedValSum += s.v * chromaW
                    chromaWeightSum += chromaW
                    regionSats.append(s.s)
                    let normX = (CGFloat(i % gridW) - panelMinX) / panelSpanX - 0.5
                    let normY = CGFloat(i / gridW) / CGFloat(gridH - 1) - 0.5
                    centralitySum += max(0, 1 - (normX * normX + normY * normY) * 2.1)
                }

                regionSats.sort(by: >)
                let topCount = max(1, regionSats.count / 4)
                let topQuartileSat = regionSats.prefix(topCount).reduce(CGFloat(0), +) / CGFloat(topCount)
                let count = CGFloat(region.count)
                let area = count / panelPixelCount
                let chromaMeanSat = weightedSatSum / max(0.0001, chromaWeightSum)
                // Preserve the vivid core of the region rather than letting soft edges/folds dilute it
                let coreSat = min(1.0, chromaMeanSat * 0.42 + topQuartileSat * 0.58)
                let meanVal = weightedValSum / max(0.0001, chromaWeightSum)
                let centrality = centralitySum / count
                let hue = wrapHue(atan2(sine, cosine) / (2 * .pi))

                // Perceptual salience:
                // 1. De-weight muted skin-tone / beige regions (hue 0.03...0.11 with moderate-low saturation)
                //    so vivid clothing, hair, or colorful accents win over skin/background.
                // 2. Strongly reward high-chroma core saturation while keeping a dedicated boost for
                //    bright pink/rose/magenta/cyan subject colors.
                let clarityBoost: CGFloat = meanVal >= 0.42 ? pow(meanVal, 0.65) : pow(meanVal / 0.42, 2.3) * 0.52
                let highSatBonus: CGFloat = 1.0 + max(0, coreSat - 0.42) * 1.15
                let vividness = pow(coreSat, 1.32) * highSatBonus * clarityBoost
                let isMutedSkinOrBeige = (hue >= 0.028 && hue <= 0.115) && coreSat < 0.48 && meanVal > 0.42
                let isVividPinkOrRed = (hue >= 0.80 || hue <= 0.026) && meanVal >= 0.46 && coreSat >= 0.18
                let hueSalienceFactor: CGFloat = isMutedSkinOrBeige ? 0.54 : (isVividPinkOrRed ? 1.34 : 1.0)
                let largeBlockBoost: CGFloat = (area >= 0.12 && coreSat >= 0.48) ? 1.38 : 1.0
                let spatialWeight = pow(area, 0.40) * (0.56 + 0.54 * centrality) * largeBlockBoost
                let score = spatialWeight * vividness * hueSalienceFactor

                clusters.append(CandidateCluster(
                    score: score,
                    area: area,
                    hue: hue,
                    saturation: coreSat,
                    brightness: meanVal
                ))
            }
        }

        // Merge fragmented regions of similar hue (e.g., hair strands or clothing separated by folds),
        // retaining the more vivid saturation of the dominant fragment.
        if !clusters.isEmpty {
            var merged: [CandidateCluster] = []
            for cluster in clusters.sorted(by: { $0.score > $1.score }) {
                if let idx = merged.firstIndex(where: { hueDistance($0.hue, cluster.hue) < 0.065 }) {
                    let existing = merged[idx]
                    let totalArea = existing.area + cluster.area
                    let w1 = existing.score
                    let w2 = cluster.score
                    let wSum = max(0.0001, w1 + w2)
                    let s1 = sin(existing.hue * 2 * .pi) * w1 + sin(cluster.hue * 2 * .pi) * w2
                    let c1 = cos(existing.hue * 2 * .pi) * w1 + cos(cluster.hue * 2 * .pi) * w2
                    let combinedHue = wrapHue(atan2(s1, c1) / (2 * .pi))
                    let bestSat = max(existing.saturation, cluster.saturation)
                    let blendedSat = (existing.saturation * w1 + cluster.saturation * w2) / wSum
                    merged[idx] = CandidateCluster(
                        score: existing.score + cluster.score * 0.78,
                        area: totalArea,
                        hue: combinedHue,
                        saturation: bestSat * 0.65 + blendedSat * 0.35,
                        brightness: (existing.brightness * w1 + cluster.brightness * w2) / wSum
                    )
                } else {
                    merged.append(cluster)
                }
            }
            clusters = merged.sorted(by: { $0.score > $1.score })
        }

        func boostVibrancy(_ rawSat: CGFloat) -> CGFloat {
            // Lift moderate & vivid colors with a nonlinear curve so they remain vibrant
            // even after blending over the translucent glass material.
            min(0.88, max(0.36, pow(rawSat, 0.66) * 1.08))
        }

        if let primary = clusters.first {
            // Every stop uses an observed region hue. A narrow analogous range
            // prevents small unrelated colors from dominating the bottom of the card.
            let related = clusters.dropFirst().filter {
                hueDistance($0.hue, primary.hue) <= 0.10 && $0.score >= primary.score * 0.20
            }
            var stops = [ThemeStop(hue: primary.hue, saturation: boostVibrancy(primary.saturation), brightness: primary.brightness)]
            for cluster in related.prefix(2) {
                stops.append(ThemeStop(hue: cluster.hue, saturation: boostVibrancy(cluster.saturation), brightness: cluster.brightness))
            }
            // Reuse a sampled hue when the artwork has fewer than three suitable
            // colors; colors(dark:) varies tone without inventing a new hue.
            while stops.count < 3 { stops.append(stops[0]) }
            return Self(stops: stops)
        }

        // Muted / flat artwork fallback: pick the most frequent color cluster
        var bins: [Int: [Sample]] = [:]
        for y in 0..<gridH {
            for x in activeXRange {
                let sample = samples[y * gridW + x]
                guard sample.alpha > 128 else { continue }
                let hueBin = sample.s < 0.10 ? 12 : min(11, Int(sample.h * 12))
                let key = hueBin * 16 + min(3, Int(sample.s * 4)) * 4 + min(3, Int(sample.v * 4))
                bins[key, default: []].append(sample)
            }
        }
        guard let key = bins.keys.sorted().max(by: { bins[$0]!.count < bins[$1]!.count }),
              let common = bins[key], !common.isEmpty else { return nil }
        let sat = common.reduce(CGFloat(0)) { $0 + $1.s } / CGFloat(common.count)
        let val = common.reduce(CGFloat(0)) { $0 + $1.v } / CGFloat(common.count)
        let sine = common.reduce(CGFloat(0)) { $0 + sin($1.h * 2 * .pi) * $1.s }
        let cosine = common.reduce(CGFloat(0)) { $0 + cos($1.h * 2 * .pi) * $1.s }
        let hue = key / 16 == 12 ? CGFloat(0) : wrapHue(atan2(sine, cosine) / (2 * .pi))
        let mutedSat = sat < 0.07 ? 0 : min(0.42, pow(sat, 0.78) * 0.85)
        let stop = ThemeStop(hue: hue, saturation: mutedSat, brightness: val)
        return Self(stops: [stop, stop, stop])
    }

    func colors(dark: Bool) -> [Color] {
        dark ? darkColors : lightColors
    }

    func chip(dark: Bool) -> Color {
        dark ? darkChip : lightChip
    }
}

struct VideoInformationMetadataSections: View {
    @ObservedObject private var onlineMovies = OnlineMovieLibrary.shared
    @StateObject private var onlineArtwork = OnlineSummaryArtwork()
    @ObservedObject var model: PlayerModel
    let telemetry: PlayerTelemetryState
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nfo: MediaNFOMetadata? = nil
    @State private var resolvedNFOURL: URL? = nil
    @State private var nfoModification: Date? = nil
    @State private var nfoContents: Data? = nil
    @State private var editingMediaPath = ""
    @State private var savingNFO = false
    @State private var nfoSourceName: String = ""
    @State private var sidecarSubtitles: [URL] = []
    @State private var informationCover: NSImage? = nil
    @State private var artworkTheme: MediaArtworkTheme? = nil
    @State private var loadedCoverPath: String = ""
    @Environment(\.colorScheme) private var informationColorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var isEditingNFO = false
    @State private var saveError: String = ""
    @State private var draftTitle = ""
    @State private var draftOriginalTitle = ""
    @State private var draftYear = ""
    @State private var draftRating: Double? = nil
    @State private var draftMPAA = ""
    @State private var draftRuntime = ""
    @State private var draftDirectors = ""
    @State private var draftActors = ""
    @State private var draftStudio = ""
    @State private var draftGenres = ""
    @State private var draftTags = ""
    @State private var draftPlot = ""

    init(model: PlayerModel, active: Bool = true) {
        self.model = model
        self.telemetry = model.telemetry
        self.active = active
        let path = model.path
        if !path.isEmpty {
            let dedicatedHit = QueueMetadataCache.cachedDedicatedArtwork(path)
            let immediateCover = dedicatedHit.image ?? ThumbnailImageCache.shared.lookup(path)?.image
            let immediateTheme = immediateCover.flatMap { MediaArtworkTheme.resolve(for: path, image: $0) } ?? MediaArtworkTheme.cached(for: path)
            let cachedNFO = MediaNFOCache.shared.lookup(path)
            _informationCover = State(initialValue: immediateCover)
            _artworkTheme = State(initialValue: immediateTheme)
            _loadedCoverPath = State(initialValue: (dedicatedHit.found && dedicatedHit.image != nil) ? path : "")
            _nfo = State(initialValue: cachedNFO.found ? cachedNFO.value : nil)
        }
    }

    private var canEditLocalNFO: Bool {
        model.path.hasPrefix("/")
    }

    private struct SubtitleTrackDetail: Identifiable {
        let id: Int
        let label: String
        let codec: String
        let lang: String
        let isExternal: Bool
        let externalFilename: String
        let isPrimary: Bool
        let isSecondary: Bool
    }

    private var subtitleTrackDetails: [SubtitleTrackDetail] {
        let _ = active ? telemetry.revision : 0
        let rawTracks = model.snapshot["track-list"] as? [[String: Any]] ?? []
        let subDicts = rawTracks.filter { $0["type"] as? String == "sub" }
        if !subDicts.isEmpty {
            return subDicts.compactMap { t -> SubtitleTrackDetail? in
                guard let id = t["id"] as? Int else { return nil }
                let idString = String(id)
                let title = (t["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let lang = (t["lang"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let codec = (t["codec"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
                let isExternal = (t["external"] as? Bool) == true
                let extFile = (t["external-filename"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
                let displayLabel = !title.isEmpty ? title : (!extFile.isEmpty ? extFile : (!lang.isEmpty ? lang.uppercased() : "Track \(id)"))
                return SubtitleTrackDetail(
                    id: id,
                    label: displayLabel,
                    codec: codec,
                    lang: lang,
                    isExternal: isExternal,
                    externalFilename: extFile,
                    isPrimary: model.subtitleID == idString,
                    isSecondary: model.secondarySubtitleID == idString
                )
            }
        }
        return model.subtitles.map { track in
            let idString = String(track.id)
            return SubtitleTrackDetail(
                id: track.id,
                label: track.title,
                codec: "",
                lang: "",
                isExternal: false,
                externalFilename: "",
                isPrimary: model.subtitleID == idString,
                isSecondary: model.secondarySubtitleID == idString
            )
        }
    }

    private var hasSubtitleInfo: Bool {
        !model.subtitles.isEmpty || !sidecarSubtitles.isEmpty || model.liveCaptionPlacement != "off"
    }

    var body: some View {
        OnlineMovieControls(model: model)
        Group {
            metadataCard

            if hasSubtitleInfo {
                let details = subtitleTrackDetails
                InformationSectionCard("Subtitles") {
                    let primaryTrack = details.first(where: \.isPrimary)
                    LabeledContent("Primary subtitle", value: formattedTrackSummary(primaryTrack, fallbackID: model.subtitleID))

                    if model.secondarySubtitleID != "no" || details.count > 1 {
                        let secondaryTrack = details.first(where: \.isSecondary)
                        LabeledContent(
                            "Secondary subtitle",
                            value: formattedTrackSummary(secondaryTrack, fallbackID: model.secondarySubtitleID)
                        )
                    }

                    if model.liveCaptionPlacement != "off" {
                        LabeledContent("Live captions", value: model.liveCaptionPlacement.capitalized)
                    }

                    DisclosureGroup("Track Details") {
                    if !details.isEmpty {
                        LabeledContent("Loaded tracks", value: "\(details.count)")
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(details) { track in
                                HStack(spacing: 6) {
                                    Text("#\(track.id)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 22, alignment: .leading)
                                    Text(track.label)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    if !track.lang.isEmpty {
                                        Text(track.lang.uppercased())
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    if !track.codec.isEmpty {
                                        Text(track.codec)
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.primary.opacity(0.08), in: Capsule())
                                    }
                                    Text(track.isExternal ? String(localized: "External") : String(localized: "Embedded"))
                                        .font(.caption2)
                                        .foregroundStyle(track.isExternal ? Color.accentColor : Color.secondary)
                                }
                            }
                        }
                    }

                    if !sidecarSubtitles.isEmpty {
                        LabeledContent(
                            "Sidecar subtitle files",
                            value: sidecarSubtitles.map(\.lastPathComponent).joined(separator: " · ")
                        )
                    }
                }
            }
            }
        }
        .task(id: "online-info|\(model.path)|\(active)|\(onlineMovies.movie(for: model.path)?.posterURL?.absoluteString ?? "")") {
            guard active else { return }
            await onlineArtwork.load(path: model.path, url: onlineMovies.movie(for: model.path)?.posterURL)
        }
        .task(id: "cover|\(model.path)|\(active)|\(model.path.hasPrefix("/") ? false : model.remoteMetadataDeferred)") {
            guard active else { return }
            let path = model.path
            guard !path.isEmpty else {
                loadedCoverPath = ""
                informationCover = nil
                artworkTheme = nil
                return
            }
            // Do not wipe or reload when the cover for this path is already displayed.
            if loadedCoverPath == path, informationCover != nil {
                return
            }
            var hasImmediateForPath = false
            if loadedCoverPath != path {
                loadedCoverPath = path
                // Synchronously seed from in-memory caches so opening a file with a cached
                // cover or browser thumbnail shows its cover and theme on the very first frame.
                let dedicatedHit = QueueMetadataCache.cachedDedicatedArtwork(path)
                if let immediateImage = dedicatedHit.image ?? ThumbnailImageCache.shared.lookup(path)?.image {
                    hasImmediateForPath = true
                    informationCover = immediateImage
                    artworkTheme = MediaArtworkTheme.resolve(for: path, image: immediateImage)
                    if dedicatedHit.found && dedicatedHit.image != nil {
                        return
                    }
                } else if let cachedTheme = MediaArtworkTheme.cached(for: path) {
                    artworkTheme = cachedTheme
                }
            }

            if path.hasPrefix("/") {
                let posterAndTheme: (NSImage, MediaArtworkTheme?)? = await Task.detached(priority: .userInitiated) {
                    guard let poster = QueueMetadataCache.detailArtwork(path) else { return nil }
                    let theme = MediaArtworkTheme.resolve(for: path, image: poster)
                    return (poster, theme)
                }.value
                guard !Task.isCancelled, model.path == path else { return }
                if let (poster, theme) = posterAndTheme {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                        informationCover = poster
                        artworkTheme = theme
                    }
                    return
                }
                if hasImmediateForPath { return }
                let metadata = await QueueMetadataCache.shared.read(path, cover: true, priority: .detail)
                guard !Task.isCancelled, model.path == path else { return }
                guard let data = metadata.cover else {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.20)) {
                        informationCover = nil
                        artworkTheme = nil
                    }
                    return
                }
                let decodedAndTheme: (NSImage, MediaArtworkTheme?)? = await Task.detached(priority: .userInitiated) {
                    guard let image = ThumbnailImageCache.decodeImage(from: data, maxPixels: 900) else { return nil }
                    let theme = MediaArtworkTheme.resolve(for: path, image: image)
                    return (image, theme)
                }.value
                guard !Task.isCancelled, model.path == path, let (image, theme) = decodedAndTheme else { return }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                    informationCover = image
                    artworkTheme = theme
                }
            } else if let entry = model.remoteEntries[path] {
                let metadata = await model.remoteMetadata.read(entry, cover: true,
                    allowLoad: !model.remoteMetadataDeferred, priorityRevision: model.metadataPriorityRevision)
                guard !Task.isCancelled, model.path == path else { return }
                guard let data = metadata.cover else {
                    if !hasImmediateForPath {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.20)) {
                            informationCover = nil
                            artworkTheme = nil
                        }
                    }
                    return
                }
                let decodedAndTheme: (NSImage, MediaArtworkTheme?)? = await Task.detached(priority: .userInitiated) {
                    guard let image = ThumbnailImageCache.decodeImage(from: data, maxPixels: 900) else { return nil }
                    let theme = MediaArtworkTheme.resolve(for: path, image: image)
                    return (image, theme)
                }.value
                guard !Task.isCancelled, model.path == path, let (image, theme) = decodedAndTheme else { return }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                    informationCover = image
                    artworkTheme = theme
                }
            }
        }
        .task(id: "\(model.path)|\(active)") {
            // Tab switches must not discard a draft or replace its conflict baseline.
            if isEditingNFO && editingMediaPath == model.path { return }
            isEditingNFO = false
            saveError = ""
            guard active, !model.path.isEmpty else {
                if model.path.isEmpty {
                    nfo = nil
                    resolvedNFOURL = nil
                    nfoModification = nil
                    nfoContents = nil
                    nfoSourceName = ""
                    sidecarSubtitles = []
                }
                return
            }
            await loadCurrentMediaNFOAndSubtitles(for: model.path)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaCoverDidChange)) { note in
            guard let changedPath = note.object as? String,
                  !model.path.isEmpty,
                  changedPath == model.path || URL(fileURLWithPath: changedPath).standardizedFileURL == URL(fileURLWithPath: model.path).standardizedFileURL else { return }
            let path = model.path
            Task { await onlineArtwork.load(path: path, url: onlineMovies.movie(for: path)?.posterURL) }
            let updatedCover = QueueMetadataCache.cachedDedicatedArtwork(path).image ?? ThumbnailImageCache.shared.lookup(path)?.image
            let updatedTheme = updatedCover.flatMap { MediaArtworkTheme.resolve(for: path, image: $0) } ?? MediaArtworkTheme.cached(for: path)
            loadedCoverPath = path
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) {
                if let updatedCover { informationCover = updatedCover }
                if let updatedTheme { artworkTheme = updatedTheme }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaNFODidChange)) { note in
            guard let changedPath = note.object as? String,
                  !model.path.isEmpty,
                  changedPath == model.path || URL(fileURLWithPath: changedPath).standardizedFileURL == URL(fileURLWithPath: model.path).standardizedFileURL else { return }
            Task {
                await loadCurrentMediaNFOAndSubtitles(for: model.path)
            }
        }
    }

    private var displayMetadata: MediaNFOMetadata {
        CurrentMediaMetadataResolver.resolve(nfo: nfo,
            raw: model.snapshot["metadata"] as? [String: String] ?? [:],
            fallbackTitle: model.path.isEmpty ? "" : model.title, online: onlineMovies.movie(for: model.path))
    }

    private var metadataDuration: String {
        if let minutes = displayMetadata.runtimeMinutes { return String(localized: "\(minutes) min") }
        guard model.duration.isFinite, model.duration > 0 else { return "N/A" }
        let seconds = Int(min(model.duration, Double(Int32.max)))
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    @ViewBuilder
    private func searchableMetadataLink(_ text: String) -> some View {
        Button {
            model.searchInCurrentFolder(text)
        } label: {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Search in current folder"))
    }

    private var metadataCard: some View {
        let info = displayMetadata
        let dark = informationColorScheme == .dark
        let onlineImage = onlineArtwork.image(for: model.path, url: onlineMovies.movie(for: model.path)?.posterURL)
        let awaitingOnline = onlineArtwork.awaitingImage(path: model.path, url: onlineMovies.movie(for: model.path)?.posterURL)
        let informationCover = onlineImage ?? (awaitingOnline ? nil : self.informationCover)
        let artworkTheme = onlineImage != nil ? onlineArtwork.theme(for: model.path, url: onlineMovies.movie(for: model.path)?.posterURL) : (awaitingOnline ? nil : self.artworkTheme)
        let chip = artworkTheme?.chip(dark: dark) ?? Color.primary
        return VStack(alignment: .leading, spacing: 10) {
            if awaitingOnline {
                ProgressView().frame(maxWidth: .infinity).frame(height: 180)
            } else if let informationCover {
                MediaDetailCover(image: informationCover, maximumHeight: 460, cornerRadius: 12)
                    .transition(.opacity)
            }
            if !info.title.isEmpty {
                Text(info.title).font(.title3.weight(.bold))
                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            if !info.originalTitle.isEmpty && info.originalTitle != info.title {
                Text(info.originalTitle).font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Label(metadataDuration, systemImage: "clock").monospacedDigit()
                Spacer()
                HStack(spacing: 7) {
                    if !info.mpaa.isEmpty {
                        Text(info.mpaa).font(.caption2.weight(.medium))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.45), lineWidth: 0.5) }
                    }
                    if !info.year.isEmpty {
                        Button {
                            model.searchInCurrentFolder(info.year)
                        } label: {
                            Text(info.year)
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Search in current folder"))
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }.font(.caption).foregroundStyle(.secondary)
            if isEditingNFO {
                NFOStarRatingPicker(ratingOutOfTen: draftRating, editable: true) { draftRating = $0 }
                nfoEditorFields
            } else {
                if info.rating != nil || canEditLocalNFO {
                    NFOStarRatingPicker(ratingOutOfTen: info.rating, editable: canEditLocalNFO) { updateStarRatingDirectly($0) }
                }
                if !info.directors.isEmpty {
                    LabeledContent("Director") {
                        MetadataFlowLayout(alignment: .trailing, spacing: 6, lineSpacing: 4) {
                            ForEach(Array(info.directors.enumerated()), id: \.offset) { index, director in
                                HStack(spacing: 4) {
                                    searchableMetadataLink(director)
                                    if index < info.directors.count - 1 {
                                        Text("/").font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                }
                if !info.actors.isEmpty {
                    let castList = Array(info.actors.prefix(10))
                    LabeledContent(model.audioOnly ? "Artist" : "Cast") {
                        MetadataFlowLayout(alignment: .trailing, spacing: 6, lineSpacing: 4) {
                            ForEach(Array(castList.enumerated()), id: \.offset) { index, actor in
                                HStack(spacing: 4) {
                                    searchableMetadataLink(actor)
                                    if index < castList.count - 1 {
                                        Text("·").font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                }
                if !info.studio.isEmpty {
                    LabeledContent("Studio") {
                        searchableMetadataLink(info.studio)
                    }
                }
                if !info.genres.isEmpty || !info.tags.isEmpty {
                    MetadataFlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(Array((info.genres + info.tags).enumerated()), id: \.offset) { _, tag in
                            Button {
                                model.searchInCurrentFolder(tag)
                            } label: {
                                Text(tag)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(chip.opacity(dark ? 0.25 : 0.15), in: Capsule())
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                                    )
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help(String(localized: "Search in current folder"))
                        }
                    }
                }
                if !info.plot.isEmpty { Text(info.plot).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                HStack(alignment: .center, spacing: 8) {
                    if !nfoSourceName.isEmpty {
                        Text(nfoSourceName).font(.caption2).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle).help(nfoSourceName)
                    }
                    Spacer(minLength: 0)
                    if canEditLocalNFO {
                        Button("Edit Metadata…", systemImage: "square.and.pencil", action: beginEditingNFO)
                            .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
                            .help("Edit Metadata…").accessibilityLabel("Edit Metadata…")
                    }
                }
            }
        }
        .labeledContentStyle(InformationValueStyle())
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
            shape.fill(.ultraThinMaterial)
                .opacity(reduceTransparency ? 1 : 0.78)
            LinearGradient(
                colors: artworkTheme?.colors(dark: dark) ?? [.clear, .clear, .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(artworkTheme == nil ? 0 : (reduceTransparency ? 1 : 0.34))
            .clipShape(shape)
            shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: informationCover != nil)
        .animation(reduceMotion ? nil : .smooth(duration: 0.36), value: artworkTheme)
        .animation(reduceMotion ? nil : .spring(duration: 0.34, bounce: 0.06), value: isEditingNFO)
    }

    @ViewBuilder
    private var nfoEditorFields: some View {
        Group {
            TextField("Title", text: $draftTitle)
            TextField("Original title", text: $draftOriginalTitle)
            TextField("Year", text: $draftYear)
            TextField("Director (separate with / or ,)", text: $draftDirectors)
            TextField("Cast (separate with / or ,)", text: $draftActors)
            TextField("Genre (separate with / or ,)", text: $draftGenres)
            TextField("Tags (separate with / or ,)", text: $draftTags)
            TextField("Studio", text: $draftStudio)
            TextField("Content rating (MPAA)", text: $draftMPAA)
            TextField("Runtime (minutes)", text: $draftRuntime)
            TextField("Plot", text: $draftPlot, axis: .vertical)
                .lineLimit(3...6)
        }
        .textInputBorderShape(.roundedRectangle)
        if !saveError.isEmpty {
            Text(saveError)
                .font(.caption)
                .foregroundStyle(.red)
        }
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel") {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.05)) {
                    isEditingNFO = false
                    saveError = ""
                }
            }
            .controlSize(.small)

            Button("Save") {
                saveEditedNFO()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private func beginEditingNFO() {
        editingMediaPath = model.path
        let current = displayMetadata
        let fallbackTitle = URL(fileURLWithPath: model.path).deletingPathExtension().lastPathComponent
        draftTitle = current.title.isEmpty ? fallbackTitle : current.title
        draftOriginalTitle = current.originalTitle
        draftYear = current.year
        draftRating = current.rating
        draftMPAA = current.mpaa
        draftRuntime = current.runtimeMinutes.map(String.init) ?? ""
        draftDirectors = current.directors.joined(separator: " / ")
        draftActors = current.actors.joined(separator: " / ")
        draftStudio = current.studio
        draftGenres = current.genres.joined(separator: " / ")
        draftTags = current.tags.joined(separator: " / ")
        draftPlot = current.plot
        saveError = ""
        withAnimation(reduceMotion ? nil : .spring(duration: 0.34, bounce: 0.06)) {
            isEditingNFO = true
        }
    }

    private func splitListInput(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: "/,，、·;；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func updateStarRatingDirectly(_ newRating: Double?) {
        guard canEditLocalNFO && !savingNFO else { return }
        var updated = displayMetadata
        if updated.title.isEmpty {
            updated.title = URL(fileURLWithPath: model.path).deletingPathExtension().lastPathComponent
        }
        updated.rating = newRating
        persistNFO(updated, closeEditor: false)
    }

    private func saveEditedNFO() {
        guard canEditLocalNFO && !savingNFO else { return }
        var updated = MediaNFOMetadata()
        let fallbackTitle = URL(fileURLWithPath: model.path).deletingPathExtension().lastPathComponent
        updated.title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if updated.title.isEmpty { updated.title = fallbackTitle }
        updated.originalTitle = draftOriginalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.year = draftYear.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.rating = draftRating
        updated.mpaa = draftMPAA.trimmingCharacters(in: .whitespacesAndNewlines)
        let runtimeTrimmed = draftRuntime.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.runtimeMinutes = Int(runtimeTrimmed)
        updated.directors = splitListInput(draftDirectors)
        updated.actors = splitListInput(draftActors)
        updated.studio = draftStudio.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.genres = splitListInput(draftGenres)
        updated.tags = splitListInput(draftTags)
        updated.plot = draftPlot.trimmingCharacters(in: .whitespacesAndNewlines)

        persistNFO(updated, closeEditor: true)
    }

    private func persistNFO(_ updated: MediaNFOMetadata, closeEditor: Bool) {
        let path = model.path
        let target = resolvedNFOURL
        let revision = nfoModification
        let contents = nfoContents
        let expectsMissing = target == nil
        savingNFO = true
        Task {
            defer { savingNFO = false }
            do {
                let savedURL = try await MediaNFOCache.shared.saveLocalMetadata(updated,
                    forMediaPath: path, preferredNFOURL: target, expectedModification: revision,
                    expectedContents: contents, expectsMissing: expectsMissing)
                guard model.path == path else { return }
                nfo = updated; resolvedNFOURL = savedURL
                let contents = await Task.detached(priority: .utility) { MediaNFOCache.readLocalNFO(savedURL) }.value
                guard model.path == path else { return }
                nfoContents = contents
                if let contents, let fresh = NFOParser.parse(contents) { nfo = fresh }
                nfoModification = (try? FileManager.default.attributesOfItem(atPath: savedURL.path)[.modificationDate]) as? Date
                nfoSourceName = savedURL.lastPathComponent
                if closeEditor { isEditingNFO = false }
                saveError = ""
            } catch {
                guard model.path == path else { return }
                saveError = error.localizedDescription
            }
        }
    }

    private func formattedTrackSummary(_ track: SubtitleTrackDetail?, fallbackID: String) -> String {
        guard fallbackID != "no" else { return String(localized: "Off") }
        guard let track else { return "Track \(fallbackID)" }
        var parts: [String] = [track.label]
        if !track.lang.isEmpty && !track.label.localizedCaseInsensitiveContains(track.lang) {
            parts.append(track.lang.uppercased())
        }
        if !track.codec.isEmpty {
            parts.append(track.codec)
        }
        parts.append(track.isExternal ? String(localized: "External") : String(localized: "Embedded"))
        return parts.joined(separator: " · ")
    }

    private func loadCurrentMediaNFOAndSubtitles(for path: String) async {
        if path.hasPrefix("/") {
            let discovered = await MediaNFOCache.shared.localSnapshot(for: path)
            guard !Task.isCancelled, model.path == path else { return }
            let subs = await Task.detached(priority: .utility) {
                FolderMedia.matchingSubtitles(for: URL(fileURLWithPath: path)).all
            }.value
            guard !Task.isCancelled, model.path == path else { return }
            sidecarSubtitles = subs
            let primaryMeta = discovered.metadata
            MediaNFOCache.shared.store(path, value: primaryMeta)
            nfo = primaryMeta
            resolvedNFOURL = discovered.nfoURL
            nfoModification = discovered.modification
            nfoContents = discovered.contents
            nfoSourceName = (discovered.nfoURL ?? discovered.showNFOURL)?.lastPathComponent ?? ""
        } else if let remote = model.remoteEntries[path], case .webDAV(let creds) = remote.origin {
            sidecarSubtitles = []
            resolvedNFOURL = nil
            let remoteURL = remote.item.url
            let nfoCandidate = remoteURL.deletingPathExtension().appendingPathExtension("nfo")
            let loaded = await MediaNFOCache.shared.metadata(
                for: remote.item.id,
                localMediaURL: nil,
                nfoURL: nfoCandidate,
                isFolder: false,
                credentials: creds
            )
            guard !Task.isCancelled, model.path == path else { return }
            MediaNFOCache.shared.store(path, value: loaded)
            nfo = loaded
            nfoSourceName = loaded != nil ? nfoCandidate.lastPathComponent : ""
        } else {
            nfo = nil
            resolvedNFOURL = nil
            nfoSourceName = ""
            sidecarSubtitles = []
        }
    }
}

struct VideoInformationRows: View {
    @ObservedObject var model: PlayerModel
    let telemetry: PlayerTelemetryState
    let active: Bool
    init(model: PlayerModel, active: Bool = true) {
        self.active = active
        self.model = model
        self.telemetry = model.telemetry
    }
    var body: some View {
        let _ = active ? telemetry.revision : 0
        if model.audioOnly {
            LabeledContent("Media", value: String(localized: "Audio"))
            LabeledContent("Audio codec", value: model.audioCodec)
            LabeledContent("Decoded audio", value: model.audioFormatDescription)
            LabeledContent("Audio bitrate", value: model.bitrate(model.number("audio-bitrate")))
            LabeledContent("Artist", value: model.audioArtist.isEmpty ? "N/A" : model.audioArtist)
            LabeledContent("Album", value: model.audioAlbum.isEmpty ? "N/A" : model.audioAlbum)
        } else {
        LabeledContent("Source", value: model.sourceDescription)
        LabeledContent("Source FPS (container)", value: model.fps("container-fps"))
        LabeledContent("Video codec / profile", value: model.sourceCodec)
        LabeledContent("Active hardware decoder", value: model.systemHDRActive ? "AVKit · N/A" : model.snapshot["hwdec-current"] as? String ?? "N/A")
        LabeledContent("Requested decoder", value: model.systemHDRActive ? "AVKit" : model.effectiveDecoderOption)
        LabeledContent("Video bitrate (packet estimate)", value: model.videoBitrate)
        LabeledContent("Declared video bitrate", value: model.declaredVideoBitrate)
        LabeledContent("Audio codec", value: model.audioCodec)
        LabeledContent("Audio bitrate (packet estimate)", value: model.bitrate(model.number("audio-bitrate")))
        Text("Packet bitrate is estimated between keyframes and may update slowly. It is not network speed or total file bitrate.").font(.caption).foregroundStyle(.secondary)
        LabeledContent("Source pixel format", value: model.source["pixelformat"] as? String ?? "N/A")
        Text(model.sourceColor).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        if model.isDolbyVision && !model.systemHDRActive {
            LabeledContent("Dolby Vision", value: model.dolbyVisionStatus)
            Text("The OpenGL presentation surface is SDR. Supported per-frame RPU is mapped on the GPU before BT.2390 tone mapping. No native Dolby Vision / EDR output or full enhancement-layer reconstruction. SDR-only neural effects are bypassed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        LabeledContent("Filter output", value: model.systemHDRActive ? "AVKit · N/A" : model.outputDescription)
        LabeledContent("Output FPS (estimated)", value: model.fps("estimated-vf-fps"))
        LabeledContent("Picture area", value: model.systemHDRActive ? "N/A" : model.pictureDescription)
        LabeledContent("Render viewport", value: model.systemHDRActive ? "N/A" : model.viewportDescription)
        DisclosureGroup("Rendering & Enhancement Diagnostics") {
        LabeledContent("Render callbacks", value: model.renderRate)
        LabeledContent("Measured display FPS", value: "N/A")
        LabeledContent("Render call P95", value: model.renderTiming("draw_p95_ms"))
        LabeledContent("Buffer swap call P95", value: model.renderTiming("swap_p95_ms"))
        LabeledContent("FI queue P95 · dispatch / ready / backpressure", value: model.queueTimes(model.fi == "rife" ? "iive-rife" : "iive-fi"))
        LabeledContent("SR queue P95 · dispatch / ready / backpressure", value: model.queueTimes("iive-sr"))
        LabeledContent("FI queue surface estimate", value: model.queueBudget(model.fi == "rife" ? "iive-rife" : "iive-fi"))
        LabeledContent("SR queue surface estimate", value: model.queueBudget("iive-sr"))
        Text("Per-stage surface estimates constrain optional prefetch. Model workspace, decoder buffers and idle pool caches are excluded; a required batch can exceed the target. These are not measured memory usage.").font(.caption).foregroundStyle(.secondary)
        Text("Queue and render percentiles cover recent samples. Model calls include CPU scheduling and GPU waits; buffer swaps are not measured display latency.").font(.caption).foregroundStyle(.secondary)
        }
        }
        if !model.path.isEmpty && !model.path.hasPrefix("/") {
            LabeledContent("Network playback", value: model.playbackActivity.rawValue.capitalized)
            LabeledContent("Background metadata", value: model.remoteMetadataDeferred ? String(localized: "Deferred · cached information only") : String(localized: "Available · one request at a time"))
            LabeledContent("Seekable", value: model.mediaSeekable ? String(localized: "Yes") : String(localized: "No / Live"))
            LabeledContent("Media buffered", value: (model.snapshot["demuxer-cache-duration"] as? NSNumber).map { String(format: "%.1f s", $0.doubleValue) } ?? "N/A")
        }
        LabeledContent("Player CPU", value: model.processCPU)
        LabeledContent("Player memory footprint", value: model.memoryDescription("process-memory-bytes"))
        LabeledContent("Peak sampled footprint", value: model.memoryDescription("process-peak-sampled-footprint-bytes"))
        LabeledContent("Resident memory", value: model.memoryDescription("process-resident-bytes"))
        Text("CPU samples this process once per second; 100% equals one CPU core. Memory is this process, not system usage.").font(.caption).foregroundStyle(.secondary)
        LabeledContent("Performance Recording") {
            HStack(spacing: 8) {
                Button(model.recordingMetrics ? String(localized: "Stop Recording") : String(localized: "Start Recording")) {
                    model.toggleMetricsRecording()
                }
                Button("Export JSONL…") {
                    model.exportMetricsRecording()
                }.disabled(!model.recordingMetrics && model.lastMetricsURL == nil)
                if model.lastMetricsURL != nil && !model.recordingMetrics {
                    Button("Show in Finder") {
                        model.revealMetricsRecording()
                    }
                }
            }
        }
        Text(active ? model.metricsStatus + String(localized: " · Summarize with: python3 benchmarks/pipeline_profile.py --summarize-player <file.jsonl>") : String(localized: ""))
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        if !model.audioOnly {
        LabeledContent("Added rotation", value: "\(Int(model.number("video-rotate") ?? Double(model.rotation)))°")
        Text(model.colorProfileStatus).font(.caption).foregroundStyle(.secondary)
        Text("Output FPS uses recent frame timestamps, not physical display measurements; it may fluctuate after seeks and does not include playback speed. Filter output precedes any display shader. Picture area includes final display scaling.")
            .font(.caption).foregroundStyle(.secondary)
        }
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
        fileDialogs.importFiles(title: "Choose RGB ICC Profile") { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.colorProfileStatus = "Could not open profile: " + error.localizedDescription
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { @MainActor [weak self] in
                    let data = await Task.detached(priority: .utility) { () -> Data? in
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1024 * 1024 else { return nil }
                        return try? Data(contentsOf: url)
                    }.value
                    guard let self else { return }
                    guard let data, NSColorSpace(iccProfileData: data)?.colorSpaceModel == .rgb else {
                        self.colorProfileStatus = "Invalid or unsupported RGB ICC profile (maximum 16 MB)."; return
                    }
                    // Keep a validated copy independent of the original file's lifetime.
                    UserDefaults.standard.set(data, forKey: "customICCData")
                    UserDefaults.standard.set(url.lastPathComponent, forKey: "customICCName")
                    self.colorProfile = "custom"
                }
            }
        }
    }

    func applyColorProfile() {
        colorProfileTask?.cancel()
        guard let view = videoView, let session else { return }
        let mode = colorProfile
        let screen = view.window?.screen ?? NSScreen.main
        let data: Data?
        let label: String
        switch mode {
        case "display": data = screen?.colorSpace?.iccProfileData; label = "Current Display ICC"
        case "srgb": data = NSColorSpace.sRGB.iccProfileData; label = "sRGB ICC"
        case "p3": data = NSColorSpace.displayP3.iccProfileData; label = "Display P3 ICC"
        case "custom": data = UserDefaults.standard.data(forKey: "customICCData"); label = UserDefaults.standard.string(forKey: "customICCName") ?? "Custom ICC"
        default: data = nil; label = "Automatic · source metadata"
        }
        let missingProfile = mode != "auto" && data == nil
        colorProfileStatus = "Configuring output color…"
        colorProfileTask = Task { [weak self, weak view, weak session] in
            guard let self, let view, let session, !Task.isCancelled else { return }
            let iccAccepted = await view.setICCProfileData(data)
            guard !Task.isCancelled, self.videoView === view else { return }
            let commands = [
                ["set", "icc-profile-auto", data != nil ? "yes" : "no"],
                ["set", "target-prim", "auto"],
                ["set", "target-trc", "auto"],
                ["set", "target-peak", "auto"]
            ]
            let accepted = await session.configureColorOutput(commands)
            guard !Task.isCancelled, self.videoView === view else { return }
            guard iccAccepted && accepted else {
                self.colorProfileStatus = "Unable to apply output profile · playback continues with available SDR configuration"
                return
            }
            self.colorProfileStatus = missingProfile ? "Unavailable ICC · using automatic source metadata"
                : mode == "auto" ? label : "Configured · \(label)"
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
        SystemPlaybackNotice(model: model)
        Picker("Decoder", selection: $model.decoder) {
            Label("Software", systemImage: "cpu").tag("no")
            Label("Auto · Hardware Enabled", systemImage: "bolt.circle").tag("auto")
            Label("Hardware · Copy", systemImage: "square.on.square").tag("videotoolbox-copy")
        }
        .disabled(model.systemHDRActive)
        Text(model.decoderExplanation).font(.caption).foregroundStyle(.secondary)
        Text("Changes apply to the current video and are saved. Auto shares VideoToolbox IOSurfaces only when color metadata and centered chroma match the model input; other supported frames are converted. Unsupported hardware formats fall back automatically; changing modes may briefly interrupt decoding.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
struct PictureSettings: View {
    @ObservedObject var model: PlayerModel
    var body: some View {
        SystemPlaybackNotice(model: model)
        Group {
        Toggle("Dolby Vision RPU Mapping · Experimental", isOn: $model.dolbyVisionMapping)
        Text("Applies available per-frame Dolby Vision metadata before SDR tone mapping. No EDR output or full enhancement-layer reconstruction. Turn off only to compare a compatible base layer; Profile 5 requires RPU mapping for correct colors.")
            .font(.caption).foregroundStyle(.secondary)
        Picker("Rotation · Added to File Orientation", selection: $model.rotation) {
            Text("0°").tag(0); Text("90° Clockwise").tag(90); Text("180°").tag(180); Text("270° Clockwise").tag(270)
        }
        VideoGeometryControls(model: model)
        Text("Aspect ratio stretches the picture; center crop removes edges at the display stage. Both reset when opening media and leave the original file untouched. Crop uses the final frame size, including super resolution.")
            .font(.caption).foregroundStyle(.secondary)
        Text("Deinterlacing runs before enhancement and is saved. Auto follows source frame flags, which can be incorrect. Auto/On bypasses AI interpolation to avoid processing doubled field cadence; SR remains available. VideoToolbox NV12/P010 frames use Metal YADIF when available. Other inputs use CPU BWDIF and may require a hardware-frame transfer.")
            .font(.caption).foregroundStyle(.secondary)
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
        }.disabled(model.systemHDRActive)
        LabeledContent("HDR Output", value: model.systemHDRActive ? model.systemHDRPlayback.status : String(localized: "SDR Tone Mapping"))
        Toggle("Use system HDR playback automatically", isOn: $model.automaticSystemHDR)
        if model.systemHDRActive {
            Button("Return to mpv playback", systemImage: "arrow.uturn.backward") { model.systemHDRPlayback.close() }
        } else {
            Button("Use system HDR playback", systemImage: "play.rectangle") { model.openSystemHDRPlayback() }
                .disabled(!model.loaded || !model.hasMotionVideo || !model.path.hasPrefix("/"))
        }
        Text("Supported local HDR MP4 and MOV files play in this window using AVKit. Use the existing menus to select system audio and subtitles. Enhancement, external and second subtitles are unavailable. Other files retain mpv tone mapping.")
            .font(.caption).foregroundStyle(.secondary)
        Text(model.colorProfileStatus).font(.caption).foregroundStyle(.secondary)
        Text("ICC describes the output display, not the source. Choose a profile matching your display; sRGB/P3 are manual overrides, not HDR upgrades. Existing HDR enhancement restrictions still apply.").font(.caption).foregroundStyle(.secondary)
    }
    private func adjustment(_ title: LocalizedStringKey, _ symbol: String, _ value: Binding<Double>) -> some View {
        LabeledContent { HStack {
            Slider(value: value, in: -100...100, step: 1).accessibilityLabel(title)
            Text(String(format: "%+.0f", value.wrappedValue)).monospacedDigit().frame(width: 40)
        } } label: { Label(title, systemImage: symbol) }
    }
}

enum CurrentMediaMetadataResolver {
    private static func splitList(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: "/,，、·;；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    static func resolve(nfo: MediaNFOMetadata?, raw: [String: String], fallbackTitle: String, online: OnlineMovie? = nil) -> MediaNFOMetadata {
        var tags: [String: String] = [:]
        for (key, value) in raw { tags[key.lowercased()] = value }
        func tag(_ keys: String...) -> String { keys.compactMap { tags[$0] }.first(where: { !$0.isEmpty }) ?? "" }
        var info = nfo ?? MediaNFOMetadata()
        if info.title.isEmpty { info.title = tag("title") }
        if info.title.isEmpty { info.title = online?.title ?? fallbackTitle }
        if info.originalTitle.isEmpty { info.originalTitle = tag("originaltitle", "original_title") }
        if info.year.isEmpty { info.year = String(tag("year", "date", "creation_time").prefix(4)) }
        if nfo?.year.isEmpty != false, Int(info.year) == nil { info.year = "" }
        if info.mpaa.isEmpty { info.mpaa = tag("mpaa", "content_rating", "parental_rating") }
        if info.plot.isEmpty { info.plot = tag("synopsis", "description", "comment") }
        if info.studio.isEmpty { info.studio = tag("studio", "publisher") }
        if info.directors.isEmpty { info.directors = splitList(tag("director")) }
        if info.actors.isEmpty { info.actors = splitList(tag("actors", "cast", "artist")) }
        if info.genres.isEmpty { info.genres = splitList(tag("genre")) }
        if info.tags.isEmpty { info.tags = splitList(tag("keywords", "tags")) }
        if let online {
            if info.originalTitle.isEmpty { info.originalTitle = online.originalTitle ?? "" }
            if info.year.isEmpty { info.year = online.year }
            if info.plot.isEmpty { info.plot = online.overview ?? "" }
            if info.runtimeMinutes == nil, let runtime = online.runtime, runtime > 0 { info.runtimeMinutes = runtime }
            if info.studio.isEmpty { info.studio = online.productionCompanies?.map(\.name).joined(separator: " / ") ?? "" }
            if info.genres.isEmpty { info.genres = online.genres?.map(\.name) ?? [] }
            if info.directors.isEmpty { info.directors = online.credits?.crew.filter { $0.job == "Director" }.map(\.name) ?? [] }
            if info.actors.isEmpty { info.actors = online.credits?.cast.prefix(12).map(\.name) ?? [] }
        }
        return info
    }
}
