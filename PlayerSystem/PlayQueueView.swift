// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AVFoundation
import QuickLook

/// The anchor crosses native List row boundaries; reflection is drawn once behind
/// the whole list, where individual row hosting views cannot crop its falloff.
private struct QueueArtworkReflection {
    let itemID: Int64
    let bounds: Anchor<CGRect>
    let image: NSImage
}

private struct QueueArtworkReflectionKey: PreferenceKey {
    static let defaultValue: QueueArtworkReflection? = nil
    static func reduce(value: inout QueueArtworkReflection?, nextValue: () -> QueueArtworkReflection?) {
        value = nextValue() ?? value
    }
}

/// Samples only the outer border band of the center-cropped (76:44) thumbnail image,
/// converting edge sectors into natural-saturation colors whose opacity scales with grayscale luminance.
@MainActor private struct ArtworkEdgePalette {
    let topLeft: Color
    let top: Color
    let topRight: Color
    let left: Color
    let ambient: Color
    let right: Color
    let bottomLeft: Color
    let bottom: Color
    let bottomRight: Color

    private static var cache: [ObjectIdentifier: (NSImage, ArtworkEdgePalette)] = [:]
    private static var cacheOrder: [ObjectIdentifier] = []

    static func resolve(for image: NSImage) -> ArtworkEdgePalette {
        let key = ObjectIdentifier(image)
        if let cached = cache[key] { return cached.1 }
        let computed = extract(from: image)
        cache[key] = (image, computed)
        cacheOrder.append(key)
        if cacheOrder.count > 128 {
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        return computed
    }

    private static func extract(from image: NSImage) -> ArtworkEdgePalette {
        let w = 24, h = 14
        let borderX = 4, borderY = 3 // Outer ~18-20% perimeter ring of the cropped thumbnail
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let rawCG = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .clear
        }
        // Crop source CGImage to the exact 76:44 (.scaledToFill) aspect ratio displayed by QueueArtwork
        // so edge sampling strictly reads the visible cropped edges rather than clipped letterbox/pillarbox regions.
        let srcW = Double(rawCG.width), srcH = Double(rawCG.height)
        let targetAspect = 76.0 / 44.0
        let srcAspect = srcW / max(1.0, srcH)
        let cropRect: CGRect
        if srcAspect > targetAspect {
            let cropW = srcH * targetAspect
            cropRect = CGRect(x: (srcW - cropW) * 0.5, y: 0, width: cropW, height: srcH)
        } else {
            let cropH = srcW / targetAspect
            cropRect = CGRect(x: 0, y: (srcH - cropH) * 0.5, width: srcW, height: cropH)
        }
        let cgImage = rawCG.cropping(to: cropRect.integral) ?? rawCG

        guard let ctx = CGContext(
                  data: &pixels,
                  width: w,
                  height: h,
                  bitsPerComponent: 8,
                  bytesPerRow: w * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return .clear
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        struct Accumulator {
            var r = 0.0, g = 0.0, b = 0.0, lumaSum = 0.0, weight = 0.0, count = 0.0
            mutating func add(r pr: Double, g pg: Double, b pb: Double) {
                let luma = 0.2126 * pr + 0.7152 * pg + 0.0722 * pb
                let maxC = max(pr, pg, pb), minC = min(pr, pg, pb)
                let w = 1.0 + (maxC - minC) * 0.65
                r += pr * w; g += pg * w; b += pb * w
                weight += w
                lumaSum += luma
                count += 1.0
            }
            func pigment() -> Color {
                guard weight > 0, count > 0 else { return .clear }
                let nr = min(1, max(0, r / weight))
                let ng = min(1, max(0, g / weight))
                let nb = min(1, max(0, b / weight))
                let avgLuma = min(1, max(0, lumaSum / count))
                // Grayscale-driven transparency: black/near-black edges (avgLuma -> 0) become
                // highly transparent (opacity -> 0), while mid/bright edges diffuse with higher opacity.
                guard avgLuma > 0.025 else { return .clear }
                let nsColor = NSColor(srgbRed: nr, green: ng, blue: nb, alpha: 1.0)
                var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0
                nsColor.getHue(&hue, saturation: &sat, brightness: &bri, alpha: nil)
                // Keep saturation natural (slight 6% lift, capped at 0.84) and tame peak brightness.
                let tunedSat = sat < 0.05 ? sat : min(0.84, sat * 1.06)
                let tunedBri = min(0.68, max(0.08, bri * 0.82))
                let lumaOpacity = pow(min(1.0, max(0.0, (avgLuma - 0.025) / 0.78)), 0.88)
                let alpha = min(0.86, lumaOpacity * (0.72 + Double(tunedSat) * 0.16))
                return Color(hue: Double(hue), saturation: Double(tunedSat), brightness: Double(tunedBri), opacity: alpha)
            }
        }

        var tl = Accumulator(), tc = Accumulator(), tr = Accumulator()
        var ml = Accumulator(), mr = Accumulator()
        var bl = Accumulator(), bc = Accumulator(), br = Accumulator()
        var all = Accumulator()

        for y in 0..<h {
            for x in 0..<w {
                let isTop = y < borderY
                let isBottom = y >= h - borderY
                let isLeft = x < borderX
                let isRight = x >= w - borderX
                guard isTop || isBottom || isLeft || isRight else { continue }
                let idx = (y * w + x) * 4
                let r = Double(pixels[idx]) / 255.0
                let g = Double(pixels[idx + 1]) / 255.0
                let b = Double(pixels[idx + 2]) / 255.0
                all.add(r: r, g: g, b: b)
                if isTop && isLeft { tl.add(r: r, g: g, b: b) }
                if isTop && !isLeft && !isRight { tc.add(r: r, g: g, b: b) }
                if isTop && isRight { tr.add(r: r, g: g, b: b) }
                if !isTop && !isBottom && isLeft { ml.add(r: r, g: g, b: b) }
                if !isTop && !isBottom && isRight { mr.add(r: r, g: g, b: b) }
                if isBottom && isLeft { bl.add(r: r, g: g, b: b) }
                if isBottom && !isLeft && !isRight { bc.add(r: r, g: g, b: b) }
                if isBottom && isRight { br.add(r: r, g: g, b: b) }
            }
        }

        return ArtworkEdgePalette(
            topLeft: tl.pigment(),
            top: tc.pigment(),
            topRight: tr.pigment(),
            left: ml.pigment(),
            ambient: all.pigment(),
            right: mr.pigment(),
            bottomLeft: bl.pigment(),
            bottom: bc.pigment(),
            bottomRight: br.pigment()
        )
    }

    private static var clear: ArtworkEdgePalette {
        ArtworkEdgePalette(topLeft: .clear, top: .clear, topRight: .clear,
                           left: .clear, ambient: .clear, right: .clear,
                           bottomLeft: .clear, bottom: .clear, bottomRight: .clear)
    }
}

private struct QueueArtworkReflectionView: View {
    let image: NSImage
    let size: CGSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if !reduceTransparency && contrast != .increased {
            let palette = ArtworkEdgePalette.resolve(for: image)
            let meshPoints: [SIMD2<Float>] = [
                SIMD2(0.0, 0.0), SIMD2(0.5, 0.0), SIMD2(1.0, 0.0),
                SIMD2(0.0, 0.5), SIMD2(0.5, 0.5), SIMD2(1.0, 0.5),
                SIMD2(0.0, 1.0), SIMD2(0.5, 1.0), SIMD2(1.0, 1.0)
            ]
            let meshColors: [Color] = [
                palette.topLeft, palette.top, palette.topRight,
                palette.left, palette.ambient, palette.right,
                palette.bottomLeft, palette.bottom, palette.bottomRight
            ]
            ZStack {
                // Wide outward color fusion field sampled from the cropped perimeter ring
                MeshGradient(width: 3, height: 3, points: meshPoints, colors: meshColors)
                    .frame(width: size.width * 2.10, height: size.height * 2.00)
                    .mask(
                        RadialGradient(
                            colors: [.white, .white.opacity(0.84), .white.opacity(0.36), .clear],
                            center: .center,
                            startRadius: 4,
                            endRadius: max(size.width * 1.06, size.height * 1.04)
                        )
                    )
                    .clipShape(Ellipse())
                    .blur(radius: 19)

                // Near-edge directional color bleed hugging the cropped thumbnail perimeter
                MeshGradient(width: 3, height: 3, points: meshPoints, colors: meshColors)
                    .frame(width: size.width * 1.38, height: size.height * 1.38)
                    .clipShape(Ellipse())
                    .blur(radius: 9)
            }
        }
    }
}

private struct QueueArtwork: View {
    let itemID: Int64
    let image: NSImage?
    let current: Bool
    let visible: Bool
    var artworkSize: CGSize = CGSize(width: 76, height: 44)
    var originalAspect = false
    @Environment(\.queueArtworkPressed) private var pressed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.quaternary)
                .overlay { Image(systemName: "play.rectangle").foregroundStyle(.secondary) }
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: originalAspect ? .fit : .fill)
                    .frame(width: artworkSize.width, height: artworkSize.height).clipped()
                    .id(ObjectIdentifier(image)).transition(.opacity)
            }
        }
        .frame(width: artworkSize.width, height: artworkSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
        }
        .anchorPreference(key: QueueArtworkReflectionKey.self, value: .bounds) { bounds in
            guard current && visible, let image else { return nil }
            return QueueArtworkReflection(itemID: itemID, bounds: bounds, image: image)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: current && visible && image != nil)
        .scaleEffect(pressed && image != nil && !reduceMotion ? 0.91 : 1)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.35), value: pressed)
        .accessibilityHidden(true)
    }
}

/// All list artwork uses the same local-cover / online-poster / frame precedence as summaries.
private struct ResolvedQueueArtwork: View {
    let path: String
    let itemID: Int64
    let image: NSImage?
    let current: Bool
    let visible: Bool
    var artworkSize: CGSize = CGSize(width: 76, height: 44)
    var originalAspect = false
    @ObservedObject private var library = OnlineMovieLibrary.shared
    @StateObject private var online = OnlineSummaryArtwork()
    var body: some View {
        let url = library.movie(for: path)?.posterURL
        let poster = online.image(for: path, url: url)
        let waiting = online.awaitingImage(path: path, url: url)
        let resolved = poster ?? (waiting ? nil : image)
        let ratio = resolved.map { max(0.05, $0.size.width / max(1, $0.size.height)) } ?? 1
        let size = originalAspect && poster != nil ? CGSize(width: min(120, 180 * ratio), height: min(180, 120 / ratio)) : artworkSize
        QueueArtwork(itemID: itemID, image: resolved, current: current, visible: visible,
                     artworkSize: size, originalAspect: originalAspect || poster != nil)
            .task(id: "\(path)|\(visible)|\(library.searchRevision)") {
                guard visible, path.hasPrefix("/") else { return }
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                await library.validate(path, prefetchPoster: false)
                guard !Task.isCancelled else { return }
                await online.load(path: path, url: library.movie(for: path)?.posterURL)
            }
            .onReceive(NotificationCenter.default.publisher(for: .mediaCoverDidChange)) { note in
                guard let changed = note.object as? String, changed == path, visible else { return }
                Task { await online.load(path: path, url: library.movie(for: path)?.posterURL) }
            }
    }
}

private struct OnlineSearchHint: View {
    let path: String
    let query: String
    @ObservedObject private var library = OnlineMovieLibrary.shared
    var body: some View {
        Group {
            if let hint = library.movie(for: path)?.searchHint(query) {
                Text(hint).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(hint)
            }
        }.task(id: "\(path)|\(query.isEmpty)|\(library.searchRevision)") {
            guard !query.isEmpty else { return }
            await library.validate(path, prefetchPoster: false)
        }
    }
}

private struct QueueRowPresentation: Equatable {
    let detailed: Bool
    let paused: Bool
    let duration: Double
    let canPlayNext: Bool
    let remote: Bool
    let remoteDeferred: Bool
    let remoteRevision: UInt64
}

private struct QueueRow: View, @MainActor Equatable {
    @Environment(\.displayScale) private var displayScale
    let model: PlayerModel
    let presentation: QueueRowPresentation
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.item == rhs.item &&
        lhs.metadataActive == rhs.metadataActive && lhs.presentation == rhs.presentation && lhs.searchQuery == rhs.searchQuery
    }
    let item: QueueItem
    let metadataActive: Bool
    var searchQuery = ""
    var onRequestDelete: (QueueItem) -> Void
    @State private var metadata = QueueMetadata()
    @State private var coverImage: NSImage? = nil
    @State private var metadataPath = ""
    @State private var rowVisible = false
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 10) {
            Button { model.playQueueItem(item.id) } label: {
                HStack(spacing: 10) {
                    if presentation.detailed {
                        ResolvedQueueArtwork(path: item.filename, itemID: item.id, image: coverImage, current: item.current,
                                     visible: metadataActive && rowVisible)
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .transition(.opacity)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            PlayerSymbol(name: presentation.paused ? "pause.fill" : "play.fill")
                                .font(.caption2).foregroundStyle(.tint)
                                .frame(width: 10).opacity(item.current ? 1 : 0)
                                .accessibilityHidden(true)
                            Text(item.title).lineLimit(2)
                                .fontWeight(item.current ? .semibold : .regular)
                                .shadow(color: .primary.opacity(hovered ? 0.35 : 0), radius: 2)
                        }
                        HStack {
                            Text(durationText).monospacedDigit()
                            if presentation.detailed {
                                Text("·")
                                Text(metadata.size.map(SharedByteCountFormatter.format) ?? "N/A")
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                        if !searchQuery.isEmpty { OnlineSearchHint(path: item.filename, query: searchQuery) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(QueuePressStyle()).help(item.title)
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
            Button { model.removeQueueItem(item.id) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).accessibilityLabel("Remove \(item.title) from queue")
                .opacity(item.current ? 0 : 1).disabled(item.current)
                .accessibilityHidden(item.current)
        }
        .padding(.vertical, 9)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: item.current)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: presentation.detailed)
        .accessibilityValue(item.current ? (presentation.paused ? String(localized: "Current item, paused") : String(localized: "Now playing")) : "")
        .contextMenu {
            Button {
                model.playQueueItem(item.id)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            Button {
                model.playNextQueueItem(item.id)
            } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            .disabled(!presentation.canPlayNext)
            Divider()
            Button {
                model.revealInFileBrowser(path: item.filename)
            } label: {
                Label("Show in File Browser", systemImage: "sidebar.leading")
            }.disabled(!model.canRevealInFileBrowser(path: item.filename))
            Button {
                model.showInFinder(path: item.filename)
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }.disabled(!item.filename.hasPrefix("/"))
            if item.filename.hasPrefix("/") {
                ShareLink(item: URL(fileURLWithPath: item.filename),
                          preview: SharePreview(item.title)) {
                    Label("Share File…", systemImage: "square.and.arrow.up")
                }
            }
            Divider()
            Button {
                model.removeQueueItem(item.id)
            } label: {
                Label("Remove from Queue", systemImage: "minus.circle")
            }
            Button(role: .destructive) {
                onRequestDelete(item)
            } label: {
                Label("Delete File…", systemImage: "trash")
            }.disabled(!item.filename.hasPrefix("/"))
        }
        .onScrollVisibilityChange(threshold: 0.01) { rowVisible = $0 }
        .onDisappear { rowVisible = false }
        .task(id: metadataTaskKey) {
            await loadQueueItemMetadata()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaCoverDidChange)) { note in
            handleCoverDidChange(note)
        }
    }

    private var metadataTaskKey: String {
        let remotePart = presentation.remote ? "\(presentation.remoteDeferred)|\(presentation.remoteRevision)" : ""
        return "\(item.filename)|\(presentation.detailed)|\(metadataActive && rowVisible)|\(remotePart)"
    }

    private func handleCoverDidChange(_ note: Notification) {
        guard let changedPath = note.object as? String else { return }
        let isMatch = changedPath == item.filename ||
            URL(fileURLWithPath: changedPath).standardizedFileURL.path == URL(fileURLWithPath: item.filename).standardizedFileURL.path
        guard isMatch, presentation.detailed,
              let cached = ThumbnailImageCache.shared.lookup(item.filename),
              let img = cached.image else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            coverImage = img
        }
    }

    private func loadQueueItemMetadata() async {
        let detailed = presentation.detailed
        if metadataPath != item.filename {
            metadataPath = item.filename
            if let cached = ThumbnailImageCache.shared.lookup(item.filename) {
                metadata = QueueMetadata(duration: cached.duration, size: cached.size ?? model.remoteEntries[item.filename]?.item.size)
                coverImage = detailed ? cached.image : nil
            } else {
                metadata = QueueMetadata(size: model.remoteEntries[item.filename]?.item.size)
                coverImage = nil
            }
        } else if !detailed && coverImage != nil {
            coverImage = nil
        } else if detailed && coverImage == nil, let cached = ThumbnailImageCache.shared.lookup(item.filename), let img = cached.image {
            coverImage = img
        }
        if metadata.duration != nil && (!detailed || coverImage != nil) { return }
        guard metadataActive && rowVisible else { return }
        do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
        for attempt in 0..<3 {
            if attempt > 0 {
                do { try await Task.sleep(for: .seconds(31)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            let result: QueueMetadata
            if let remote = model.remoteEntries[item.filename] {
                result = await model.remoteMetadata.read(remote, cover: detailed, allowLoad: !model.remoteMetadataDeferred,
                                                         priorityRevision: model.metadataPriorityRevision)
            } else { result = await QueueMetadataCache.shared.read(item.filename, cover: detailed) }
            guard !Task.isCancelled else { return }
            let nextCover = result.cover ?? metadata.cover
            var decodedImage: NSImage? = coverImage
            if detailed, decodedImage == nil, let data = nextCover {
                decodedImage = await ThumbnailDecoder.shared.decode(data, maxPixels: 512, pixelSize: CGSize(width: 76 * displayScale, height: 44 * displayScale))
            }
            guard !Task.isCancelled else { return }
            metadata = QueueMetadata(duration: result.duration ?? metadata.duration,
                size: result.size ?? metadata.size, cover: nextCover)
            ThumbnailImageCache.shared.store(key: item.filename, image: decodedImage, duration: metadata.duration, size: metadata.size)
            if detailed {
                if coverImage !== decodedImage {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { coverImage = decodedImage }
                }
            } else if coverImage != nil {
                coverImage = nil
            }
            if metadata.duration != nil && (!detailed || coverImage != nil) { return }
            if model.remoteEntries[item.filename] != nil && model.remoteMetadataDeferred { return }
        }
    }
    private var durationText: String {
        guard let value = item.current && presentation.duration > 0 ? presentation.duration : metadata.duration,
              value.isFinite, value >= 0 else { return "N/A" }
        let seconds = Int(min(value, Double(Int32.max)))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct QueueView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var onlineLibrary = OnlineMovieLibrary.shared
    @State private var onlineSearchLoading = false
    @State private var onlineSearchIndex: [String: String] = [:]
    @State private var onlineSearchRevision: UInt64 = 0
    @ObservedObject var model: PlayerModel
    var metadataActive = true
    @State private var pendingDeleteItem: QueueItem? = nil
    @State private var query = ""
    @State private var showSearch = false
    @State private var selection: Set<Int64> = []
    @FocusState private var searchFocused: Bool

    private var visibleQueue: [QueueItem] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return model.queue }
        return model.queue.filter { item in
            words.allSatisfy { item.title.localizedStandardContains($0) || item.filename.localizedStandardContains($0) || (onlineLibrary.enabled && onlineSearchRevision == onlineLibrary.searchRevision && onlineSearchIndex[item.filename]?.localizedStandardContains($0) == true) }
        }
    }

    private var preferredPopoverHeight: CGFloat {
        let windowHeight = model.window?.contentLayoutRect.height
            ?? model.window?.frame.height
            ?? (NSScreen.main?.visibleFrame.height ?? 820)
        let maxAvailableHeight = max(240, min(580, windowHeight - 140))

        var chromeHeight: CGFloat = 54
        if showSearch || !query.isEmpty { chromeHeight += 38 }
        if selection.count > 1 { chromeHeight += 32 }
        if !model.folderQueueStatus.isEmpty { chromeHeight += 24 }

        let filteredCount = visibleQueue.count
        if model.queue.isEmpty || filteredCount == 0 {
            return min(maxAvailableHeight, max(200, chromeHeight + 166))
        }
        let rowHeight: CGFloat = model.queueDetailed ? 66 : 50
        let contentHeight = chromeHeight + CGFloat(filteredCount) * rowHeight + 18
        return min(maxAvailableHeight, max(180, contentHeight))
    }

    var body: some View {
        // Resolve the insertion neighbour once, rather than scanning the queue
        // twice per row whenever a player property changes.
        let currentIndex = model.queue.firstIndex(where: \.current)
        let nextIndex = currentIndex.map { $0 + 1 } ?? 0
        let nextID = model.queue.indices.contains(nextIndex) ? model.queue[nextIndex].id : nil
        let filtered = visibleQueue
        let hasInactive = model.queue.contains(where: { !$0.current })
        VStack(spacing: 0) {
            HStack {
                Text("Play Queue").font(.headline)
                Text("\(model.queue.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.queue.count)
                    .accessibilityLabel("\(model.queue.count) queued items")
                Spacer()
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                        showSearch.toggle()
                        if showSearch { searchFocused = true }
                        else { query = "" }
                    }
                } label: {
                    Image(systemName: showSearch || !query.isEmpty ? "magnifyingglass.circle.fill" : "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .disabled(model.queue.isEmpty && query.isEmpty)
                .help("Search Play Queue")
                Menu {
                    Picker("Sort", selection: $model.queueSort) {
                        Label("Custom / Added Order", systemImage: "line.3.horizontal").tag("custom")
                        Label("Filename", systemImage: "textformat.abc").tag("name")
                        Label("Date Created · Oldest First", systemImage: "calendar").tag("created")
                    }
                    Picker("Display", selection: $model.queueDetailed) {
                        Label("Title & Duration", systemImage: "list.bullet").tag(false)
                        Label("Cover, Title, Duration & Size", systemImage: "photo.on.rectangle").tag(true)
                    }
                    Divider()
                    Toggle(isOn: $model.autoQueueFolder) {
                        Label("Add Media from the Same Folder", systemImage: "folder.badge.plus")
                    }
                    Button {
                        model.scanCurrentMediaFolder()
                    } label: {
                        Label("Scan Current Folder", systemImage: "arrow.clockwise")
                    }
                    .disabled(!model.autoQueueFolder || (!model.path.hasPrefix("/") && model.remoteEntries[model.path] == nil))
                    Divider()
                    Button {
                        model.clearInactiveQueueItems()
                        selection.removeAll()
                    } label: {
                        Label("Remove Other Items", systemImage: "minus.circle")
                    }
                    .disabled(!hasInactive)
                    Button(role: .destructive) {
                        model.clearPlayQueue()
                        selection.removeAll()
                    } label: {
                        Label("Clear Play Queue", systemImage: "trash")
                    }
                    .disabled(model.queue.isEmpty)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28, height: 24)
                .help("Queue sorting and appearance")
                Button { model.queuePopover = false; openWindow(id: "player"); model.openPanel(append: true) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add Files…")
            }.padding()
            if showSearch || !query.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                    TextField("Search Play Queue", text: $query)
                        .textInputBorderShape(.capsule)
                        .controlSize(.small)
                        .focused($searchFocused)
                        .onKeyPress(.escape) {
                            if !query.isEmpty { query = ""; return .handled }
                            showSearch = false; return .handled
                        }
                    if !query.isEmpty {
                        Button("Clear Search", systemImage: "xmark.circle.fill") {
                            query = ""; searchFocused = true
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            if selection.count > 1 {
                HStack(spacing: 8) {
                    Text("\(selection.count) selected")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Play Next", systemImage: "text.insert") {
                        model.playNextQueueItems(Array(selection))
                        selection.removeAll()
                    }
                    .controlSize(.small)
                    Button("Remove", systemImage: "minus.circle") {
                        model.removeQueueItems(selection)
                        selection.removeAll()
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            if !model.folderQueueStatus.isEmpty { Text(model.folderQueueStatus).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.bottom, 6) }
            if model.queue.isEmpty {
                ContentUnavailableView("No Media Queued", systemImage: "list.bullet", description: Text("Open video or audio files to build your queue."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty && onlineSearchLoading {
                ProgressView("Searching local information…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                ContentUnavailableView("No matching files", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(filtered) { item in
                        QueueRow(model: model, presentation: QueueRowPresentation(
                            detailed: model.queueDetailed, paused: item.current && model.paused,
                            duration: item.current ? model.duration : 0,
                            canPlayNext: !item.current && item.id != nextID,
                            remote: model.remoteEntries[item.filename] != nil,
                            remoteDeferred: model.remoteEntries[item.filename] != nil && model.remoteMetadataDeferred,
                            remoteRevision: model.remoteEntries[item.filename] != nil ? model.metadataPriorityRevision : 0),
                            item: item, metadataActive: metadataActive, searchQuery: query) { target in
                            pendingDeleteItem = target
                        }
                        .equatable()
                        .id(item.id)
                        .tag(item.id)
                        .listRowBackground(Color.clear)
                        .moveDisabled(model.queueSort != "custom" || !query.isEmpty)
                    }.onMove { model.moveQueueItems(from: $0, to: $1) }
                }
                .listStyle(.sidebar).scrollContentBackground(.hidden)
                .modifier(ArtworkReflectionLayer())
                .task(id: metadataActive) {
                    guard metadataActive, query.isEmpty, let id = model.queue.first(where: \.current)?.id else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
                .onChange(of: model.queue.map(\.id)) { _, liveIDs in
                    selection.formIntersection(Set(liveIDs))
                }
                }
            }
        }
                .task(id: "online-search|\(metadataActive)|\(query.isEmpty)|\(onlineLibrary.searchRevision)|\(model.queue.map(\.filename).joined(separator: "|"))") {
                    guard metadataActive, !query.isEmpty, onlineLibrary.enabled else { onlineSearchIndex = [:]; onlineSearchLoading = false; return }
                    onlineSearchLoading = true
                    defer { if !Task.isCancelled { onlineSearchLoading = false } }
                    do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
                    let index = await onlineLibrary.searchIndex(paths: model.queue.map(\.filename))
                    guard !Task.isCancelled else { return }
                    onlineSearchIndex = index
                    onlineSearchRevision = onlineLibrary.searchRevision
                }
        .frame(width: 360, height: preferredPopoverHeight, alignment: .top)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: preferredPopoverHeight)
        .confirmationDialog(
            "Delete \"\(pendingDeleteItem?.title ?? "File")\"?",
            isPresented: Binding(get: { pendingDeleteItem != nil }, set: { if !$0 { pendingDeleteItem = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeleteItem
        ) { item in
            Button("Move to Trash", role: .destructive) {
                pendingDeleteItem = nil
                model.deleteQueueFile(item)
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteItem = nil
            }
        } message: { item in
            Text("The file \"\(URL(fileURLWithPath: item.filename).lastPathComponent)\" will be removed from the play queue and moved to the Trash.")
        }
    }
}


private struct QueueArtworkPressedKey: EnvironmentKey {
    static let defaultValue = false
}
private extension EnvironmentValues {
    var queueArtworkPressed: Bool {
        get { self[QueueArtworkPressedKey.self] }
        set { self[QueueArtworkPressedKey.self] = newValue }
    }
}
private struct QueuePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.queueArtworkPressed, configuration.isPressed)
    }
}

// MARK: - NFO Metadata Parser & Cache (Kodi / Jellyfin / Emby / Plex Compatible)

struct MediaNFOMetadata: Equatable, Sendable {
    var title: String = ""
    var originalTitle: String = ""
    var year: String = ""
    var rating: Double? = nil
    var mpaa: String = ""
    var runtimeMinutes: Int? = nil
    var directors: [String] = []
    var actors: [String] = []
    var genres: [String] = []
    var tags: [String] = []
    var studio: String = ""
    var plot: String = ""

    var hasContent: Bool {
        !title.isEmpty || !originalTitle.isEmpty || !year.isEmpty || rating != nil ||
        !directors.isEmpty || !actors.isEmpty || !genres.isEmpty || !tags.isEmpty || !plot.isEmpty
    }

    var searchableText: String {
        ([title, originalTitle, year, mpaa, studio, plot] + directors + actors + genres + tags)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

private final class NFOXMLDelegate: NSObject, XMLParserDelegate {
    var result = MediaNFOMetadata()
    private var elementStack: [String] = []
    private var currentText = ""
    private var currentActorName = ""
    private var currentActorRole = ""
    private var currentRatingValue = ""
    private var currentRatingDefault = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let lower = elementName.lowercased()
        elementStack.append(lower)
        currentText = ""
        if lower == "actor" {
            currentActorName = ""
            currentActorRole = ""
        } else if lower == "rating" && elementStack.contains("ratings") {
            currentRatingValue = ""
            currentRatingDefault = (attributeDict["default"]?.lowercased() == "true")
        }
        if elementStack.count > 24 { parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let lower = elementName.lowercased()
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = elementStack.dropLast().last ?? ""

        if parent == "actor" {
            if lower == "name", !trimmed.isEmpty {
                currentActorName = trimmed
            } else if lower == "role", !trimmed.isEmpty {
                currentActorRole = trimmed
            }
        } else if lower == "actor" {
            if !currentActorName.isEmpty && result.actors.count < 16 {
                if !result.actors.contains(currentActorName) {
                    result.actors.append(currentActorName)
                }
            }
        } else if parent == "rating" && elementStack.contains("ratings") {
            if lower == "value", !trimmed.isEmpty {
                currentRatingValue = trimmed
            }
        } else if lower == "rating" && elementStack.contains("ratings") {
            if let val = Double(currentRatingValue), val > 0, val <= 10.0 {
                if result.rating == nil || currentRatingDefault {
                    result.rating = val
                }
            }
        } else if elementStack.count <= 2 {
            switch lower {
            case "title":
                if !trimmed.isEmpty && result.title.isEmpty { result.title = trimmed }
            case "originaltitle":
                if !trimmed.isEmpty && result.originalTitle.isEmpty { result.originalTitle = trimmed }
            case "year":
                if !trimmed.isEmpty && result.year.isEmpty { result.year = String(trimmed.prefix(4)) }
            case "premiered", "releasedate", "aired":
                if result.year.isEmpty, trimmed.count >= 4 {
                    let prefix4 = String(trimmed.prefix(4))
                    if Int(prefix4) != nil { result.year = prefix4 }
                }
            case "rating":
                if result.rating == nil, let val = Double(trimmed), val > 0, val <= 10.0 {
                    result.rating = val
                }
            case "mpaa", "certification":
                if !trimmed.isEmpty && result.mpaa.isEmpty { result.mpaa = trimmed }
            case "runtime":
                if result.runtimeMinutes == nil {
                    let digits = trimmed.prefix { $0.isNumber }
                    if let mins = Int(digits), mins > 0 { result.runtimeMinutes = mins }
                }
            case "director":
                for part in Self.splitList(trimmed) where !result.directors.contains(part) && result.directors.count < 8 {
                    result.directors.append(part)
                }
            case "genre":
                for part in Self.splitList(trimmed) where !result.genres.contains(part) && result.genres.count < 12 {
                    result.genres.append(part)
                }
            case "tag":
                for part in Self.splitList(trimmed) where !result.tags.contains(part) && result.tags.count < 16 {
                    result.tags.append(part)
                }
            case "studio":
                if !trimmed.isEmpty && result.studio.isEmpty { result.studio = trimmed }
            case "plot":
                if !trimmed.isEmpty { result.plot = trimmed }
            case "outline", "tagline":
                if !trimmed.isEmpty && result.plot.isEmpty { result.plot = trimmed }
            default:
                break
            }
        }

        if !elementStack.isEmpty { elementStack.removeLast() }
        currentText = ""
    }

    static func splitList(_ raw: String) -> [String] {
        guard !raw.isEmpty else { return [] }
        return raw
            .split(whereSeparator: { $0 == "/" || $0 == "," || $0 == "、" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

enum NFOParser {
    static func parse(_ data: Data) -> MediaNFOMetadata? {
        guard !data.isEmpty, data.count <= 1_048_576 else { return nil }
        if data.range(of: Data("<!DOCTYPE".utf8)) != nil { return nil }
        let delegate = NFOXMLDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        if parser.parse(), delegate.result.hasContent {
            return delegate.result
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return delegate.result.hasContent ? delegate.result : nil
        }
        var fallback = delegate.result
        func firstTag(_ tag: String) -> String {
            guard let range = text.range(of: "<\(tag)[^>]*>(.*?)</\(tag)>", options: [.regularExpression, .caseInsensitive]) else {
                return ""
            }
            let match = String(text[range])
            guard let openEnd = match.firstIndex(of: ">"),
                  let closeStart = match.range(of: "</", options: .backwards)?.lowerBound,
                  openEnd < closeStart else { return "" }
            return String(match[match.index(after: openEnd)..<closeStart])
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func allTags(_ tag: String, limit: Int = 12) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: "<\(tag)[^>]*>([\\s\\S]*?)</\(tag)>", options: [.caseInsensitive]) else {
                return []
            }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            var values: [String] = []
            for match in regex.matches(in: text, range: nsRange) {
                guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { continue }
                let raw = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                for item in NFOXMLDelegate.splitList(raw) where !values.contains(item) {
                    values.append(item)
                    if values.count >= limit { return values }
                }
            }
            return values
        }
        if fallback.title.isEmpty { fallback.title = firstTag("title") }
        if fallback.originalTitle.isEmpty { fallback.originalTitle = firstTag("originaltitle") }
        if fallback.year.isEmpty {
            let y = firstTag("year")
            if !y.isEmpty { fallback.year = String(y.prefix(4)) }
            else {
                let p = firstTag("premiered")
                if p.count >= 4, Int(p.prefix(4)) != nil { fallback.year = String(p.prefix(4)) }
            }
        }
        if fallback.rating == nil {
            let rStr = firstTag("rating")
            if let r = Double(rStr), r > 0, r <= 10.0 { fallback.rating = r }
            else if let v = Double(firstTag("value")), v > 0, v <= 10.0 { fallback.rating = v }
        }
        if fallback.directors.isEmpty { fallback.directors = allTags("director", limit: 8) }
        if fallback.genres.isEmpty { fallback.genres = allTags("genre", limit: 12) }
        if fallback.tags.isEmpty { fallback.tags = allTags("tag", limit: 16) }
        if fallback.actors.isEmpty {
            if let actorRegex = try? NSRegularExpression(pattern: "<actor[\\s\\S]*?<name>([\\s\\S]*?)</name>[\\s\\S]*?</actor>", options: [.caseInsensitive]) {
                let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
                for match in actorRegex.matches(in: text, range: nsRange) {
                    if match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) {
                        let name = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty && !fallback.actors.contains(name) && fallback.actors.count < 16 {
                            fallback.actors.append(name)
                        }
                    }
                }
            }
        }
        if fallback.plot.isEmpty {
            let p = firstTag("plot")
            fallback.plot = !p.isEmpty ? p : firstTag("outline")
        }
        return fallback.hasContent ? fallback : nil
    }

    static func serialize(_ metadata: MediaNFOMetadata, rootElement: String = "movie") -> Data {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&apos;")
        }
        var lines: [String] = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>",
            "<\(rootElement)>"
        ]
        if !metadata.title.isEmpty {
            lines.append("    <title>\(escape(metadata.title))</title>")
        }
        if !metadata.originalTitle.isEmpty {
            lines.append("    <originaltitle>\(escape(metadata.originalTitle))</originaltitle>")
        }
        if !metadata.year.isEmpty {
            lines.append("    <year>\(escape(metadata.year))</year>")
        }
        if let rating = metadata.rating, rating > 0 {
            lines.append(String(format: "    <rating>%.1f</rating>", rating))
        }
        if !metadata.mpaa.isEmpty {
            lines.append("    <mpaa>\(escape(metadata.mpaa))</mpaa>")
        }
        if let mins = metadata.runtimeMinutes, mins > 0 {
            lines.append("    <runtime>\(mins)</runtime>")
        }
        if !metadata.studio.isEmpty {
            lines.append("    <studio>\(escape(metadata.studio))</studio>")
        }
        if !metadata.plot.isEmpty {
            lines.append("    <plot>\(escape(metadata.plot))</plot>")
        }
        for director in metadata.directors where !director.isEmpty {
            lines.append("    <director>\(escape(director))</director>")
        }
        for genre in metadata.genres where !genre.isEmpty {
            lines.append("    <genre>\(escape(genre))</genre>")
        }
        for tag in metadata.tags where !tag.isEmpty {
            lines.append("    <tag>\(escape(tag))</tag>")
        }
        for actor in metadata.actors where !actor.isEmpty {
            lines.append("    <actor>")
            lines.append("        <name>\(escape(actor))</name>")
            lines.append("    </actor>")
        }
        lines.append("</\(rootElement)>\n")
        return Data(lines.joined(separator: "\n").utf8)
    }
}

extension Notification.Name {
    static let mediaNFODidChange = Notification.Name("IIVEPlayerMediaNFODidChange")
    static let mediaCoverDidChange = Notification.Name("IIVEPlayerMediaCoverDidChange")
    static let browserSearchCurrentFolder = Notification.Name("IIVEPlayerBrowserSearchCurrentFolder")
    static let browserRevealMediaItem = Notification.Name("IIVEPlayerBrowserRevealMediaItem")
}

actor MediaNFOCache {
    static let shared = MediaNFOCache()
    struct LocalSnapshot: Sendable {
        let nfoURL: URL?
        let showNFOURL: URL?
        let contents: Data?
        let modification: Date?
        let metadata: MediaNFOMetadata?
    }
    private var localReads: [String: Task<LocalSnapshot, Never>] = [:]

    /// Coalesce simultaneous card/sidebar reads, but revalidate on the next request.
    /// Keep the original bytes and timestamp for conflict-safe editing.
    func localSnapshot(for path: String) async -> LocalSnapshot {
        if let pending = localReads[path] { return await pending.value }
        let task = Task.detached(priority: .utility) {
            let file = URL(fileURLWithPath: path)
            let item = Self.locateLocalNFO(for: file, isFolder: false)
            let folder = Self.locateLocalNFO(for: file.deletingLastPathComponent(), isFolder: true)
            let modification = item.flatMap {
                try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
            let contents = item.flatMap { Self.readLocalNFO($0) }
            var metadata = contents.flatMap { NFOParser.parse($0) }
            if let folder, folder != item, let inherited = Self.indexedLocalMetadata(folder) {
                if metadata == nil { metadata = inherited }
                else {
                    if metadata?.genres.isEmpty == true { metadata?.genres = inherited.genres }
                    if metadata?.tags.isEmpty == true { metadata?.tags = inherited.tags }
                    if metadata?.studio.isEmpty == true { metadata?.studio = inherited.studio }
                    if metadata?.actors.isEmpty == true { metadata?.actors = inherited.actors }
                }
            }
            return LocalSnapshot(nfoURL: item, showNFOURL: folder, contents: contents,
                                 modification: modification, metadata: metadata)
        }
        localReads[path] = task
        let snapshot = await task.value
        localReads[path] = nil
        return snapshot
    }

    private static let syncLock = NSLock()
    private nonisolated(unsafe) static var syncCache: [String: MediaNFOMetadata?] = [:]
    private nonisolated(unsafe) static var syncOrder: [String] = []

    nonisolated func lookup(_ key: String) -> (found: Bool, value: MediaNFOMetadata?) {
        Self.syncLock.lock()
        defer { Self.syncLock.unlock() }
        if let entry = Self.syncCache[key] {
            return (true, entry)
        }
        return (false, nil)
    }

    nonisolated func store(_ key: String, value: MediaNFOMetadata?) {
        Self.syncLock.lock()
        defer { Self.syncLock.unlock() }
        Self.syncCache[key] = .some(value)
        Self.syncOrder.removeAll { $0 == key }
        Self.syncOrder.append(key)
        while Self.syncOrder.count > 400 {
            let oldest = Self.syncOrder.removeFirst()
            Self.syncCache.removeValue(forKey: oldest)
        }
    }

    nonisolated func invalidateLocalPath(_ path: String) {
        Self.syncLock.lock()
        defer { Self.syncLock.unlock() }
        let keys = Self.syncOrder.filter { $0 == path || $0.hasPrefix(path + "/") }
        for key in keys { Self.syncCache.removeValue(forKey: key) }
        Self.syncOrder.removeAll { keys.contains($0) }
    }

    @discardableResult
    func saveLocalMetadata(_ metadata: MediaNFOMetadata, forMediaPath path: String, preferredNFOURL: URL? = nil, expectedModification: Date? = nil, expectedContents: Data? = nil, expectsMissing: Bool = false) throws -> URL {
        let mediaURL = URL(fileURLWithPath: path)
        let targetURL = preferredNFOURL
            ?? Self.locateLocalNFO(for: mediaURL, isFolder: false)
            ?? mediaURL.deletingPathExtension().appendingPathExtension("nfo")
        guard targetURL.isFileURL, targetURL.pathExtension.lowercased() == "nfo" else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if let expectedModification {
            let actual = try FileManager.default.attributesOfItem(atPath: targetURL.path)[.modificationDate] as? Date
            guard actual == expectedModification else { throw CocoaError(.fileWriteFileExists) }
        }
        if expectsMissing && FileManager.default.fileExists(atPath: targetURL.path) {
            throw CocoaError(.fileWriteFileExists)
        }
        if let expectedContents {
            guard try Data(contentsOf: targetURL) == expectedContents else { throw CocoaError(.fileWriteFileExists) }
        }
        var originalContents: Data?
        var xmlData = NFOParser.serialize(metadata)
        if FileManager.default.fileExists(atPath: targetURL.path) {
            let size = try FileManager.default.attributesOfItem(atPath: targetURL.path)[.size] as? NSNumber
            guard let size, size.intValue <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
            let original = try Data(contentsOf: targetURL)
            originalContents = original
            guard original.count <= 1_048_576,
                  original.range(of: Data("<!DOCTYPE".utf8)) == nil,
                  let previous = NFOParser.parse(original) else { throw CocoaError(.fileReadCorruptFile) }
            let document = try XMLDocument(data: original, options: [.nodeLoadExternalEntitiesNever])
            guard let root = document.rootElement() else { throw CocoaError(.fileReadCorruptFile) }
            let before = try XMLDocument(data: NFOParser.serialize(previous), options: [])
            let after = try XMLDocument(data: xmlData, options: [])
            for name in ["title", "originaltitle", "year", "rating", "mpaa", "runtime", "studio", "plot", "director", "genre", "tag", "actor"] {
                let old = before.rootElement()?.elements(forName: name) ?? []
                let new = after.rootElement()?.elements(forName: name) ?? []
                guard old.map(\.xmlString) != new.map(\.xmlString) else { continue }
                for element in root.elements(forName: name) { element.detach() }
                for element in new { root.addChild(element.copy() as! XMLNode) }
                if name == "rating" {
                    // Kodi's nested ratings take precedence over its legacy rating field.
                    let ratings = root.elements(forName: "ratings").flatMap { $0.elements(forName: "rating") }
                    if let primary = ratings.first(where: { $0.attribute(forName: "default")?.stringValue == "true" }) ?? ratings.first {
                        primary.elements(forName: "value").first?.stringValue = metadata.rating.map { String($0) } ?? "0"
                    }
                }
            }
            xmlData = document.xmlData(options: [.nodePrettyPrint])
            let backup = targetURL.appendingPathExtension("luma-backup")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.copyItem(at: targetURL, to: backup)
            }
        }
        // Recheck after XML merging/backup creation; never overwrite a newer edit.
        if let originalContents {
            guard try Data(contentsOf: targetURL) == originalContents else { throw CocoaError(.fileWriteFileExists) }
            try xmlData.write(to: targetURL, options: .atomic)
        } else {
            try xmlData.write(to: targetURL, options: .withoutOverwriting)
        }
        store(path, value: metadata)
        store(targetURL.path, value: metadata)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .mediaNFODidChange, object: path)
        }
        return targetURL
    }

    @discardableResult
    func applyCoverAndSaveNFO(
        forMediaPath path: String,
        coverFileName: String,
        fallbackTitle: String,
        rawMetadata: [String: String]
    ) throws -> URL {
        let mediaURL = URL(fileURLWithPath: path)
        let defaultNFOURL = mediaURL.deletingPathExtension().appendingPathExtension("nfo")
        let existingLocated = Self.locateLocalNFO(for: mediaURL, isFolder: false)
        // Prefer the media-specific <basename>.nfo when creating or updating a video's cover.
        let targetURL: URL = {
            if let existingLocated,
               existingLocated.deletingLastPathComponent().standardizedFileURL == mediaURL.deletingLastPathComponent().standardizedFileURL,
               existingLocated.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(mediaURL.deletingPathExtension().lastPathComponent) == .orderedSame {
                return existingLocated
            }
            return defaultNFOURL
        }()

        var tags: [String: String] = [:]
        for (k, v) in rawMetadata { tags[k.lowercased()] = v }
        func rawTag(_ keys: String...) -> String {
            keys.compactMap { tags[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
        }
        func splitRaw(_ value: String) -> [String] {
            value.components(separatedBy: CharacterSet(charactersIn: "/,;|"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        let resolvedFallbackTitle: String = {
            let t = rawTag("title")
            if !t.isEmpty { return t }
            let cleaned = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return cleaned }
            return mediaURL.deletingPathExtension().lastPathComponent
        }()

        let document: XMLDocument
        var parsedMetadata: MediaNFOMetadata

        if FileManager.default.fileExists(atPath: targetURL.path),
           let existingData = Self.readLocalNFO(targetURL),
           existingData.range(of: Data("<!DOCTYPE".utf8)) == nil,
           let existingDoc = try? XMLDocument(data: existingData, options: [.nodeLoadExternalEntitiesNever]),
           let root = existingDoc.rootElement() {
            document = existingDoc
            parsedMetadata = NFOParser.parse(existingData) ?? MediaNFOMetadata()
            if parsedMetadata.title.isEmpty {
                parsedMetadata.title = resolvedFallbackTitle
                if root.elements(forName: "title").isEmpty {
                    root.addChild(XMLElement(name: "title", stringValue: resolvedFallbackTitle))
                }
            }
            // Update or insert <thumb aspect="poster"> and <cover>
            let existingThumbs = root.elements(forName: "thumb")
            let posterThumbs = existingThumbs.filter {
                let aspect = $0.attribute(forName: "aspect")?.stringValue?.lowercased()
                return aspect == nil || aspect == "poster"
            }
            if let firstPoster = posterThumbs.first {
                firstPoster.stringValue = coverFileName
                if firstPoster.attribute(forName: "aspect") == nil {
                    firstPoster.addAttribute(XMLNode.attribute(withName: "aspect", stringValue: "poster") as! XMLNode)
                }
            } else {
                let thumbElem = XMLElement(name: "thumb", stringValue: coverFileName)
                thumbElem.addAttribute(XMLNode.attribute(withName: "aspect", stringValue: "poster") as! XMLNode)
                root.addChild(thumbElem)
            }
        } else {
            var info = (existingLocated.flatMap { Self.readLocalNFO($0) }.flatMap { NFOParser.parse($0) }) ?? MediaNFOMetadata()
            if info.title.isEmpty { info.title = resolvedFallbackTitle }
            if info.originalTitle.isEmpty { info.originalTitle = rawTag("originaltitle", "original_title") }
            if info.year.isEmpty {
                let y = String(rawTag("year", "date", "creation_time").prefix(4))
                if Int(y) != nil { info.year = y }
            }
            if info.mpaa.isEmpty { info.mpaa = rawTag("mpaa", "content_rating", "parental_rating") }
            if info.studio.isEmpty { info.studio = rawTag("studio", "publisher") }
            if info.plot.isEmpty { info.plot = rawTag("synopsis", "description", "comment") }
            if info.directors.isEmpty { info.directors = splitRaw(rawTag("director")) }
            if info.actors.isEmpty { info.actors = splitRaw(rawTag("actors", "cast", "artist")) }
            if info.genres.isEmpty { info.genres = splitRaw(rawTag("genre")) }
            if info.tags.isEmpty { info.tags = splitRaw(rawTag("keywords", "tags")) }

            parsedMetadata = info
            let baseXML = NFOParser.serialize(info)
            document = try XMLDocument(data: baseXML, options: [.nodeLoadExternalEntitiesNever])
            if let root = document.rootElement() {
                let thumbElem = XMLElement(name: "thumb", stringValue: coverFileName)
                thumbElem.addAttribute(XMLNode.attribute(withName: "aspect", stringValue: "poster") as! XMLNode)
                root.addChild(thumbElem)
            }
        }

        let xmlData = document.xmlData(options: [.nodePrettyPrint])
        try xmlData.write(to: targetURL, options: .atomic)
        Self.clearFileIndex()
        invalidateLocalPath(path)
        store(path, value: parsedMetadata)
        store(mediaURL.standardizedFileURL.path, value: parsedMetadata)
        store(targetURL.path, value: parsedMetadata)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .mediaNFODidChange, object: path)
        }
        return targetURL
    }

    func metadata(for key: String, localMediaURL: URL?, nfoURL: URL?, isFolder: Bool, credentials: NetworkServerCredentials?) async -> MediaNFOMetadata? {
        let cached = lookup(key)
        if cached.found && nfoURL?.isFileURL != true && localMediaURL?.isFileURL != true {
            return cached.value
        }
        let parsed: MediaNFOMetadata?
        if let nfoURL {
            if nfoURL.isFileURL {
                parsed = await Task.detached(priority: .utility) {
                    return Self.indexedLocalMetadata(nfoURL)
                }.value
            } else if let credentials {
                parsed = await fetchRemoteNFO(url: nfoURL, credentials: credentials)
            } else {
                parsed = nil
            }
        } else if let localMediaURL, localMediaURL.isFileURL {
            parsed = await Task.detached(priority: .utility) {
                guard let candidate = Self.locateLocalNFO(for: localMediaURL, isFolder: isFolder) else { return nil }
                return Self.indexedLocalMetadata(candidate)
            }.value
        } else {
            parsed = nil
        }
        guard !Task.isCancelled else { return parsed }
        store(key, value: parsed)
        return parsed
    }

    private struct ParsedFile { let modified: Date?; let size: Int64; let metadata: MediaNFOMetadata? }
    private nonisolated(unsafe) static var parsedFiles: [URL: ParsedFile] = [:]
    nonisolated static func indexedLocalMetadata(_ url: URL) -> MediaNFOMetadata? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let fileSize: Int64?
        let modified: Date?
        if let sz = values?.fileSize {
            fileSize = Int64(sz)
            modified = values?.contentModificationDate
        } else if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let sz = attrs[.size] as? NSNumber {
            fileSize = sz.int64Value
            modified = attrs[.modificationDate] as? Date
        } else {
            return nil
        }
        guard let validSize = fileSize, validSize <= 1_048_576 else { return nil }
        syncLock.lock(); let old = parsedFiles[url]; syncLock.unlock()
        if let old, old.modified == modified, old.size == validSize { return old.metadata }
        let metadata = (try? Data(contentsOf: url, options: .mappedIfSafe)).flatMap { NFOParser.parse($0) }
        syncLock.lock()
        if parsedFiles.count >= 400 { parsedFiles.removeAll() }
        parsedFiles[url] = ParsedFile(modified: modified, size: validSize, metadata: metadata)
        syncLock.unlock()
        return metadata
    }
    nonisolated static func clearFileIndex() { syncLock.lock(); parsedFiles.removeAll(); syncLock.unlock() }

    nonisolated static func readLocalNFO(_ url: URL) -> Data? {
        if let sz = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            guard sz <= 1_048_576 else { return nil }
        } else {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
                  size.intValue <= 1_048_576 else { return nil }
        }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    nonisolated static func locateLocalNFO(for url: URL, isFolder: Bool) -> URL? {
        let fm = FileManager.default
        if isFolder {
            for name in ["tvshow.nfo", "movie.nfo", "\(url.lastPathComponent).nfo"] {
                let candidate = url.appendingPathComponent(name)
                if fm.isReadableFile(atPath: candidate.path) { return candidate }
            }
            return nil
        }
        let exact = url.deletingPathExtension().appendingPathExtension("nfo")
        if fm.isReadableFile(atPath: exact.path) { return exact }
        let dir = url.deletingLastPathComponent()
        let baseLower = url.deletingPathExtension().lastPathComponent.lowercased()
        if let siblings = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            if let match = siblings.first(where: {
                $0.pathExtension.lowercased() == "nfo" &&
                $0.deletingPathExtension().lastPathComponent.lowercased() == baseLower
            }) {
                return match
            }
            let movieNFO = dir.appendingPathComponent("movie.nfo")
            if fm.isReadableFile(atPath: movieNFO.path) {
                let videoCount = siblings.filter { FolderMedia.extensions.contains($0.pathExtension.lowercased()) }.count
                if videoCount <= 2 { return movieNFO }
            }
        }
        return nil
    }

    private func fetchRemoteNFO(url: URL, credentials: NetworkServerCredentials) async -> MediaNFOMetadata? {
        let config = NetworkRequestPolicy.configuration(remaining: 8)
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        if let auth = try? NetworkMediaRequest.authorization(username: credentials.username, password: credentials.password) {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 524_288 else { return nil }
                data.append(byte)
            }
            return NFOParser.parse(data)
        } catch {
            return nil
        }
    }
}

private enum SharedByteCountFormatter {
    private static let lock = NSLock()
    private nonisolated(unsafe) static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
    nonisolated static func format(_ bytes: Int64) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(fromByteCount: bytes)
    }
}

/// Directory membership cache with kernel-level bulk URL resource property prefetch.
private enum BrowserDirectoryIndex {
    private struct Snapshot { let modified: Date?; let expires: Date; let files: [URL] }
    private static let lock = NSLock()
    private static let prefetchKeys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .fileSizeKey,
        .contentModificationDateKey, .isSymbolicLinkKey, .isPackageKey
    ]
    nonisolated(unsafe) private static var cache: [URL: Snapshot] = [:]
    nonisolated static func files(_ directory: URL) -> [URL] {
        let modified = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? ((try? FileManager.default.attributesOfItem(atPath: directory.path)[.modificationDate]) as? Date)
        lock.lock()
        let old = cache[directory]
        lock.unlock()
        if let old, old.modified == modified, old.expires > Date() { return old.files }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: prefetchKeys,
            options: [.skipsHiddenFiles]) else { return [] }
        lock.lock()
        // Bound both directory count and retained URL count.
        if cache.count >= 128 || cache.values.reduce(0, { $0 + $1.files.count }) + files.count > 20_000 { cache.removeAll() }
        if files.count <= 20_000 { cache[directory] = Snapshot(modified: modified, expires: Date().addingTimeInterval(30), files: files) }
        lock.unlock()
        return files
    }
    nonisolated static func clear() { lock.lock(); cache.removeAll(); lock.unlock() }
}

private actor BrowserFolderSummary {
    static let shared = BrowserFolderSummary()
    private struct Cached { let modified: Date?; let expires: Date; let text: String }
    private var cache: [URL: Cached] = [:]
    func count(_ url: URL) -> String? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        if let old = cache[url], old.modified == modified, old.expires > Date() { return old.text }
        guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]) else { return nil }
        var count = 0, visited = 0
        for case let item as URL in items {
            guard !Task.isCancelled else { return nil }
            visited += 1
            if visited > 10_000 { break }
            if FolderMedia.extensions.contains(item.pathExtension.lowercased()),
               (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { count += 1 }
        }
        let text = visited > 10_000 ? String(localized: "At least \(count) media files") : String(localized: "\(count) media files")
        if cache.count >= 128 { cache.removeAll(keepingCapacity: true) }
        cache[url] = Cached(modified: modified, expires: Date().addingTimeInterval(30), text: text)
        return text
    }
}

private struct BrowserEntry: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let name: String
    let folder: Bool
    let size: Int64?
    let webDAVItem: WebDAVItem?
    var nfoURL: URL? = nil
    var relativeFolder: String? = nil
    var created: Date? = nil
    var modified: Date? = nil
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.url == rhs.url && lhs.name == rhs.name &&
        lhs.folder == rhs.folder && lhs.size == rhs.size &&
        lhs.nfoURL == rhs.nfoURL && lhs.relativeFolder == rhs.relativeFolder &&
        lhs.created == rhs.created && lhs.modified == rhs.modified
    }
}

private struct BrowserStack: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let entries: [BrowserEntry]

    nonisolated static func build(_ entries: [BrowserEntry], enabled: Bool) -> [BrowserStack] {
        guard enabled else { return entries.map { BrowserStack(id: $0.id, title: $0.name, entries: [$0]) } }
        let patterns = [#"(?i)^(.+?)[ ._-]+((?:s[0-9]{1,2})?(?:episode|ep|e)[ ._-]*[0-9]{1,3})(.*)$"#,
                        #"^(.+?)[ ._-]+([0-9]{1,3})([ ._-]+[^0-9].*)?$"#]
        let regexes = patterns.compactMap { try? NSRegularExpression(pattern: $0) }
        var keys: [String] = [], buckets: [String: [BrowserEntry]] = [:], titles: [String: String] = [:]
        for entry in entries {
            var key = entry.id, title = entry.name
            if !entry.folder {
                let stem = entry.url.deletingPathExtension().lastPathComponent
                let ns = stem as NSString
                if let episode = MovieFilenameQuery.episode(entry.url.lastPathComponent) {
                    let year = MovieFilenameQuery.parse(entry.url.lastPathComponent).year ?? ""
                    let prefix = episode.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                    key = "series:" + entry.url.deletingLastPathComponent().absoluteString + "|" + prefix + "|" + year
                    title = episode.title
                }
                for regex in regexes where key == entry.id {
                    guard let match = regex.firstMatch(in: stem, range: NSRange(location: 0, length: ns.length)) else { continue }
                    let prefix = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                    guard prefix.count >= 2 else { continue }
                    let suffix = match.range(at: 3).location == NSNotFound ? "" : ns.substring(with: match.range(at: 3))
                    key = "series:" + entry.url.deletingLastPathComponent().absoluteString + "|" + prefix.lowercased() + "|" + suffix.lowercased() + "|" + entry.url.pathExtension.lowercased()
                    title = prefix
                    break
                }
            }
            if buckets[key] == nil { keys.append(key); titles[key] = title }
            buckets[key, default: []].append(entry)
        }
        return keys.map { key in
            let items = buckets[key]!
            return BrowserStack(id: items.count > 1 ? key : items[0].id,
                                title: items.count > 1 ? titles[key]! : items[0].name, entries: items)
        }
    }
}

private struct BrowserMediaSection: Identifiable, Equatable, Sendable {
    let id: String
    let folderName: String?
    let folderEntry: BrowserEntry?
    let stacks: [BrowserStack]
    let mediaEntries: [BrowserEntry]
}

private struct BrowserSubfolderSectionHeader: View {
    let title: String
    let itemCount: Int
    let isPlayingInSection: Bool
    let isPaused: Bool
    let canShowInFinder: Bool
    let onOpenFolder: (() -> Void)?
    let onPlaySection: () -> Void
    let onEnqueueSection: (Bool) -> Void
    let onShowInFinder: (() -> Void)?
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Button {
                (onOpenFolder ?? onPlaySection)()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tint)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(itemCount)")
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(.primary.opacity(0.08), in: Capsule())
                    if isPlayingInSection {
                        Image(systemName: isPaused ? "pause.fill" : "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(onOpenFolder != nil ? String(localized: "Open Folder") : title)

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                Button(action: onPlaySection) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Play Folder")

                Button {
                    onEnqueueSection(false)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Add Folder to Queue")

                if let onOpenFolder {
                    Button(action: onOpenFolder) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Open Folder")
                }
            }
            .opacity(hovered ? 1.0 : 0.65)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(hovered ? 0.07 : 0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
        .padding(.top, 6)
        .padding(.bottom, 2)
        .onHover { value in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                hovered = value
            }
        }
        .contextMenu {
            Button(action: onPlaySection) {
                Label("Play Folder", systemImage: "play.fill")
            }
            Button {
                onEnqueueSection(true)
            } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            Button {
                onEnqueueSection(false)
            } label: {
                Label("Add Folder to Queue", systemImage: "plus")
            }
            if let onOpenFolder {
                Divider()
                Button(action: onOpenFolder) {
                    Label("Open Folder", systemImage: "folder")
                }
            }
            if canShowInFinder, let onShowInFinder {
                Button(action: onShowInFinder) {
                    Label("Show in Finder", systemImage: "folder.badge.gearshape")
                }
            }
        }
    }
}

private struct BrowserScrollingKey: EnvironmentKey {
    static let defaultValue = false
}
private extension EnvironmentValues {
    var browserScrolling: Bool {
        get { self[BrowserScrollingKey.self] }
        set { self[BrowserScrollingKey.self] = newValue }
    }
}

private struct StackArtworkNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}
private extension EnvironmentValues {
    var stackArtworkNamespace: Namespace.ID? {
        get { self[StackArtworkNamespaceKey.self] }
        set { self[StackArtworkNamespaceKey.self] = newValue }
    }
}
private struct StackArtworkMatch: ViewModifier {
    let id: String
    @Environment(\.stackArtworkNamespace) private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder func body(content: Content) -> some View {
        if let namespace, !reduceMotion {
            content.matchedGeometryEffect(id: id, in: namespace)
        } else { content }
    }
}

private struct BrowserStackRow<Rows: View>: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.browserScrolling) private var scrolling
    let stack: BrowserStack
    @Binding var expanded: Bool
    let detailed: Bool
    let active: Bool
    let model: PlayerModel
    let credentials: NetworkServerCredentials?
    let remoteDeferred: Bool
    let remoteRevision: UInt64
    @ViewBuilder let rows: () -> Rows
    @Namespace private var artworkNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var rowsMounted = false
    @State private var images: [String: NSImage] = [:]
    @State private var durations: [String: Double] = [:]
    @State private var finished = false
    @State private var contentStamps: [String: String] = [:]
    private func contentStamp(_ entry: BrowserEntry) -> String {
        "\(entry.size ?? -1)|\(entry.modified?.timeIntervalSince1970 ?? -1)"
    }
    private var stackContentIdentity: String {
        stack.entries.map { $0.id + "|" + contentStamp($0) }.joined(separator: "|")
    }
    @ObservedObject private var onlineLibrary = OnlineMovieLibrary.shared
    private var seriesSummary: OnlineSeriesSummary? {
        OnlineSeriesSummary.resolve(stack.entries.prefix(128).compactMap {
            $0.url.isFileURL ? onlineLibrary.movie(for: $0.url.path) : nil
        })
    }

    private var totalText: String {
        guard !durations.isEmpty else { return finished ? "N/A" : String(localized: "Reading duration…") }
        let total = durations.values.reduce(0, +)
        let seconds = Int(min(total, Double(Int32.max)))
        let text = String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        return durations.count == stack.entries.count ? text : String(localized: "\(text) · Partial \(durations.count)/\(stack.entries.count)")
    }

    var body: some View {
        let series = seriesSummary
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.42, bounce: 0.08)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        if !expanded, detailed, let poster = series?.posterURL {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7).fill(.quaternary)
                                    .frame(width: 32, height: 44).rotationEffect(.degrees(-8)).offset(x: -6, y: -2)
                                OnlineMoviePoster(url: poster).frame(width: 34, height: 50)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }.frame(width: 84, height: 50)
                        } else if expanded {
                            Image(systemName: "rectangle.stack").foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(stack.entries.prefix(3).enumerated().reversed()), id: \.element.id) { index, entry in
                                ZStack {
                                    RoundedRectangle(cornerRadius: 7).fill(.quaternary)
                                    if let image = images[entry.id] {
                                        Image(nsImage: image).resizable().scaledToFill()
                                    } else {
                                        Image(systemName: "play.rectangle").foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: detailed ? 76 : 22, height: detailed ? 44 : 18)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5) }
                                .modifier(StackArtworkMatch(id: entry.id))
                                .scaleEffect(1 - Double(index) * 0.055)
                                .rotationEffect(.degrees(Double(index) * -3))
                                .offset(x: Double(index) * 3, y: Double(index) * -2)
                                .zIndex(Double(3 - index))
                            }
                        }
                    }
                    .frame(width: detailed ? 84 : 22, height: detailed ? 50 : 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(series?.title ?? stack.title).fontWeight(.medium).lineLimit(1).help(series?.title ?? stack.title)
                        HStack(spacing: 5) {
                            Text("\(stack.entries.count) items")
                                .contentTransition(.numericText())
                            Text("·")
                            Text(totalText).monospacedDigit().lineLimit(1)
                                .contentTransition(.numericText())
                        }.font(.caption).foregroundStyle(.secondary)
                        if let series, !series.details.isEmpty {
                            Text(series.details).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).help(series.details)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12, height: 12)
                        .foregroundStyle(.secondary)
                }
                .frame(height: detailed ? 60 : 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
            if expanded || rowsMounted {
            ExpandableDrawerLayout(progress: expanded ? 1.0 : 0.0) {
                VStack(alignment: .leading, spacing: 4) {
                    rows()
                }
                .padding(.top, 2)
                .opacity(expanded ? 1.0 : 0.0)
            }
            .clipped()
            .allowsHitTesting(expanded)
            .accessibilityHidden(!expanded)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(expanded ? Color.primary.opacity(0.05) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(expanded ? Color.primary.opacity(0.08) : Color.clear, lineWidth: 0.5)
                )
        )
        .environment(\.stackArtworkNamespace, reduceMotion || !detailed ? nil : artworkNamespace)
        .task(id: expanded) {
            if expanded { rowsMounted = true; return }
            if !reduceMotion {
                do { try await Task.sleep(for: .milliseconds(420)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            rowsMounted = false
        }
        .task(id: "online-stack|\(active && visible && !scrolling)|\(onlineLibrary.enabled)|\(stackContentIdentity)") {
            guard active, visible, !scrolling, onlineLibrary.enabled else { return }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            for entry in stack.entries.prefix(128) where entry.url.isFileURL {
                guard !Task.isCancelled else { return }
                await onlineLibrary.validate(entry.url.path, prefetchPoster: false)
            }
        }
        .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
        .onDisappear { visible = false }
        .task(id: "\(active && visible && !scrolling)|\(expanded)|\(detailed)|\(series?.posterURL?.absoluteString ?? "")|\(remoteDeferred)|\(remoteRevision)|\(stackContentIdentity)") {
            guard active, visible, !scrolling else { return }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            finished = false
            let nextStamps = Dictionary(uniqueKeysWithValues: stack.entries.map { ($0.id, contentStamp($0)) })
            let unchanged = Set(nextStamps.keys.filter { contentStamps[$0] == nextStamps[$0] })
            let changed = Set(nextStamps.keys.filter { contentStamps[$0] != nil && contentStamps[$0] != nextStamps[$0] })
            durations = durations.filter { unchanged.contains($0.key) }
            images = images.filter { unchanged.contains($0.key) }
            contentStamps = nextStamps
            for entry in stack.entries.prefix(3) where !changed.contains(entry.id) {
                if let cached = ThumbnailImageCache.shared.lookup(entry.id) { images[entry.id] = cached.image }
            }
            var collectedDurations = durations
            var lastPublication = ContinuousClock.now
            // Reuse completed work after scroll cancellation. Expanded stacks let
            // their child rows request artwork; an online series poster needs none.
            for (index, entry) in stack.entries.prefix(128).enumerated() {
                guard !Task.isCancelled else { return }
                let cover = detailed && !expanded && series?.posterURL == nil && index < 3 && images[entry.id] == nil
                if collectedDurations[entry.id] != nil && !cover { continue }
                // Give visible artwork a head start before long stack duration scans.
                if index == 3 {
                    do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                }
                let metadata: QueueMetadata
                if let item = entry.webDAVItem, let credentials {
                    let remote = RemoteQueueEntry(key: "browser-dav://" + item.id, item: item, origin: .webDAV(credentials))
                    metadata = await model.remoteMetadata.read(remote, cover: cover, allowLoad: !remoteDeferred, priorityRevision: remoteRevision, priority: cover ? .visible : .background)
                } else if entry.url.isFileURL {
                    metadata = await QueueMetadataCache.shared.read(entry.url.path, cover: cover, priority: cover ? .visible : .background)
                } else { continue }
                guard !Task.isCancelled else { return }
                if let duration = metadata.duration, duration.isFinite, duration >= 0 {
                    collectedDurations[entry.id] = duration
                }
                if index < 3 || lastPublication.duration(to: .now) >= .milliseconds(200) {
                    if durations != collectedDurations { durations = collectedDurations }
                    lastPublication = .now
                }
                if cover, let data = metadata.cover {
                    let image = await ThumbnailDecoder.shared.decode(data, maxPixels: 512, pixelSize: CGSize(width: 76 * displayScale, height: 44 * displayScale))
                    guard !Task.isCancelled else { return }
                    images[entry.id] = image
                    ThumbnailImageCache.shared.store(key: entry.id, image: image, duration: metadata.duration, size: metadata.size)
                }
            }
            if durations != collectedDurations { durations = collectedDurations }
            finished = true
        }
    }
}

private struct BrowserTagSummary: Identifiable, Equatable, Sendable {
    var id: String { key }
    let key: String
    let display: String
    let count: Int
}

/// Preserve artwork aspect ratio, with a bounded height for tall posters.
struct MediaDetailCover: View {
    let image: NSImage
    var maximumHeight: CGFloat = 420
    var cornerRadius: CGFloat = 10
    var body: some View {
        MediaCoverLayout(ratio: max(0.01, image.size.width / max(1, image.size.height)), maximumHeight: maximumHeight) {
            Image(nsImage: image).resizable().scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityLabel("Media artwork")
    }
}
private struct MediaCoverLayout: Layout {
    let ratio: CGFloat
    let maximumHeight: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(0, proposal.width ?? 320)
        return CGSize(width: width, height: min(maximumHeight, width / ratio))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                             proposal: ProposedViewSize(bounds.size))
    }
}

private struct BrowserEntryDetailCard: View {
    let entry: BrowserEntry
    let nfo: MediaNFOMetadata?
    let loadingNFO: Bool
    let durationText: String
    let sizeText: String?
    let subtitleSummary: String
    let onPlay: () -> Void
    let onEnqueue: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            if let nfo, nfo.hasContent {
                VStack(alignment: .leading, spacing: 3) {
                    if !nfo.title.isEmpty {
                        Text(nfo.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !nfo.originalTitle.isEmpty && nfo.originalTitle != nfo.title {
                        Text(nfo.originalTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 6) {
                    if !nfo.year.isEmpty {
                        badge(nfo.year, icon: "calendar")
                    }
                    if let rating = nfo.rating {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.yellow)
                            Text(String(format: "%.1f", rating))
                                .font(.caption2.monospacedDigit().weight(.semibold))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.yellow.opacity(0.16), in: Capsule())
                    }
                    if !nfo.mpaa.isEmpty {
                        badge(nfo.mpaa, icon: nil)
                    }
                    if let mins = nfo.runtimeMinutes {
                        badge(String(localized: "\(mins) min"), icon: "clock")
                    }
                }

                let combinedChips = (nfo.genres.map { ("genre", $0) } + nfo.tags.map { ("tag", $0) }).prefix(8)
                if !combinedChips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(Array(combinedChips.enumerated()), id: \.offset) { _, chip in
                                Text(chip.1)
                                    .font(.caption2)
                                    .foregroundStyle(chip.0 == "genre" ? .primary : .secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2.5)
                                    .background(
                                        chip.0 == "genre"
                                            ? Color.accentColor.opacity(0.22)
                                            : Color.primary.opacity(0.08),
                                        in: Capsule()
                                    )
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    if !nfo.directors.isEmpty {
                        detailField(label: String(localized: "Director"), value: nfo.directors.joined(separator: " / "))
                    }
                    if !nfo.actors.isEmpty {
                        detailField(label: String(localized: "Cast"), value: nfo.actors.prefix(8).joined(separator: " · "))
                    }
                    if !nfo.studio.isEmpty {
                        detailField(label: String(localized: "Studio"), value: nfo.studio)
                    }
                }

                if !nfo.plot.isEmpty {
                    Text(nfo.plot)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            } else if loadingNFO {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Reading metadata…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        if durationText != "N/A" {
                            badge(durationText, icon: "clock")
                        }
                        if let sizeText {
                            badge(sizeText, icon: "internaldrive")
                        }
                        badge(entry.url.pathExtension.uppercased(), icon: nil)
                    }
                }
            }

            if !entry.folder {
                Label(subtitleSummary, systemImage: "captions.bubble")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button(action: onPlay) {
                        Label("Play", systemImage: "play.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button { onEnqueue(true) } label: {
                        Label("Play Next", systemImage: "text.insert")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button { onEnqueue(false) } label: {
                        Label("Queue", systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, 2)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private func badge(_ text: String, icon: String?) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9))
            }
            Text(text)
                .font(.caption2.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.primary.opacity(0.08), in: Capsule())
    }

    private func detailField(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(.caption2)
                .foregroundStyle(.primary.opacity(0.9))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ExpandableDrawerLayout: Layout {
    struct Cache {
        var width: CGFloat?
        var natural: CGSize?
    }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }
    private func naturalSize(width: CGFloat?, subview: LayoutSubview, cache: inout Cache) -> CGSize {
        if cache.width == width, let size = cache.natural { return size }
        let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
        cache.width = width
        cache.natural = size
        return size
    }
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let clamped = min(1.0, max(0.0, progress))
        guard clamped > 0.0001 else {
            return CGSize(width: proposal.width ?? 0, height: 0)
        }
        let natural = naturalSize(width: proposal.width, subview: subview, cache: &cache)
        return CGSize(width: proposal.width ?? natural.width, height: natural.height * clamped)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard let subview = subviews.first else { return }
        let natural = naturalSize(width: bounds.width, subview: subview, cache: &cache)
        subview.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: natural.height)
        )
    }
}

private struct BrowserEntryRow: View, @MainActor Equatable {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.browserScrolling) private var scrolling
    @State private var detailMounted = false
    let duration: Double
    let remoteDeferred: Bool
    let remoteRevision: UInt64
    let browserRevision: Int
    var searchQuery = ""
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.entry == rhs.entry && lhs.detailed == rhs.detailed &&
        lhs.active == rhs.active && lhs.isCurrent == rhs.isCurrent &&
        lhs.isQueued == rhs.isQueued && lhs.isHighlighted == rhs.isHighlighted &&
        lhs.showsRelativeFolder == rhs.showsRelativeFolder && lhs.isExpanded == rhs.isExpanded &&
        lhs.webDAVCredentials == rhs.webDAVCredentials && lhs.duration == rhs.duration &&
        lhs.remoteDeferred == rhs.remoteDeferred && lhs.remoteRevision == rhs.remoteRevision &&
        lhs.browserRevision == rhs.browserRevision && lhs.searchQuery == rhs.searchQuery
    }
    let model: PlayerModel
    let entry: BrowserEntry
    let detailed: Bool
    let active: Bool
    let isCurrent: Bool
    var isQueued: Bool = false
    var isHighlighted: Bool = false
    var showsRelativeFolder: Bool = true
    var isExpanded: Bool = false
    let webDAVCredentials: NetworkServerCredentials?
    var onSingleClick: (() -> Void)? = nil
    let onOpen: () -> Void
    let onPreview: () -> Void
    let onEnqueue: (Bool) -> Void
    var onPlayFolder: (() -> Void)? = nil
    var onEnqueueFolder: ((Bool) -> Void)? = nil
    var onRemoveFromQueue: (() -> Void)? = nil
    var onRename: (() -> Void)? = nil
    var onTrash: (() -> Void)? = nil

    @State private var subtitleSummary = String(localized: "Subtitles: Not checked")
    @State private var folderCount: String? = nil
    @State private var metadata = QueueMetadata()
    @State private var coverImage: NSImage? = nil
    @State private var detailArtwork: NSImage? = nil
    @State private var nfo: MediaNFOMetadata? = nil
    @State private var loadingNFO = false
    @State private var loadedKey = ""
    @State private var rowVisible = false
    @State private var hovered = false
    @State private var artworkHovered = false
    @State private var tapBounce = false
    @Environment(\.queueArtworkPressed) private var pressed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var metadataIdentity: String {
        "\(entry.id)|\(entry.modified?.timeIntervalSince1970 ?? 0)|\(entry.size ?? -1)|\(entry.nfoURL?.absoluteString ?? "")"
    }
    private var isCompressed: Bool { pressed || tapBounce }

    private func triggerTap(_ action: () -> Void) {
        if !reduceMotion && entry.folder {
            tapBounce = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(140))
                tapBounce = false
            }
        }
        action()
    }

    private var effectiveNFO: MediaNFOMetadata? {
        if let nfo { return nfo }
        let cached = MediaNFOCache.shared.lookup(entry.id)
        return cached.found ? cached.value : nil
    }

    private var displayTitle: String {
        if let info = effectiveNFO, !info.title.isEmpty {
            if !info.year.isEmpty && !info.title.contains(info.year) {
                return "\(info.title) (\(info.year))"
            }
            return info.title
        }
        return entry.name
    }

    private var rowArtworkSize: CGSize {
        guard isExpanded, let image = detailArtwork ?? coverImage else { return CGSize(width: 76, height: 44) }
        let ratio = max(0.05, image.size.width / max(1, image.size.height))
        let width = min(120, 180 * ratio)
        return CGSize(width: width, height: min(180, width / ratio))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                triggerTap(entry.folder ? onOpen : (onSingleClick ?? onOpen))
            } label: {
                HStack(spacing: 10) {
                    if detailed {
                        if entry.folder {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(.primary.opacity(0.06))
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(.tint)
                            }
                            .frame(width: 76, height: 44)
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                            }
                            .scaleEffect(isCompressed && !reduceMotion ? 0.94 : 1.0)
                            .animation(reduceMotion ? nil : .spring(duration: 0.34, bounce: 0.16), value: isCompressed)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 3)
                        } else {
                            ResolvedQueueArtwork(
                                path: entry.url.isFileURL ? entry.url.path : entry.id,
                                itemID: Int64(bitPattern: UInt64(truncatingIfNeeded: entry.id.hashValue)),
                                image: isExpanded ? (detailArtwork ?? coverImage) : coverImage,
                                current: isCurrent,
                                visible: active && rowVisible && !scrolling,
                                artworkSize: rowArtworkSize, originalAspect: isExpanded
                            )
                            .modifier(StackArtworkMatch(id: entry.id))
                            .scaleEffect(pressed && !reduceMotion ? 0.95 : 1.0)
                            .animation(reduceMotion ? nil : .spring(duration: 0.34, bounce: 0.16), value: pressed)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 3)
                        }
                    } else {
                        Image(systemName: entry.folder ? "folder.fill" : (isCurrent ? "play.fill" : (isQueued ? "text.badge.checkmark" : "play.rectangle")))
                            .foregroundStyle(entry.folder || isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .frame(width: 18)
                            .scaleEffect(pressed && !reduceMotion ? 0.92 : 1.0)
                            .animation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.14), value: pressed)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(displayTitle)
                                .lineLimit(2)
                                .fontWeight(isCurrent ? .semibold : .regular)
                                .shadow(color: .primary.opacity(hovered ? 0.35 : 0), radius: 2)
                            Spacer(minLength: 2)
                            if !entry.folder {
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                    .frame(width: 12, height: 12)
                            }
                        }
                        if !searchQuery.isEmpty { OnlineSearchHint(path: entry.url.isFileURL ? entry.url.path : entry.id, query: searchQuery) }
                        if detailed {
                            HStack(spacing: 4) {
                                if entry.folder {
                                    Text(folderCount ?? String(localized: "Folder"))
                                        .help("Media files directly inside this folder")
                                } else {
                                    if showsRelativeFolder, let rel = entry.relativeFolder, !rel.isEmpty {
                                        Image(systemName: "folder")
                                            .font(.system(size: 9))
                                        Text(rel)
                                            .lineLimit(1)
                                        Text("·")
                                    }
                                    if let rating = effectiveNFO?.rating {
                                        Text(String(format: "★ %.1f", rating))
                                            .foregroundStyle(.yellow.opacity(0.9))
                                        Text("·")
                                    }
                                    Text(durationText).monospacedDigit()
                                    if let sizeText {
                                        Text("·")
                                        Text(sizeText)
                                    }
                                    if isQueued && !isCurrent {
                                        Text("·")
                                        Image(systemName: "text.badge.checkmark")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.tint)
                                            .help("In Play Queue")
                                    }
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else if showsRelativeFolder, let rel = entry.relativeFolder, !rel.isEmpty, !entry.folder {
                            Text(rel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, detailed ? 5 : 4)
                .opacity(pressed ? 0.88 : 1.0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: pressed)
                .contentShape(Rectangle())
            }
            .buttonStyle(QueuePressStyle())
            .overlay(alignment: .topLeading) {
                if detailed && !entry.folder {
                    ZStack {
                        Color.clear.contentShape(Rectangle()).onTapGesture { (onSingleClick ?? onOpen)() }
                        if artworkHovered {
                            Button(action: onOpen) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .frame(width: 36, height: 36)
                                    .glassEffect(.regular.interactive(), in: Circle())
                            }
                            .buttonStyle(.plain).help("Play")
                            .accessibilityLabel("Play")
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        }
                    }
                    .frame(width: rowArtworkSize.width + 8, height: rowArtworkSize.height + 16)
                    .onHover { value in
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { artworkHovered = value }
                    }
                }
            }
            .help(entry.name)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)

            if !entry.folder && (isExpanded || detailMounted) {
                ExpandableDrawerLayout(progress: isExpanded ? 1.0 : 0.0) {
                    BrowserEntryDetailCard(
                        entry: entry,
                        nfo: effectiveNFO,
                        loadingNFO: loadingNFO && effectiveNFO == nil,
                        durationText: durationText,
                        sizeText: sizeText,
                        subtitleSummary: subtitleSummary,
                        onPlay: onOpen,
                        onEnqueue: onEnqueue
                    )
                    .padding(.horizontal, 4)
                    .opacity(isExpanded ? 1.0 : 0.0)
                    .offset(y: isExpanded ? 0 : -6)
                }
                .clipped()
                .allowsHitTesting(isExpanded)
                .accessibilityHidden(!isExpanded)
            }
        }
        // Keep outer padding invariant between collapsed and expanded states so the row header never jumps,
        // and never clip the outer row so the thumbnail glow radiates freely.
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isHighlighted
                        ? Color.accentColor.opacity(0.14)
                        : (isExpanded ? Color.primary.opacity(0.06) : (hovered ? Color.primary.opacity(0.03) : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isHighlighted
                                ? Color.accentColor.opacity(0.45)
                                : (isExpanded ? Color.primary.opacity(0.08) : Color.clear),
                            lineWidth: isHighlighted ? 1.0 : 0.5
                        )
                )
        )
        .animation(reduceMotion ? nil : .spring(duration: 0.38, bounce: 0.04), value: isExpanded)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: isHighlighted)
        .task(id: isExpanded) {
            if isExpanded { detailMounted = true; return }
            // Keep the outgoing content only for the collapse animation.
            if !reduceMotion {
                do { try await Task.sleep(for: .milliseconds(420)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            detailMounted = false
        }
        .task(id: "\(metadataIdentity)|\(active && rowVisible && !scrolling)|\(isExpanded)|\(metadata.subtitleCount ?? -1)") {
            guard active, !scrolling, rowVisible || isExpanded else { return }
            if !entry.url.isFileURL {
                if let count = metadata.subtitleCount {
                    subtitleSummary = String(localized: "Embedded subtitles: \(count) · External: Not checked")
                }
                return
            }
            if entry.folder {
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                folderCount = await BrowserFolderSummary.shared.count(entry.url)
            } else if isExpanded {
                let url = entry.url
                let sidecars = await Task.detached(priority: .utility) { FolderMedia.matchingSubtitles(for: url).all.count }.value
                guard !Task.isCancelled else { return }
                let asset = AVURLAsset(url: url)
                let unsupported = ["mkv", "webm", "avi", "ts", "m2ts"].contains(url.pathExtension.lowercased())
                let tracks = unsupported ? nil : try? await asset.loadTracks(withMediaType: .subtitle)
                guard !Task.isCancelled else { return }
                if let embedded = metadata.subtitleCount {
                    subtitleSummary = String(localized: "Embedded subtitles: \(embedded) · External: \(sidecars)")
                } else if let tracks {
                    subtitleSummary = String(localized: "Embedded subtitles: \(tracks.count) · External: \(sidecars)")
                } else {
                    subtitleSummary = String(localized: "External subtitles: \(sidecars) · Embedded: Not checked")
                }
            }
        }
        .task(id: "poster|\(metadataIdentity)|\(active && isExpanded && !scrolling)") {
            guard active, isExpanded, entry.url.isFileURL else { detailArtwork = nil; return }
            guard !scrolling else { return }
            let path = entry.url.path
            let image = await Task.detached(priority: .utility) { QueueMetadataCache.detailArtwork(path) }.value
            guard !Task.isCancelled else { return }
            detailArtwork = image
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaNFODidChange)) { note in
            handleBrowserNFODidChange(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaCoverDidChange)) { note in
            handleBrowserCoverDidChange(note)
        }
        .contextMenu {
            if let onRename { Button("Rename…", action: onRename) }
            if let onTrash { Button("Move to Trash", role: .destructive, action: onTrash) }
            if entry.folder {
                Button(action: onOpen) {
                    Label("Open Folder", systemImage: "folder")
                }
                if let onPlayFolder {
                    Button(action: onPlayFolder) {
                        Label("Play Folder", systemImage: "play.fill")
                    }
                }
                if let onEnqueueFolder {
                    Divider()
                    Button { onEnqueueFolder(true) } label: {
                        Label("Play Next", systemImage: "text.insert")
                    }
                    Button { onEnqueueFolder(false) } label: {
                        Label("Add Folder to Queue", systemImage: "plus")
                    }
                }
                if entry.webDAVItem == nil && entry.url.isFileURL {
                    Divider()
                    Button { model.showInFinder(path: entry.url.path) } label: {
                        Label("Show in Finder", systemImage: "folder.badge.gearshape")
                    }
                }
            } else {
                Button(action: onOpen) {
                    Label("Play", systemImage: "play.fill")
                }
                if let onSingleClick {
                    Button(action: onSingleClick) {
                        Label(isExpanded ? "Hide Details" : "Show Details", systemImage: "info.circle")
                    }
                }
                Divider()
                Button { onEnqueue(true) } label: {
                    Label("Play Next", systemImage: "text.insert")
                }
                Button { onEnqueue(false) } label: {
                    Label("Add to Play Queue", systemImage: "plus")
                }
                if isQueued && !isCurrent, let onRemoveFromQueue {
                    Button(action: onRemoveFromQueue) {
                        Label("Remove from Queue", systemImage: "minus.circle")
                    }
                }
                if entry.webDAVItem == nil && entry.url.isFileURL {
                    Divider()
                    Button("Quick Look", systemImage: "eye", action: onPreview)
                    ShareLink(item: entry.url, preview: SharePreview(entry.name)) {
                        Label("Share File…", systemImage: "square.and.arrow.up")
                    }
                    Button { model.showInFinder(path: entry.url.path) } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                }
            }
        }
        .onScrollVisibilityChange(threshold: 0.01) { rowVisible = $0 }
        .onDisappear { rowVisible = false }
        .task(id: "\(metadataIdentity)|\(isExpanded)|\(active && rowVisible && !scrolling)") {
            await loadBrowserRowNFO()
        }
        .task(id: "\(metadataIdentity)|\(detailed)|\(isExpanded)|\(active && rowVisible && !scrolling)|\(remoteDeferred)|\(remoteRevision)") {
            await loadRowMetadata()
        }
    }

    private func handleBrowserNFODidChange(_ note: Notification) {
        guard let changedPath = note.object as? String,
              changedPath == entry.id || changedPath == entry.url.path else { return }
        let cached = MediaNFOCache.shared.lookup(entry.id)
        if cached.found { nfo = cached.value }
    }

    private func handleBrowserCoverDidChange(_ note: Notification) {
        guard let changedPath = note.object as? String else { return }
        let isMatch = changedPath == entry.id ||
            changedPath == entry.url.path ||
            URL(fileURLWithPath: changedPath).standardizedFileURL == entry.url.standardizedFileURL
        guard isMatch else { return }
        if let cached = ThumbnailImageCache.shared.lookup(entry.id), let img = cached.image {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                coverImage = img
            }
        }
        if isExpanded, entry.url.isFileURL {
            let path = entry.url.path
            Task {
                let updatedPoster = await Task.detached(priority: .userInitiated) { QueueMetadataCache.detailArtwork(path) }.value
                await MainActor.run {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                        detailArtwork = updatedPoster
                    }
                }
            }
        }
    }

    private func loadBrowserRowNFO() async {
        guard !entry.folder, active, !scrolling, (rowVisible || isExpanded) else { return }
        let cached = MediaNFOCache.shared.lookup(entry.id)
        if cached.found {
            if nfo != cached.value { nfo = cached.value }
            loadingNFO = false
            return
        }
        if nfo == nil {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            loadingNFO = true
            let loaded = await MediaNFOCache.shared.metadata(
                for: entry.id,
                localMediaURL: entry.url.isFileURL ? entry.url : nil,
                nfoURL: entry.nfoURL,
                isFolder: entry.folder,
                credentials: webDAVCredentials
            )
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.36, bounce: 0.04)) {
                nfo = loaded
                loadingNFO = false
            }
        }
    }

    private func loadRowMetadata() async {
            guard !entry.folder else { return }
            let wantsCover = detailed || isExpanded
            if loadedKey != metadataIdentity {
                loadedKey = metadataIdentity
                let cachedNFO = MediaNFOCache.shared.lookup(entry.id)
                nfo = cachedNFO.found ? cachedNFO.value : nil
                if let cached = ThumbnailImageCache.shared.lookup(entry.id) {
                    metadata = QueueMetadata(duration: cached.duration, size: cached.size ?? entry.size)
                    coverImage = detailed ? cached.image : nil
                } else {
                    metadata = QueueMetadata(size: entry.size)
                    coverImage = nil
                }
            } else if !wantsCover && coverImage != nil {
                coverImage = nil
            } else if detailed && coverImage == nil, let cached = ThumbnailImageCache.shared.lookup(entry.id), let img = cached.image {
                coverImage = img
            }
            let wantsMetadata = detailed || isExpanded
            if metadata.duration != nil && (!wantsCover || coverImage != nil) && (!isExpanded || metadata.subtitleCount != nil) { return }
            guard wantsMetadata, active, !scrolling, (rowVisible || isExpanded) else { return }
            // Visibility tasks are cancelled as rows leave the viewport. Avoid starting
            // disk probes and decoder jobs for rows merely crossed during a fast scroll.
            do { try await Task.sleep(for: .milliseconds(isExpanded ? 0 : 120)) } catch { return }
            let result: QueueMetadata
            if let davItem = entry.webDAVItem, let creds = webDAVCredentials {
                let remoteEntry = RemoteQueueEntry(
                    key: "browser-dav://" + davItem.id,
                    item: davItem,
                    origin: .webDAV(creds)
                )
                result = await model.remoteMetadata.read(
                    remoteEntry,
                    cover: wantsCover,
                    allowLoad: !model.remoteMetadataDeferred,
                    priorityRevision: model.metadataPriorityRevision
                )
            } else if entry.url.isFileURL {
                result = await QueueMetadataCache.shared.read(entry.url.path, cover: wantsCover, priority: isExpanded ? .detail : .visible)
            } else {
                return
            }
            guard !Task.isCancelled else { return }
            let nextCover = result.cover ?? metadata.cover
            var decodedImage: NSImage? = coverImage
            if wantsCover, decodedImage == nil, let data = nextCover {
                decodedImage = await ThumbnailDecoder.shared.decode(data, maxPixels: 512, pixelSize: CGSize(width: rowArtworkSize.width * displayScale, height: rowArtworkSize.height * displayScale), priority: isExpanded ? .detail : .visible)
            }
            guard !Task.isCancelled else { return }
            let updatedDuration: Double? = result.duration ?? metadata.duration
            let cachedSize: Int64? = metadata.size ?? entry.size
            let updatedSize: Int64? = result.size ?? cachedSize
            metadata = QueueMetadata(duration: updatedDuration, size: updatedSize, cover: nextCover, subtitleCount: result.subtitleCount ?? metadata.subtitleCount)
            ThumbnailImageCache.shared.store(key: entry.id, image: decodedImage, duration: metadata.duration, size: metadata.size)
            if wantsCover, coverImage !== decodedImage {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    coverImage = decodedImage
                }
            }
    }

    private var sizeText: String? {
        guard let bytes = metadata.size ?? entry.size else { return nil }
        return SharedByteCountFormatter.format(bytes)
    }

    private var durationText: String {
        guard let value = (isCurrent && duration > 0) ? duration : metadata.duration,
              value.isFinite, value >= 0 else { return "N/A" }
        let seconds = Int(min(value, Double(Int32.max)))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Sidebar file browser supporting both Local Folders and WebDAV servers, with Compact List, Thumbnail view modes, and recursive NFO Tag Capsule filtering.
struct LocalMediaBrowser: View {
    @ObservedObject private var onlineLibrary = OnlineMovieLibrary.shared
    let model: PlayerModel
    @StateObject private var observation = SidebarModelObservation()
    var active: Bool
    private let servers = NetworkServerStore.shared
    @AppStorage("fileBrowserDetailed") private var detailedView = true
    @State private var selectedServerID: UUID? = nil // nil == Local Files
    @State private var directory: URL? = nil
    @State private var davFolder: URL? = nil
    @State private var davRootPath = "/"
    @State private var davCredentials: NetworkServerCredentials? = nil
    @State private var entries: [BrowserEntry] = []
    @State private var secondLevelMediaEntries: [BrowserEntry] = []
    @State private var subtreeMediaEntries: [BrowserEntry] = []
    @State private var availableTags: [BrowserTagSummary] = []
    @State private var entryTagsByID: [String: Set<String>] = [:]
    @State private var entrySearchIndexByID: [String: String] = [:]
    @State private var onlineSearchLoading = false
    @State private var onlineSearchIndex: [String: String] = [:]
    @State private var onlineSearchRevision: UInt64 = 0
    @State private var onlinePoolRevision = 0
    @State private var indexedPoolRevision = -1
    @State private var selectedTags: Set<String> = []
    @State private var expandedEntryID: String? = nil
    @State private var query = ""
    @State private var settledQuery = ""
    @State private var pendingSearchQuery: String? = nil
    @State private var pendingRevealEntryID: String? = nil
    @State private var highlightedEntryID: String? = nil
    @State private var highlightDismissTask: Task<Void, Never>? = nil
    @State private var showSearch = false
    @State private var failure = ""
    @State private var loading = false
    @State private var reloadToken = UUID()
    @State private var directoryWatcher = BrowserDirectoryWatcher()
    @State private var directoryRefreshPending = false
    @State private var loadedLocation = ""
    @State private var refreshing = false
    @AppStorage("browserSort") private var sortOrder = "name"
    @AppStorage("browserStackEpisodes") private var stackEpisodes = false
    @AppStorage("browserExpandSubfolders") private var expandSubfolders = false
    @State private var displayedStacks: [BrowserStack] = []
    @State private var displayedSections: [BrowserMediaSection] = []
    @State private var quickLookURL: URL?
    @State private var browserScrolling = false
    @State private var expandedStacks: Set<String> = []
    @State private var editingFile: URL? = nil
    @State private var newFilename = ""
    @State private var trashFile: URL? = nil
    @State private var fileBusy = false
    @State private var tagRefresh = 0
    @State private var displayedEntries: [BrowserEntry] = []
    @State private var browserRevision = 0
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func refreshDisplayedEntries() {
        // Coalesce changes into a cancellable SwiftUI task; never sort in body.
        browserRevision &+= 1
    }

    private var activeMediaMetadataText: (path: String, text: String)? {
        guard !model.path.isEmpty, let raw = model.snapshot["metadata"] as? [String: String], !raw.isEmpty else { return nil }
        return (model.path, raw.values.joined(separator: "\n"))
    }

    private func updateDisplayedEntries() async {
        guard active else { return }
        let entries = entries
        let secondLevel = secondLevelMediaEntries
        let subtree = subtreeMediaEntries
        let tags = entryTagsByID
        var searchIndex = entrySearchIndexByID
        if !settledQuery.isEmpty, onlineLibrary.enabled,
           onlineSearchRevision == onlineLibrary.searchRevision, indexedPoolRevision == onlinePoolRevision {
            let pool = entries + secondLevel + subtree
            let online = onlineSearchIndex
            var indexedIDs: Set<String> = []
            for entry in pool {
                guard indexedIDs.insert(entry.id).inserted, let text = online[entry.url.path] else { continue }
                let local = searchIndex[entry.id] ?? MediaNFOCache.shared.lookup(entry.id).value?.searchableText ?? ""
                searchIndex[entry.id] = local + "\n" + text
            }
        }
        let combinedSearchIndex = searchIndex
        let activeMeta = activeMediaMetadataText
        let selection = selectedTags
        let query = settledQuery
        let order = sortOrder
        let stacking = stackEpisodes
        let expandSubs = expandSubfolders
        let rootFolderTitle = currentTitle

        let work = Task.detached(priority: .userInitiated) { () -> ([BrowserEntry], [BrowserStack], [BrowserMediaSection])? in
            if expandSubs && !secondLevel.isEmpty {
                return Self.buildExpandedSubfolderSections(
                    rootEntries: entries,
                    secondLevelEntries: secondLevel,
                    subtree: subtree,
                    tags: tags,
                    searchIndex: combinedSearchIndex,
                    activeMetadata: activeMeta,
                    selection: selection,
                    query: query,
                    order: order,
                    stacking: stacking,
                    rootFolderTitle: rootFolderTitle
                )
            } else {
                guard let result = Self.filterEntries(
                    entries,
                    subtree: subtree,
                    tags: tags,
                    searchIndex: combinedSearchIndex,
                    activeMetadata: activeMeta,
                    selection: selection,
                    query: query,
                    order: order
                ) else { return nil }
                let stacks = BrowserStack.build(result, enabled: stacking)
                let section = BrowserMediaSection(
                    id: "root",
                    folderName: nil,
                    folderEntry: nil,
                    stacks: stacks,
                    mediaEntries: result.filter { !$0.folder }
                )
                return (result, stacks, result.isEmpty ? [] : [section])
            }
        }
        let result = await withTaskCancellationHandler { await work.value }
            onCancel: { work.cancel() }
        guard !Task.isCancelled, let result else { return }
        if displayedEntries != result.0 { displayedEntries = result.0 }
        if displayedStacks != result.1 { displayedStacks = result.1 }
        if displayedSections != result.2 { displayedSections = result.2 }
        let validStackIDs = Set(result.2.flatMap { $0.stacks.map(\.id) })
        expandedStacks.formIntersection(validStackIDs)
    }

    private func editFile(_ url: URL, trash: Bool) {
        guard !fileBusy else { return }
        // Playing and queued paths remain stable; explicit queue edits are separate.
        guard !model.queue.contains(where: { $0.filename == url.path || $0.filename.hasPrefix(url.path + "/") }) else {
            failure = String(localized: "Remove this file or folder's media from the play queue before editing it.")
            return
        }
        let name = newFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trash || (!name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains(":")) else {
            failure = String(localized: "Enter a valid filename."); return
        }
        fileBusy = true
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    if trash { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                    else { try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent(name)) }
                }.value
                let affected = (entries + secondLevelMediaEntries + subtreeMediaEntries).filter {
                    $0.url.path == url.path || $0.url.path.hasPrefix(url.path + "/")
                }
                for oldPath in Set(affected.filter { !$0.folder }.map { $0.url.path } + [url.path]) {
                    if trash { onlineLibrary.remove(oldPath) }
                    else {
                        let destination = url.deletingLastPathComponent().appendingPathComponent(name).path + String(oldPath.dropFirst(url.path.count))
                        await onlineLibrary.relocate(from: oldPath, to: destination)
                    }
                }
                MediaNFOCache.shared.invalidateLocalPath(url.path)
                MediaNFOCache.shared.invalidateLocalPath(url.deletingLastPathComponent().appendingPathComponent(name).path)
                for entry in entries + secondLevelMediaEntries + subtreeMediaEntries
                where entry.url.path == url.path || entry.url.path.hasPrefix(url.path + "/") {
                    ThumbnailImageCache.shared.remove(entry.id)
                }
                if PlayerSpotlightLibrary.shared.enabled { PlayerSpotlightLibrary.shared.refresh() }
                if expandedEntryID == url.path {
                    expandedEntryID = trash ? nil : url.deletingLastPathComponent().appendingPathComponent(name).path
                }
                reloadToken = UUID()
            } catch { failure = error.localizedDescription }
            fileBusy = false
        }
    }

    private var isWebDAV: Bool { selectedServerID != nil }

    private var currentTitle: String {
        if isWebDAV {
            if let davFolder, !davFolder.lastPathComponent.isEmpty, davFolder.path != "/" {
                return davFolder.lastPathComponent
            }
            if let id = selectedServerID, let server = servers.servers.first(where: { $0.id == id }) {
                return server.name
            }
            return "WebDAV"
        }
        return directory?.lastPathComponent ?? String(localized: "Files")
    }

    private var currentPathHelp: String {
        if isWebDAV { return davFolder?.absoluteString ?? "" }
        return directory?.path ?? ""
    }

    private var canGoUp: Bool {
        if isWebDAV {
            guard let davFolder else { return false }
            let path = davFolder.path.isEmpty ? "/" : davFolder.path
            return path != "/" && path != davRootPath
        }
        guard let directory else { return false }
        return directory.path != "/"
    }

    nonisolated private static func compareEntries(_ a: BrowserEntry, _ b: BrowserEntry, order: String) -> Bool {
        if a.folder != b.folder { return a.folder }
        if order.hasPrefix("created-") || order.hasPrefix("modified-") {
            let left = order.hasPrefix("created-") ? a.created : a.modified
            let right = order.hasPrefix("created-") ? b.created : b.modified
            if left != right {
                guard let left else { return false }
                guard let right else { return true }
                return order.hasSuffix("new") ? left > right : left < right
            }
        }
        if order == "size", a.size != b.size { return (a.size ?? -1) > (b.size ?? -1) }
        let comparison = a.name.localizedStandardCompare(b.name)
        if comparison == .orderedSame { return a.id < b.id }
        return order == "descending" ? comparison == .orderedDescending : comparison == .orderedAscending
    }

    nonisolated private static func buildExpandedSubfolderSections(
        rootEntries: [BrowserEntry],
        secondLevelEntries: [BrowserEntry],
        subtree: [BrowserEntry],
        tags: [String: Set<String>],
        searchIndex: [String: String],
        activeMetadata: (path: String, text: String)?,
        selection: Set<String>,
        query: String,
        order: String,
        stacking: Bool,
        rootFolderTitle: String
    ) -> ([BrowserEntry], [BrowserStack], [BrowserMediaSection])? {
        guard !Task.isCancelled else { return nil }
        // Group second-level media strictly by immediate subfolder name (no 3rd-level "/" paths).
        var mediaBySubfolder: [String: [BrowserEntry]] = [:]
        for item in secondLevelEntries {
            guard let rel = item.relativeFolder, !rel.isEmpty, !rel.contains("/") else { continue }
            mediaBySubfolder[rel, default: []].append(item)
        }
        let populatedSubfolders = Set(mediaBySubfolder.keys)
        let folderEntriesByName = Dictionary(
            rootEntries.filter(\.folder).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }
        )

        // Root entries: keep folders that have no extracted 2nd-level media, plus direct root media files.
        let rootCandidateEntries = rootEntries.filter { entry in
            if entry.folder {
                return !populatedSubfolders.contains(entry.name)
            }
            return true
        }
        guard let filteredRoot = filterEntries(
            rootCandidateEntries,
            subtree: [],
            tags: tags,
            searchIndex: searchIndex,
            activeMetadata: activeMetadata,
            selection: selection,
            query: query,
            order: order
        ) else { return nil }

        // Sort second-level subfolders according to the active sort order.
        let orderedSubfolderNames = mediaBySubfolder.keys.sorted { lhsName, rhsName in
            if let lhsFolder = folderEntriesByName[lhsName], let rhsFolder = folderEntriesByName[rhsName] {
                return compareEntries(lhsFolder, rhsFolder, order: order)
            }
            let cmp = lhsName.localizedStandardCompare(rhsName)
            return order == "descending" ? cmp == .orderedDescending : cmp == .orderedAscending
        }

        var subfolderSections: [BrowserMediaSection] = []
        for subName in orderedSubfolderNames {
            guard !Task.isCancelled else { return nil }
            let rawItems = mediaBySubfolder[subName] ?? []
            guard let filteredSub = filterEntries(
                rawItems,
                subtree: [],
                tags: tags,
                searchIndex: searchIndex,
                activeMetadata: activeMetadata,
                selection: selection,
                query: query,
                order: order
            ), !filteredSub.isEmpty else { continue }
            let stacks = BrowserStack.build(filteredSub, enabled: stacking)
            let folderEntry = folderEntriesByName[subName]
            subfolderSections.append(
                BrowserMediaSection(
                    id: "subfolder:" + (folderEntry?.id ?? subName),
                    folderName: subName,
                    folderEntry: folderEntry,
                    stacks: stacks,
                    mediaEntries: filteredSub.filter { !$0.folder }
                )
            )
        }

        var sections: [BrowserMediaSection] = []
        let rootFolders = filteredRoot.filter(\.folder)
        let rootMedia = filteredRoot.filter { !$0.folder }

        if !rootFolders.isEmpty {
            let folderStacks = BrowserStack.build(rootFolders, enabled: false)
            sections.append(
                BrowserMediaSection(
                    id: "root-folders",
                    folderName: nil,
                    folderEntry: nil,
                    stacks: folderStacks,
                    mediaEntries: []
                )
            )
        }
        if !rootMedia.isEmpty {
            let mediaStacks = BrowserStack.build(rootMedia, enabled: stacking)
            sections.append(
                BrowserMediaSection(
                    id: "root-media",
                    folderName: subfolderSections.isEmpty ? nil : rootFolderTitle,
                    folderEntry: nil,
                    stacks: mediaStacks,
                    mediaEntries: rootMedia
                )
            )
        }
        sections.append(contentsOf: subfolderSections)

        let flatEntries = sections.flatMap { section in
            section.stacks.flatMap(\.entries)
        }
        let allStacks = sections.flatMap(\.stacks)
        return Task.isCancelled ? nil : (flatEntries, allStacks, sections)
    }

    nonisolated private static func filterEntries(
        _ entries: [BrowserEntry], subtree: [BrowserEntry], tags: [String: Set<String>],
        searchIndex: [String: String], activeMetadata: (path: String, text: String)?,
        selection: Set<String>, query: String, order: String
    ) -> [BrowserEntry]? {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let pool: [BrowserEntry]
        if !selection.isEmpty {
            pool = subtree.isEmpty ? entries : subtree
        } else if !words.isEmpty && !subtree.isEmpty {
            var seen = Set(entries.map(\.id))
            var combined = entries
            for sub in subtree where seen.insert(sub.id).inserted {
                combined.append(sub)
            }
            pool = combined
        } else {
            pool = entries
        }
        var matches: [BrowserEntry] = []
        for item in pool {
            guard !Task.isCancelled else { return nil }
            if !selection.isEmpty {
                guard !item.folder, let itemTags = tags[item.id], selection.isSubset(of: itemTags) else { continue }
            }
            if words.isEmpty {
                matches.append(item)
            } else {
                let indexedText = searchIndex[item.id] ?? MediaNFOCache.shared.lookup(item.id).value?.searchableText ?? ""
                let liveText = (activeMetadata?.path == item.id) ? (activeMetadata?.text ?? "") : ""
                if words.allSatisfy({ word in
                    item.name.localizedStandardContains(word) ||
                    item.relativeFolder?.localizedStandardContains(word) == true ||
                    (!indexedText.isEmpty && indexedText.localizedStandardContains(word)) ||
                    (!liveText.isEmpty && liveText.localizedStandardContains(word))
                }) {
                    matches.append(item)
                }
            }
        }
        matches.sort { a, b in compareEntries(a, b, order: order) }
        return Task.isCancelled ? nil : matches
    }

    var body: some View {
        let visible = displayedEntries
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("Up", systemImage: "chevron.up", action: goUp)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(!canGoUp || loading)
                    .help("Parent Folder")

                Menu {
                    Section("Local") {
                        Button {
                            selectedServerID = nil
                        } label: {
                            Label(
                                directory?.lastPathComponent ?? String(localized: "Local Folder"),
                                systemImage: selectedServerID == nil ? "checkmark" : "folder"
                            )
                        }
                        Button("Choose Local Folder…", systemImage: "folder.badge.plus") {
                            chooseLocalFolder()
                        }
                        Button("Use This as Default Folder", systemImage: "folder.badge.checkmark") {
                            guard let directory else { return }
                            do { try model.fileDialogs.saveDefaultBrowserFolder(directory) }
                            catch { failure = error.localizedDescription }
                        }.disabled(directory == nil)
                        Button("Open Default Folder", systemImage: "house") {
                            do { if let url = try model.fileDialogs.restoreDefaultBrowserFolder() { directory = url } }
                            catch { failure = error.localizedDescription }
                        }
                    }
                    Section("WebDAV") {
                        if servers.servers.isEmpty {
                            Text("No saved WebDAV servers")
                        }
                        ForEach(servers.servers) { server in
                            Button {
                                selectWebDAVServer(server.id)
                            } label: {
                                Label(server.name, systemImage: selectedServerID == server.id ? "checkmark" : "externaldrive.connected.to.line.below")
                            }
                        }
                        Button("Open / Manage WebDAV…", systemImage: "network") {
                            model.showNetworkSheet = true
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isWebDAV ? "network" : "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(currentTitle)
                            .font(.headline)
                            .lineLimit(1)
                    }
                }
                .menuStyle(.borderlessButton)
                .help(currentPathHelp)

                Spacer(minLength: 0)

                if model.canRevealInFileBrowser(path: model.path) {
                    Button {
                        model.revealInFileBrowser(path: model.path)
                    } label: {
                        Image(systemName: "scope")
                    }
                    .buttonStyle(.borderless)
                    .help("Locate Playing Media")
                }

                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                        showSearch.toggle()
                        if showSearch { searchFocused = true }
                        else { query = "" }
                    }
                } label: {
                    Image(systemName: showSearch || !query.isEmpty ? "magnifyingglass.circle.fill" : "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .disabled(entries.isEmpty && secondLevelMediaEntries.isEmpty && query.isEmpty)
                .help("Search Folder")

                Menu {
                    sortChoice("Name · A–Z", value: "name")
                    sortChoice("Name · Z–A", value: "descending")
                    sortChoice("Size · Largest First", value: "size")
                    Divider()
                    sortChoice("Date Created · Newest First", value: "created-new")
                    sortChoice("Date Created · Oldest First", value: "created-old")
                    sortChoice("Date Modified · Newest First", value: "modified-new")
                    sortChoice("Date Modified · Oldest First", value: "modified-old")
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 26, height: 24)
                .help("Sort")

                Menu {
                    Toggle("Show Subfolder Media", isOn: $expandSubfolders)
                    Toggle("Stack Similar Episodes", isOn: $stackEpisodes)
                    Picker("Display", selection: $detailedView) {
                        Label("Title & Icon", systemImage: "list.bullet").tag(false)
                        Label("Thumbnail, Title, Duration & Size", systemImage: "photo.on.rectangle").tag(true)
                    }
                    Divider()
                    Button("Locate Playing Media", systemImage: "scope") {
                        model.revealInFileBrowser(path: model.path)
                    }
                    .disabled(!model.canRevealInFileBrowser(path: model.path))
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        BrowserDirectoryIndex.clear()
                        MediaNFOCache.clearFileIndex()
                        reloadToken = UUID()
                    }
                    .disabled(loading)
                    if !isWebDAV {
                        Button("Choose Local Folder…", systemImage: "folder.badge.plus") {
                            chooseLocalFolder()
                        }
                    } else {
                        Button("Manage WebDAV Servers…", systemImage: "network") {
                            model.showNetworkSheet = true
                        }
                    }
                } label: {
                    Image(systemName: detailedView ? "photo.on.rectangle" : "line.3.horizontal.decrease")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 26, height: 24)
                .help("View mode and folder options")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if showSearch || !query.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                    TextField("Search Folder", text: $query)
                        .textInputBorderShape(.capsule)
                        .controlSize(.small)
                        .focused($searchFocused)
                        .onKeyPress(.escape) {
                            if !query.isEmpty { query = ""; return .handled }
                            showSearch = false; return .handled
                        }
                    if !query.isEmpty {
                        Button("Clear Search", systemImage: "xmark.circle.fill") {
                            query = ""; searchFocused = true
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if !availableTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        tagCapsule(
                            title: String(localized: "All"),
                            count: nil,
                            selected: selectedTags.isEmpty
                        ) {
                            withAnimation(reduceMotion ? nil : .spring(duration: 0.34, bounce: 0.08)) {
                                selectedTags.removeAll()
                            }
                        }

                        ForEach(availableTags) { tag in
                            let isSelected = selectedTags.contains(tag.key)
                            tagCapsule(
                                title: tag.display,
                                count: tag.count,
                                selected: isSelected
                            ) {
                                withAnimation(reduceMotion ? nil : .spring(duration: 0.34, bounce: 0.08)) {
                                    if isSelected {
                                        selectedTags.remove(tag.key)
                                    } else {
                                        selectedTags.insert(tag.key)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 2)
                }
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if loading || refreshing {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
            }
            if !failure.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if isWebDAV {
                            Button("Retry", systemImage: "arrow.clockwise") { reloadToken = UUID() }
                                .controlSize(.small)
                            Button("Open Network…", systemImage: "network") { model.showNetworkSheet = true }
                                .controlSize(.small)
                        } else {
                            Button("Choose Folder…", systemImage: "folder.badge.plus") { chooseLocalFolder() }
                                .controlSize(.small)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }

            if !loading && entries.isEmpty && secondLevelMediaEntries.isEmpty && failure.isEmpty {
                ContentUnavailableView {
                    Label(isWebDAV ? String(localized: "No Media in WebDAV Folder") :
                          directory == nil ? String(localized: "Choose a Folder") : String(localized: "No Media in Folder"),
                          systemImage: isWebDAV ? "network" : "folder")
                } description: {
                    Text("Browse media, folders and episode details here.")
                } actions: {
                    if !isWebDAV {
                        Button("Choose Folder…", systemImage: "folder.badge.plus", action: chooseLocalFolder)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !loading && visible.isEmpty && (!query.isEmpty || !selectedTags.isEmpty) {
                if !query.isEmpty && selectedTags.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("No matching items", systemImage: "tag.slash")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(displayedSections) { section in
                                if let sectionTitle = section.folderName {
                                    BrowserSubfolderSectionHeader(
                                        title: sectionTitle,
                                        itemCount: section.mediaEntries.count,
                                        isPlayingInSection: section.mediaEntries.contains(where: isEntryCurrentlyPlaying),
                                        isPaused: model.paused,
                                        canShowInFinder: section.folderEntry?.url.isFileURL == true,
                                        onOpenFolder: section.folderEntry.map { folder in
                                            { openEntry(folder) }
                                        },
                                        onPlaySection: { playSection(section) },
                                        onEnqueueSection: { playNext in enqueueSection(section, playNext: playNext) },
                                        onShowInFinder: section.folderEntry?.url.isFileURL == true ? {
                                            if let path = section.folderEntry?.url.path {
                                                model.showInFinder(path: path)
                                            }
                                        } : nil
                                    )
                                    .id(section.id)
                                }
                                ForEach(section.stacks) { stack in
                                    if stack.entries.count > 1 {
                                        BrowserStackRow(stack: stack,
                                            expanded: Binding(get: { expandedStacks.contains(stack.id) }, set: { value in
                                                if value { expandedStacks.insert(stack.id) } else { expandedStacks.remove(stack.id) }
                                            }), detailed: detailedView, active: active, model: model,
                                            credentials: davCredentials, remoteDeferred: model.remoteMetadataDeferred,
                                            remoteRevision: model.metadataPriorityRevision) {
                                                ForEach(stack.entries) { entry in
                                                    browserRow(entry, inNamedSection: section.folderName != nil)
                                                        .id(entry.id)
                                                }
                                            }
                                            .id(stack.id)
                                            .disabled(fileBusy || loading)
                                    } else if let entry = stack.entries.first {
                                        browserRow(entry, inNamedSection: section.folderName != nil)
                                            .id(entry.id)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                    .environment(\.browserScrolling, browserScrolling)
                    .onScrollPhaseChange { _, phase in
                        let moving = phase != .idle
                        if browserScrolling != moving { browserScrolling = moving }
                    }
                    .modifier(ArtworkReflectionLayer())
                    .onChange(of: displayedEntries) { _, _ in
                        performPendingRevealIfNeeded(using: proxy)
                    }
                    .onChange(of: pendingRevealEntryID) { _, _ in
                        performPendingRevealIfNeeded(using: proxy)
                    }
                }
            }
        }
        .quickLookPreview($quickLookURL)
        .onChange(of: active, initial: true) { _, value in
            observation.update(model, active: value)
            if !value { quickLookURL = nil; directoryWatcher.stop() }
        }
        .onAppear { observation.update(model, active: active) }
        .onDisappear { observation.stop(); directoryWatcher.stop() }
        .onChange(of: directoryWatcher.revision) { _, _ in directoryRefreshPending = true }
        .task(id: "\(directoryWatcher.revision)|\(browserScrolling)|\(active)") {
            guard active, !isWebDAV, !browserScrolling, directoryRefreshPending else { return }
            directoryRefreshPending = false
            reloadToken = UUID()
        }
        .task(id: "\(browserRevision)|\(active)") { await updateDisplayedEntries() }
        .task(id: "online-index|\(active)|\(settledQuery.isEmpty)|\(onlinePoolRevision)|\(onlineLibrary.searchRevision)") {
            guard active, !settledQuery.isEmpty, onlineLibrary.enabled else {
                onlineSearchIndex = [:]; onlineSearchLoading = false; refreshDisplayedEntries(); return
            }
            onlineSearchLoading = true
            defer { if !Task.isCancelled { onlineSearchLoading = false } }
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            let poolRevision = onlinePoolRevision
            let paths = (entries + secondLevelMediaEntries + subtreeMediaEntries)
                .filter { !$0.folder && $0.url.isFileURL }.map { $0.url.path }
            let index = await onlineLibrary.searchIndex(paths: paths)
            guard !Task.isCancelled, poolRevision == onlinePoolRevision else { return }
            onlineSearchIndex = index
            onlineSearchRevision = onlineLibrary.searchRevision
            indexedPoolRevision = poolRevision
            refreshDisplayedEntries()
        }
        .onChange(of: entries, initial: true) { _, _ in onlinePoolRevision &+= 1; refreshDisplayedEntries() }
        .onChange(of: secondLevelMediaEntries) { _, _ in onlinePoolRevision &+= 1; refreshDisplayedEntries() }
        .onChange(of: subtreeMediaEntries) { _, _ in onlinePoolRevision &+= 1; refreshDisplayedEntries() }
        .onChange(of: entryTagsByID) { _, _ in refreshDisplayedEntries() }
        .onChange(of: onlineLibrary.searchRevision) { _, _ in refreshDisplayedEntries() }
        .onChange(of: entrySearchIndexByID) { _, _ in refreshDisplayedEntries() }
        .onChange(of: selectedTags) { _, _ in refreshDisplayedEntries() }
        .onReceive(NotificationCenter.default.publisher(for: .browserSearchCurrentFolder)) { note in
            guard let term = note.userInfo?["query"] as? String, !term.isEmpty else { return }
            if let folderURL = note.userInfo?["folderURL"] as? URL {
                selectedServerID = nil
                if directory != folderURL {
                    pendingSearchQuery = term
                    directory = folderURL
                }
            }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.06)) {
                selectedTags.removeAll()
                expandedEntryID = nil
                showSearch = true
                query = term
                settledQuery = term
            }
            refreshDisplayedEntries()
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserRevealMediaItem)) { note in
            handleRevealMediaItem(note)
        }
        .task(id: query) {
            // Cancel superseded searches while keeping the text field responsive.
            if !query.isEmpty {
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            settledQuery = query
            refreshDisplayedEntries()
        }
        .onChange(of: sortOrder) { _, _ in refreshDisplayedEntries() }
        .onChange(of: stackEpisodes) { _, _ in refreshDisplayedEntries() }
        .onChange(of: expandSubfolders) { _, _ in refreshDisplayedEntries() }
        .alert("Rename", isPresented: Binding(get: { editingFile != nil }, set: { if !$0 { editingFile = nil } })) {
            TextField("Filename", text: $newFilename)
            Button("Save") { if let url = editingFile { editFile(url, trash: false) }; editingFile = nil }
            Button("Cancel", role: .cancel) { editingFile = nil }
        }
        .confirmationDialog("Move to Trash?", isPresented: Binding(get: { trashFile != nil }, set: { if !$0 { trashFile = nil } }), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { if let url = trashFile { editFile(url, trash: true) }; trashFile = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaNFODidChange)) { _ in tagRefresh += 1 }
        .task(id: "\(tagRefresh)|\(active)|\(selectedServerID?.uuidString ?? "local")|\(directory?.path ?? "")") {
            guard tagRefresh > 0, active, !isWebDAV, let directory else { return }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await scanLocalFolderTreeForTags(root: directory)
        }
        .task(id: active) {
            guard active, directory == nil, selectedServerID == nil else { return }
            do { directory = try model.fileDialogs.restoreDefaultBrowserFolder() }
            catch { failure = error.localizedDescription }
        }
        .task(id: "\(selectedServerID?.uuidString ?? "local")|\(directory?.path ?? "")|\(davFolder?.absoluteString ?? "")|\(expandSubfolders)|\(reloadToken.uuidString)|\(active)") {
            guard active else { return }
            let location = "\(selectedServerID?.uuidString ?? "local")|\(directory?.path ?? "")|\(davFolder?.absoluteString ?? "")"
            if location != loadedLocation {
                directoryWatcher.stop()
                refreshing = false
                loadedLocation = location
                directoryRefreshPending = false
                expandedEntryID = nil
                expandedStacks.removeAll()
                selectedTags.removeAll()
                availableTags = []
                entryTagsByID = [:]
                entrySearchIndexByID = [:]
                entries = []; displayedEntries = []; displayedStacks = []; displayedSections = []
                secondLevelMediaEntries = []; subtreeMediaEntries = []
            }
            if let pending = pendingSearchQuery {
                pendingSearchQuery = nil
                showSearch = true
                query = pending
                settledQuery = pending
            }
            if isWebDAV {
                await loadWebDAVFolder()
            } else {
                await loadLocalFolder()
            }
        }
    }

    private func handleRevealMediaItem(_ note: Notification) {
        guard let info = note.userInfo, let targetID = info["entryID"] as? String else { return }
        withAnimation(reduceMotion ? nil : .spring(duration: 0.30, bounce: 0.06)) {
            selectedTags.removeAll()
            query = ""
            settledQuery = ""
            showSearch = false
        }
        pendingRevealEntryID = targetID
        if let folderURL = info["folderURL"] as? URL {
            selectedServerID = nil
            // If expandSubfolders is enabled and the current directory is the immediate parent of folderURL,
            // keep the current parent directory so the item is revealed directly in its 2nd-level subfolder section.
            let stdTargetFolder = folderURL.standardizedFileURL
            let stdCurrent = directory?.standardizedFileURL
            let isSecondLevelOfCurrent = expandSubfolders && stdCurrent != nil && stdTargetFolder.deletingLastPathComponent() == stdCurrent && stdTargetFolder != stdCurrent
            if !isSecondLevelOfCurrent && stdCurrent != stdTargetFolder {
                directory = stdTargetFolder
            } else {
                refreshDisplayedEntries()
            }
        } else if let davFolderURL = info["davFolderURL"] as? URL,
                  let creds = info["davCredentials"] as? NetworkServerCredentials {
            let targetHost = davFolderURL.host ?? URL(string: creds.address)?.host ?? ""
            if let matchedServer = servers.servers.first(where: { !$0.host.isEmpty && $0.host == targetHost }) {
                selectedServerID = matchedServer.id
            } else if selectedServerID == nil {
                selectedServerID = servers.lastSelected ?? servers.servers.first?.id ?? UUID()
            }
            davCredentials = creds
            if davFolder != davFolderURL {
                davFolder = davFolderURL
            } else {
                refreshDisplayedEntries()
            }
        }
    }

    private func performPendingRevealIfNeeded(using proxy: ScrollViewProxy) {
        guard let targetID = pendingRevealEntryID else { return }
        guard displayedEntries.contains(where: { $0.id == targetID }) else { return }
        pendingRevealEntryID = nil

        for section in displayedSections {
            for stack in section.stacks where stack.entries.count > 1 {
                if stack.entries.contains(where: { $0.id == targetID }) {
                    expandedStacks.insert(stack.id)
                }
            }
        }

        highlightDismissTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
            highlightedEntryID = targetID
        }
        Task { @MainActor in
            await Task.yield()
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.30)) {
                proxy.scrollTo(targetID, anchor: .center)
            }
        }
        highlightDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(2000))
            guard !Task.isCancelled, highlightedEntryID == targetID else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
                highlightedEntryID = nil
            }
        }
    }

    private func sortChoice(_ title: LocalizedStringKey, value: String) -> some View {
        Button { sortOrder = value } label: {
            Label(title, systemImage: sortOrder == value ? "checkmark" : "arrow.up.arrow.down")
        }
    }

    private func queuedItemID(for entry: BrowserEntry) -> Int64? {
        guard !entry.folder else { return nil }
        if entry.webDAVItem != nil {
            for row in model.queue {
                if let remote = model.remoteEntries[row.filename], remote.item.url == entry.url {
                    return row.id
                }
            }
            return nil
        }
        let stdPath = entry.url.standardizedFileURL.path
        return model.queue.first(where: {
            $0.filename == entry.url.path ||
            ($0.filename.hasPrefix("/") && URL(fileURLWithPath: $0.filename).standardizedFileURL.path == stdPath)
        })?.id
    }

    @ViewBuilder
    private func browserRow(_ entry: BrowserEntry, inNamedSection: Bool = false) -> some View {
        let isCurrent = isEntryCurrentlyPlaying(entry)
        let queueID = queuedItemID(for: entry)
        let isQueued = queueID != nil
        let isHighlighted = highlightedEntryID == entry.id
        let isExpanded = expandedEntryID == entry.id
        BrowserEntryRow(
            duration: isCurrent ? model.duration : 0,
            remoteDeferred: entry.webDAVItem != nil && model.remoteMetadataDeferred,
            remoteRevision: entry.webDAVItem != nil ? model.metadataPriorityRevision : 0,
            browserRevision: browserRevision,
            searchQuery: settledQuery,
            model: model,
            entry: entry,
            detailed: detailedView,
            active: active,
            isCurrent: isCurrent,
            isQueued: isQueued,
            isHighlighted: isHighlighted,
            showsRelativeFolder: !inNamedSection,
            isExpanded: isExpanded,
            webDAVCredentials: davCredentials,
            onSingleClick: {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.38, bounce: 0.04)) {
                    expandedEntryID = (expandedEntryID == entry.id) ? nil : entry.id
                }
            },
            onOpen: { openEntry(entry) },
            onPreview: { quickLookURL = entry.url },
            onEnqueue: { playNext in enqueueEntry(entry, playNext: playNext) },
            onPlayFolder: entry.folder && entry.url.isFileURL ? { playFolderEntry(entry) } : nil,
            onEnqueueFolder: entry.folder && entry.url.isFileURL ? { playNext in enqueueFolderEntry(entry, playNext: playNext) } : nil,
            onRemoveFromQueue: (!isCurrent && queueID != nil) ? {
                if let id = queueID { model.removeQueueItem(id) }
            } : nil,
            onRename: entry.url.isFileURL ? { editingFile = entry.url; newFilename = entry.name } : nil,
            onTrash: entry.url.isFileURL ? { trashFile = entry.url } : nil
        )
        .equatable()
        .disabled(fileBusy || loading)
    }

    @ViewBuilder
    private func tagCapsule(title: String, count: Int?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption.weight(selected ? .semibold : .medium))
                if let count {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
                }
            }
            .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.88))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(selected ? Color.accentColor.opacity(0.88) : Color.primary.opacity(0.08))
            )
            .overlay(
                Capsule()
                    .strokeBorder(selected ? Color.white.opacity(0.22) : Color.white.opacity(0.10), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func chooseLocalFolder() {
        model.fileDialogs.importFiles(title: "Choose Folder", types: [.folder]) { result in
            if case .success(let urls) = result, let picked = urls.first {
                selectedServerID = nil
                directory = picked
            }
        }
    }

    private func selectWebDAVServer(_ id: UUID) {
        selectedServerID = id
        failure = ""
        entries = []
        secondLevelMediaEntries = []
        do {
            let creds = try servers.credentials(for: id)
            var rootURL = try NetworkMediaRequest.parse(creds.address, webDAV: true)
            if !rootURL.path.hasSuffix("/") { rootURL.appendPathComponent("") }
            davCredentials = creds
            davRootPath = rootURL.path.isEmpty ? "/" : rootURL.path
            let key = RemoteBrowserMemory.davKey(rootURL, user: creds.username, password: creds.password)
            if let remembered = RemoteBrowserMemory.davPosition(for: key) {
                davFolder = remembered
            } else {
                davFolder = rootURL
            }
            servers.select(id)
        } catch {
            davCredentials = nil
            davFolder = nil
            failure = error.localizedDescription
        }
    }

    private func goUp() {
        if isWebDAV {
            guard let current = davFolder, canGoUp else { return }
            var parent = current.deletingLastPathComponent()
            if !parent.path.hasSuffix("/") { parent.appendPathComponent("") }
            davFolder = parent
        } else {
            guard let current = directory, canGoUp else { return }
            directory = current.deletingLastPathComponent()
        }
    }

    private func isEntryCurrentlyPlaying(_ entry: BrowserEntry) -> Bool {
        guard !entry.folder else { return false }
        if entry.webDAVItem != nil {
            if let activeRemote = model.remoteEntries[model.path] {
                return activeRemote.item.url == entry.url
            }
            return false
        }
        return model.path == entry.url.path
    }

    private func openEntry(_ entry: BrowserEntry, siblingsOverride: [BrowserEntry]? = nil) {
        if entry.folder {
            query = ""
            if isWebDAV {
                var nextURL = entry.url
                if !nextURL.path.hasSuffix("/") { nextURL.appendPathComponent("") }
                davFolder = nextURL
            } else {
                directory = entry.url
            }
            return
        }
        if let davItem = entry.webDAVItem, let creds = davCredentials {
            let siblings = (siblingsOverride ?? displayedEntries).filter { !$0.folder }.compactMap(\.webDAVItem)
            let useExplicitOrder = siblingsOverride != nil || expandSubfolders || !selectedTags.isEmpty || !settledQuery.isEmpty || sortOrder != "name"
            model.openWebDAV(
                davItem,
                siblings: siblings.isEmpty ? [davItem] : siblings,
                credentials: NetworkServerCredentials(
                    address: davFolder?.absoluteString ?? creds.address,
                    username: creds.username,
                    password: creds.password
                ),
                append: false,
                explicitItems: useExplicitOrder && model.autoQueueFolder && !siblings.isEmpty ? siblings : nil
            )
        } else if entry.url.isFileURL {
            let siblingURLs = (siblingsOverride ?? displayedEntries).filter { !$0.folder && $0.url.isFileURL }.map(\.url)
            model.openFromBrowser(entry.url, siblingURLs: siblingURLs)
        } else {
            model.open(entry.url)
        }
    }

    private func playSection(_ section: BrowserMediaSection) {
        guard let first = section.mediaEntries.first else { return }
        openEntry(first, siblingsOverride: section.mediaEntries)
    }

    private func enqueueSection(_ section: BrowserMediaSection, playNext: Bool) {
        let media = section.mediaEntries
        guard !media.isEmpty else { return }
        if let creds = davCredentials, isWebDAV {
            let davItems = media.compactMap(\.webDAVItem)
            guard !davItems.isEmpty else { return }
            let origin = RemoteMediaOrigin.webDAV(
                .init(
                    address: davFolder?.absoluteString ?? creds.address,
                    username: creds.username,
                    password: creds.password
                )
            )
            if playNext {
                model.playNextRemoteBatch(davItems, origin: origin)
            } else {
                model.appendRemoteBatch(davItems, origin: origin)
            }
        } else {
            let urls = media.filter { $0.url.isFileURL }.map(\.url)
            guard !urls.isEmpty else { return }
            if playNext {
                model.playNextLocalFiles(urls)
            } else {
                model.openFiles(urls, append: true)
            }
        }
    }

    private func playFolderEntry(_ folderEntry: BrowserEntry) {
        guard folderEntry.folder, folderEntry.url.isFileURL else { return }
        model.openFiles([folderEntry.url], append: false)
    }

    private func enqueueFolderEntry(_ folderEntry: BrowserEntry, playNext: Bool) {
        guard folderEntry.folder, folderEntry.url.isFileURL else { return }
        if playNext {
            model.playNextLocalFiles([folderEntry.url])
        } else {
            model.openFiles([folderEntry.url], append: true)
        }
    }

    private func enqueueEntry(_ entry: BrowserEntry, playNext: Bool) {
        guard !entry.folder else { return }
        if let davItem = entry.webDAVItem, let creds = davCredentials {
            let origin = RemoteMediaOrigin.webDAV(
                .init(
                    address: davFolder?.absoluteString ?? creds.address,
                    username: creds.username,
                    password: creds.password
                )
            )
            if playNext {
                model.playNextRemoteBatch([davItem], origin: origin)
            } else {
                model.appendRemoteBatch([davItem], origin: origin)
            }
        } else if entry.url.isFileURL {
            if playNext {
                model.playNextLocalFiles([entry.url])
            } else {
                model.openFiles([entry.url], append: true)
            }
        }
    }

    private func loadLocalFolder() async {
        guard let directory else { return }
        let shouldExpandSubfolders = expandSubfolders
        failure = ""
        loading = entries.isEmpty && secondLevelMediaEntries.isEmpty
        refreshing = true
        // Subscribe before scanning so a write during the read triggers another snapshot.
        directoryWatcher.watch([directory] + (shouldExpandSubfolders ? entries.filter(\.folder).map(\.url) : []))
        let read = Task.detached(priority: .utility) { () throws -> (root: [BrowserEntry], secondLevel: [BrowserEntry]) in
            let keys: [URLResourceKey] = [
                .isDirectoryKey, .isRegularFileKey, .fileSizeKey,
                .creationDateKey, .contentModificationDateKey,
                .isSymbolicLinkKey, .isPackageKey
            ]
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            var nfoByBase: [String: URL] = [:]
            var movieNFO: URL? = nil
            for url in urls where url.pathExtension.lowercased() == "nfo" {
                let base = url.deletingPathExtension().lastPathComponent.lowercased()
                nfoByBase[base] = url
                if base == "movie" { movieNFO = url }
            }
            let playableCount = urls.filter { FolderMedia.extensions.contains($0.pathExtension.lowercased()) }.count
            var childFolders: [URL] = []
            let rootEntries = try urls.compactMap { url -> BrowserEntry? in
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: Set(keys))
                let folder = values.isDirectory == true
                guard folder || (values.isRegularFile == true && FolderMedia.extensions.contains(url.pathExtension.lowercased())) else {
                    return nil
                }
                if folder, values.isSymbolicLink != true, values.isPackage != true {
                    childFolders.append(url)
                }
                let base = url.deletingPathExtension().lastPathComponent.lowercased()
                let matchedNFO = folder ? nil : (nfoByBase[base] ?? (playableCount <= 2 ? movieNFO : nil))
                if let matchedNFO, let parsed = MediaNFOCache.indexedLocalMetadata(matchedNFO) {
                    MediaNFOCache.shared.store(url.path, value: parsed)
                }
                return BrowserEntry(
                    id: url.path,
                    url: url,
                    name: url.lastPathComponent,
                    folder: folder,
                    size: values.fileSize.map(Int64.init),
                    webDAVItem: nil,
                    nfoURL: matchedNFO, created: values.creationDate, modified: values.contentModificationDate
                )
            }.sorted { a, b in
                if a.folder != b.folder { return a.folder }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }

            var extractedSecondLevel: [BrowserEntry] = []
            if shouldExpandSubfolders {
                let sortedFolders = childFolders.sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }
                for subfolderURL in sortedFolders {
                    try Task.checkCancellation()
                    let subName = subfolderURL.lastPathComponent
                    let subURLs = (try? FileManager.default.contentsOfDirectory(
                        at: subfolderURL,
                        includingPropertiesForKeys: keys,
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]
                    )) ?? []
                    var subNFOByBase: [String: URL] = [:]
                    var subMovieNFO: URL? = nil
                    for u in subURLs where u.pathExtension.lowercased() == "nfo" {
                        let base = u.deletingPathExtension().lastPathComponent.lowercased()
                        subNFOByBase[base] = u
                        if base == "movie" { subMovieNFO = u }
                    }
                    let subPlayableCount = subURLs.filter { FolderMedia.extensions.contains($0.pathExtension.lowercased()) }.count
                    for u in subURLs {
                        try Task.checkCancellation()
                        guard let subValues = try? u.resourceValues(forKeys: Set(keys)),
                              subValues.isDirectory != true,
                              subValues.isRegularFile == true,
                              subValues.isSymbolicLink != true,
                              FolderMedia.extensions.contains(u.pathExtension.lowercased()) else {
                            // Strictly ignore 3rd-level folders and non-media files.
                            continue
                        }
                        let base = u.deletingPathExtension().lastPathComponent.lowercased()
                        let matchedNFO = subNFOByBase[base] ?? (subPlayableCount <= 2 ? subMovieNFO : nil)
                        if let matchedNFO, let parsed = MediaNFOCache.indexedLocalMetadata(matchedNFO) {
                            MediaNFOCache.shared.store(u.path, value: parsed)
                        }
                        extractedSecondLevel.append(
                            BrowserEntry(
                                id: u.path,
                                url: u,
                                name: u.lastPathComponent,
                                folder: false,
                                size: subValues.fileSize.map(Int64.init),
                                webDAVItem: nil,
                                nfoURL: matchedNFO,
                                relativeFolder: subName,
                                created: subValues.creationDate,
                                modified: subValues.contentModificationDate
                            )
                        )
                    }
                }
            }
            return (rootEntries, extractedSecondLevel)
        }
        do {
            let result = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
            guard !Task.isCancelled else { return }
            guard self.directory == directory, !isWebDAV else { return }
            let old = Dictionary((entries + secondLevelMediaEntries).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let fresh = Dictionary((result.root + result.secondLevel).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (id, previous) in old where fresh[id] != previous {
                ThumbnailImageCache.shared.remove(id)
                MediaNFOCache.shared.invalidateLocalPath(id)
            }
            if entries != result.root { entries = result.root }
            if secondLevelMediaEntries != result.secondLevel { secondLevelMediaEntries = result.secondLevel }
            if let id = expandedEntryID, old[id] != nil, fresh[id] == nil { expandedEntryID = nil }
            directoryWatcher.watch([directory] + (shouldExpandSubfolders ? result.root.filter(\.folder).map(\.url) : []))
            loading = false
            await scanLocalFolderTreeForTags(root: directory)
            if !Task.isCancelled { refreshing = false }
        } catch {
            guard !Task.isCancelled else { return }
            directoryWatcher.stop()
            failure = String(localized: "Unable to read this folder. Choose Folder to grant access.")
            loading = false; refreshing = false
        }
    }

    /// Recursively scans the current folder and its subfolders for playable media and `.nfo` files,
    /// populating `MediaNFOCache.shared` and building the tag capsule filter index.
    private func scanLocalFolderTreeForTags(root: URL) async {
        let scanTask = Task.detached(priority: .utility) { () -> (media: [BrowserEntry], tagsByID: [String: Set<String>], searchIndexByID: [String: String], summaries: [BrowserTagSummary]) in
            let rootPath = root.standardizedFileURL.path
            var filesByDir: [URL: [URL]] = [:]
            var sizesByURL: [URL: Int64] = [:]
            var totalFiles = 0, visitedEntries = 0
            var pending: [(URL, Int)] = [(root.standardizedFileURL, 0)]
            scan: while let (folder, depth) = pending.popLast() {
                for next in BrowserDirectoryIndex.files(folder) {
                    guard !Task.isCancelled else { return ([], [:], [:], []) }
                    visitedEntries += 1
                    if visitedEntries > 20_000 { break scan }
                    guard let values = try? next.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey, .isPackageKey]) else { continue }
                    if values.isDirectory == true {
                        if depth < 6 && values.isSymbolicLink != true && values.isPackage != true { pending.append((next, depth + 1)) }
                        continue
                    }
                    guard values.isRegularFile == true else { continue }
                    let ext = next.pathExtension.lowercased()
                    guard ext == "nfo" || FolderMedia.extensions.contains(ext) else { continue }
                    let dir = next.deletingLastPathComponent().standardizedFileURL
                    filesByDir[dir, default: []].append(next)
                    if let size = values.fileSize { sizesByURL[next] = Int64(size) }
                    totalFiles += 1
                    if totalFiles >= 2000 { break scan }
                }
            }

            var allMedia: [BrowserEntry] = []
            var tagsByID: [String: Set<String>] = [:]
            var searchIndexByID: [String: String] = [:]
            var displayByKey: [String: String] = [:]
            var countsByKey: [String: Int] = [:]
            var folderNFOCache: [URL: MediaNFOMetadata?] = [:]

            func folderNFO(for dir: URL, files: [URL]) -> MediaNFOMetadata? {
                if let existing = folderNFOCache[dir] { return existing }
                for name in ["tvshow.nfo", "movie.nfo", "\(dir.lastPathComponent.lowercased()).nfo"] {
                    if let match = files.first(where: { $0.lastPathComponent.lowercased() == name }),
                       let parsed = MediaNFOCache.indexedLocalMetadata(match) {
                        folderNFOCache[dir] = parsed
                        return parsed
                    }
                }
                if dir != root.standardizedFileURL {
                    let parent = dir.deletingLastPathComponent().standardizedFileURL
                    if let parentFiles = filesByDir[parent],
                       let match = parentFiles.first(where: { $0.lastPathComponent.lowercased() == "tvshow.nfo" }),
                       let parsed = MediaNFOCache.indexedLocalMetadata(match) {
                        folderNFOCache[dir] = parsed
                        return parsed
                    }
                }
                folderNFOCache[dir] = nil
                return nil
            }

            let sortedDirs = filesByDir.keys.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            for dir in sortedDirs {
                if Task.isCancelled { return ([], [:], [:], []) }
                let urls = filesByDir[dir] ?? []
                var nfoByBase: [String: URL] = [:]
                var movieNFO: URL? = nil
                for u in urls where u.pathExtension.lowercased() == "nfo" {
                    let base = u.deletingPathExtension().lastPathComponent.lowercased()
                    nfoByBase[base] = u
                    if base == "movie" { movieNFO = u }
                }
                let mediaURLs = urls.filter { FolderMedia.extensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                let playableCount = mediaURLs.count
                let inheritedNFO = folderNFO(for: dir, files: urls)

                let dirPath = dir.path
                let relFolder: String?
                if dirPath == rootPath {
                    relFolder = nil
                } else if dirPath.hasPrefix(rootPath + "/") {
                    relFolder = String(dirPath.dropFirst(rootPath.count + 1))
                } else {
                    relFolder = dir.lastPathComponent
                }

                for mediaURL in mediaURLs {
                    if Task.isCancelled { return ([], [:], [:], []) }
                    let base = mediaURL.deletingPathExtension().lastPathComponent.lowercased()
                    let matchedNFOURL = nfoByBase[base] ?? (playableCount <= 2 ? movieNFO : nil)
                    let entryID = mediaURL.path
                    let entry = BrowserEntry(
                        id: entryID,
                        url: mediaURL,
                        name: mediaURL.lastPathComponent,
                        folder: false,
                        size: sizesByURL[mediaURL],
                        webDAVItem: nil,
                        nfoURL: matchedNFOURL,
                        relativeFolder: relFolder,
                        created: (try? mediaURL.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                        modified: (try? mediaURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    )
                    allMedia.append(entry)

                    var resolvedNFO: MediaNFOMetadata? = nil
                    if let matchedNFOURL,
                              let parsed = MediaNFOCache.indexedLocalMetadata(matchedNFOURL) {
                        resolvedNFO = parsed
                        MediaNFOCache.shared.store(entryID, value: resolvedNFO)
                    }

                    // Merge item NFO tags/genres & searchable metadata with show/folder-level NFO
                    var combinedLabels: [String] = []
                    var searchChunks: [String] = []
                    if let resolvedNFO {
                        combinedLabels.append(contentsOf: resolvedNFO.genres)
                        combinedLabels.append(contentsOf: resolvedNFO.tags)
                        let text = resolvedNFO.searchableText
                        if !text.isEmpty { searchChunks.append(text) }
                    }
                    if let inheritedNFO {
                        combinedLabels.append(contentsOf: inheritedNFO.genres)
                        combinedLabels.append(contentsOf: inheritedNFO.tags)
                        let text = inheritedNFO.searchableText
                        if !text.isEmpty { searchChunks.append(text) }
                    }
                    if !searchChunks.isEmpty {
                        searchIndexByID[entryID] = searchChunks.joined(separator: "\n")
                    }

                    if !combinedLabels.isEmpty {
                        var itemKeys: Set<String> = []
                        for rawLabel in combinedLabels {
                            let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { continue }
                            let key = trimmed.lowercased()
                            if itemKeys.insert(key).inserted {
                                if displayByKey[key] == nil {
                                    displayByKey[key] = trimmed
                                }
                                countsByKey[key, default: 0] += 1
                            }
                        }
                        if !itemKeys.isEmpty {
                            tagsByID[entryID] = itemKeys
                        }
                    }
                }
            }

            let summaries = countsByKey.map { key, count in
                BrowserTagSummary(key: key, display: displayByKey[key] ?? key, count: count)
            }.sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                return a.display.localizedStandardCompare(b.display) == .orderedAscending
            }
            return (allMedia, tagsByID, searchIndexByID, summaries)
        }

        let result = await withTaskCancellationHandler {
            await scanTask.value
        } onCancel: {
            scanTask.cancel()
        }
        guard !Task.isCancelled, !isWebDAV, directory == root else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
            if subtreeMediaEntries != result.media { subtreeMediaEntries = result.media }
            if entryTagsByID != result.tagsByID { entryTagsByID = result.tagsByID }
            if entrySearchIndexByID != result.searchIndexByID { entrySearchIndexByID = result.searchIndexByID }
            if availableTags != result.summaries { availableTags = result.summaries }
        }
    }

    private func loadWebDAVFolder() async {
        guard let folderURL = davFolder, let creds = davCredentials else { return }
        let shouldExpandSubfolders = expandSubfolders
        failure = ""; loading = true
        var normalized = folderURL
        if !normalized.path.hasSuffix("/") { normalized.appendPathComponent("") }
        let cacheKey = RemoteBrowserMemory.davKey(normalized, user: creds.username, password: creds.password)
        if let rootURL = try? NetworkMediaRequest.parse(creds.address, webDAV: true),
           WebDAVDirectory.sameOrigin(normalized, rootURL) {
            let connKey = RemoteBrowserMemory.davKey(rootURL, user: creds.username, password: creds.password)
            RemoteBrowserMemory.rememberDAV(normalized, connection: connKey)
        }
        do {
            let davItems = try await WebDAVDirectory.read(normalized, username: creds.username, password: creds.password)
            guard !Task.isCancelled else { return }
            RemoteBrowserMemory.webDAV.store(
                .init(items: davItems, selection: [], updated: ProcessInfo.processInfo.systemUptime),
                for: cacheKey
            )
            var nfoByBase: [String: URL] = [:]
            var movieNFO: URL? = nil
            for item in davItems where !item.directory && (item.name as NSString).pathExtension.lowercased() == "nfo" {
                let base = ((item.name as NSString).deletingPathExtension).lowercased()
                nfoByBase[base] = item.url
                if base == "movie" { movieNFO = item.url }
            }
            let playableCount = davItems.filter {
                !$0.directory && NetworkMediaRequest.directFormats[($0.name as NSString).pathExtension.lowercased()] != nil
            }.count
            let loadedEntries = davItems.compactMap { item -> BrowserEntry? in
                let ext = (item.name as NSString).pathExtension.lowercased()
                guard item.directory || NetworkMediaRequest.directFormats[ext] != nil else { return nil }
                let base = ((item.name as NSString).deletingPathExtension).lowercased()
                let matchedNFO = item.directory ? nil : (nfoByBase[base] ?? (playableCount <= 2 ? movieNFO : nil))
                return BrowserEntry(
                    id: item.id,
                    url: item.url,
                    name: item.name,
                    folder: item.directory,
                    size: item.size,
                    webDAVItem: item,
                    nfoURL: matchedNFO, created: item.created, modified: item.modified
                )
            }

            var extractedSecondLevel: [BrowserEntry] = []
            if shouldExpandSubfolders {
                let davSubfolders = loadedEntries.filter(\.folder).prefix(24)
                for folderEntry in davSubfolders {
                    guard !Task.isCancelled else { return }
                    var subURL = folderEntry.url
                    if !subURL.path.hasSuffix("/") { subURL.appendPathComponent("") }
                    guard let subItems = try? await WebDAVDirectory.read(subURL, username: creds.username, password: creds.password) else {
                        continue
                    }
                    var subNFOByBase: [String: URL] = [:]
                    var subMovieNFO: URL? = nil
                    for item in subItems where !item.directory && (item.name as NSString).pathExtension.lowercased() == "nfo" {
                        let base = ((item.name as NSString).deletingPathExtension).lowercased()
                        subNFOByBase[base] = item.url
                        if base == "movie" { subMovieNFO = item.url }
                    }
                    let subPlayableCount = subItems.filter {
                        !$0.directory && NetworkMediaRequest.directFormats[($0.name as NSString).pathExtension.lowercased()] != nil
                    }.count
                    for subItem in subItems where !subItem.directory {
                        let ext = (subItem.name as NSString).pathExtension.lowercased()
                        guard NetworkMediaRequest.directFormats[ext] != nil else { continue }
                        let base = ((subItem.name as NSString).deletingPathExtension).lowercased()
                        let matchedNFO = subNFOByBase[base] ?? (subPlayableCount <= 2 ? subMovieNFO : nil)
                        extractedSecondLevel.append(
                            BrowserEntry(
                                id: subItem.id,
                                url: subItem.url,
                                name: subItem.name,
                                folder: false,
                                size: subItem.size,
                                webDAVItem: subItem,
                                nfoURL: matchedNFO,
                                relativeFolder: folderEntry.name,
                                created: subItem.created,
                                modified: subItem.modified
                            )
                        )
                    }
                }
            }

            entries = loadedEntries
            secondLevelMediaEntries = extractedSecondLevel
            loading = false
            await scanWebDAVEntriesForTags(entries: loadedEntries + extractedSecondLevel, credentials: creds)
        } catch {
            guard !Task.isCancelled else { return }
            loading = false
            failure = NetworkMediaError.message(for: error)
        }
    }

    private func scanWebDAVEntriesForTags(entries: [BrowserEntry], credentials: NetworkServerCredentials) async {
        let mediaEntries = entries.filter { !$0.folder }
        var tagsByID: [String: Set<String>] = [:]
        var searchIndexByID: [String: String] = [:]
        var displayByKey: [String: String] = [:]
        var countsByKey: [String: Int] = [:]

        for entry in mediaEntries where entry.nfoURL != nil {
            guard !Task.isCancelled else { return }
            if let nfo = await MediaNFOCache.shared.metadata(
                for: entry.id,
                localMediaURL: nil,
                nfoURL: entry.nfoURL,
                isFolder: false,
                credentials: credentials
            ) {
                let text = nfo.searchableText
                if !text.isEmpty { searchIndexByID[entry.id] = text }
                var itemKeys: Set<String> = []
                for rawLabel in (nfo.genres + nfo.tags) {
                    let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    let key = trimmed.lowercased()
                    if itemKeys.insert(key).inserted {
                        if displayByKey[key] == nil { displayByKey[key] = trimmed }
                        countsByKey[key, default: 0] += 1
                    }
                }
                if !itemKeys.isEmpty {
                    tagsByID[entry.id] = itemKeys
                }
            }
        }
        guard !Task.isCancelled else { return }
        let summaries = countsByKey.map { key, count in
            BrowserTagSummary(key: key, display: displayByKey[key] ?? key, count: count)
        }.sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            return a.display.localizedStandardCompare(b.display) == .orderedAscending
        }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
            subtreeMediaEntries = mediaEntries
            entryTagsByID = tagsByID
            entrySearchIndexByID = searchIndexByID
            availableTags = summaries
        }
    }
}

private struct ArtworkReflectionLayer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.backgroundPreferenceValue(QueueArtworkReflectionKey.self) { reflection in
            GeometryReader { geometry in
                if let reflection {
                    let bounds = geometry[reflection.bounds]
                    QueueArtworkReflectionView(image: reflection.image, size: bounds.size)
                        .frame(width: bounds.width, height: bounds.height)
                        .position(x: bounds.midX, y: bounds.midY)
                        .id(reflection.itemID).transition(.opacity)
                }
            }.clipped().allowsHitTesting(false).accessibilityHidden(true)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: reflection?.itemID)
        }
    }
}
