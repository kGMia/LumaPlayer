// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AVFoundation
import ImageIO

/// Shared bounded artwork cache across main/mini AudioArtworkState, Now Playing, and QueueMetadataCache.
/// Supports 64 MiB decoded pixel budget, file modification/size invalidation, and in-flight request coalescing.
actor AudioArtworkCache {
    static let shared = AudioArtworkCache()
    typealias Decoder = @Sendable (String, Bool) async -> CGImage?
    static let coverNames = ["cover.jpg", "cover.png", "folder.jpg", "folder.png", "front.jpg", "front.png"]

    struct FileStamp: Hashable, Sendable {
        struct Cover: Hashable, Sendable {
            let name: String
            let modified: TimeInterval
            let size: Int
        }
        let modified: TimeInterval
        let size: Int64
        let covers: [Cover]
    }
    private struct Entry {
        let stamp: FileStamp
        let image: CGImage?
        let embeddedChecked: Bool
        var byteCost: Int { image.map { $0.bytesPerRow * $0.height } ?? 0 }
    }
    private struct InflightKey: Hashable {
        let path: String
        let stamp: FileStamp
        let embedded: Bool
    }
    private var storage: [String: Entry] = [:]
    private var order: [String] = []
    private var inflight: [InflightKey: Task<CGImage?, Never>] = [:]
    private let decoder: Decoder
    private let capacity = 64
    private let byteLimit = 64 * 1024 * 1024
    private var byteCost = 0

    init() { decoder = { await AudioArtworkReader.decodeUncached(path: $0, embedded: $1) } }
    // Supports deterministic concurrency checks without substituting the cache logic.
    init(decoder: @escaping Decoder) { self.decoder = decoder }

    nonisolated static func fileStamp(for path: String) -> FileStamp? {
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
        let covers = coverNames.compactMap { name -> FileStamp.Cover? in
            let cover = url.deletingLastPathComponent().appendingPathComponent(name)
            guard let value = try? cover.resourceValues(forKeys: keys), value.isRegularFile == true else { return nil }
            return .init(name: name, modified: value.contentModificationDate?.timeIntervalSince1970 ?? 0, size: value.fileSize ?? 0)
        }
        return FileStamp(modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                         size: Int64(values.fileSize ?? 0), covers: covers)
    }

    func readOrCoalesce(path: String, embedded: Bool) async -> CGImage? {
        guard let stamp = Self.fileStamp(for: path), !Task.isCancelled else { return nil }
        let requiresEmbedded = AudioArtworkReader.allowsAttachedPicture(path: path, embedded: embedded)
        if let entry = storage[path] {
            if entry.stamp == stamp {
                if entry.image != nil || !requiresEmbedded || entry.embeddedChecked {
                    touch(path); return entry.image
                }
            } else { removeEntry(for: path) }
        }
        let key = InflightKey(path: path, stamp: stamp, embedded: requiresEmbedded)
        let sharedTask: Task<CGImage?, Never>
        if let existing = inflight[key] ?? (!requiresEmbedded ? inflight[InflightKey(path: path, stamp: stamp, embedded: true)] : nil) {
            sharedTask = existing
        } else {
            let decode = decoder
            let task = Task.detached(priority: .utility) { [self] in
                let result = await decode(path, requiresEmbedded)
                return await finish(key, image: result)
            }
            inflight[key] = task
            sharedTask = task
        }
        let image = await sharedTask.value
        // All subscribers, including followers, observe cancellation and file replacement.
        // The shared task owns completion/cache insertion independently of its first caller.
        guard !Task.isCancelled, Self.fileStamp(for: path) == stamp else { return nil }
        return image
    }

    private func finish(_ key: InflightKey, image: CGImage?) -> CGImage? {
        inflight.removeValue(forKey: key)
        guard Self.fileStamp(for: key.path) == key.stamp else { return nil }
        store(image: image, for: key.path, stamp: key.stamp, embeddedChecked: key.embedded)
        return image
    }

    func cachedImageIfValid(for path: String) -> CGImage? {
        guard let entry = storage[path] else { return nil }
        guard Self.fileStamp(for: path) == entry.stamp else { removeEntry(for: path); return nil }
        touch(path); return entry.image
    }
    private func removeEntry(for path: String) {
        if let removed = storage.removeValue(forKey: path) { byteCost -= removed.byteCost }
        order.removeAll { $0 == path }
    }
    private func store(image: CGImage?, for path: String, stamp: FileStamp, embeddedChecked: Bool) {
        if let existing = storage[path], existing.stamp == stamp, existing.image != nil && image == nil {
            touch(path); return
        }
        let prevChecked = storage[path]?.stamp == stamp ? (storage[path]?.embeddedChecked ?? false) : false
        byteCost -= storage[path]?.byteCost ?? 0
        storage[path] = Entry(stamp: stamp, image: image, embeddedChecked: embeddedChecked || prevChecked)
        byteCost += storage[path]?.byteCost ?? 0
        touch(path)
        while order.count > capacity || byteCost > byteLimit {
            let old = order.removeFirst()
            byteCost -= storage.removeValue(forKey: old)?.byteCost ?? 0
        }
    }
    private func touch(_ key: String) {
        order.removeAll { $0 == key }; order.append(key)
    }
}

/// Local artwork only. Decode a bounded thumbnail off the main actor.
enum AudioArtworkReader {
    static func thumbnail(_ data: Data) -> CGImage? {
        guard data.count <= 32 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    static func allowsAttachedPicture(path: String, embedded: Bool) -> Bool {
        embedded || ["flac", "mp3", "m4a", "ogg", "opus", "mka", "wv", "ape"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
    static func read(path: String, embedded: Bool) async -> CGImage? {
        guard path.hasPrefix("/"), !Task.isCancelled else { return nil }
        return await AudioArtworkCache.shared.readOrCoalesce(path: path, embedded: embedded)
    }

    fileprivate static func decodeUncached(path: String, embedded: Bool) async -> CGImage? {
        guard path.hasPrefix("/"), !Task.isCancelled else { return nil }
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let data: Data? = await mediaReadWithDeadline(seconds: 3, cancel: { asset.cancelLoading() }) {
            guard let items = try? await asset.load(.commonMetadata) else { return nil }
            for item in items where item.commonKey == .commonKeyArtwork {
                if let data = try? await item.load(.dataValue), data.count <= 32 * 1024 * 1024 { return data }
            }
            return nil
        }
        guard !Task.isCancelled else { return nil }
        if let data, let image = thumbnail(data) { return image }
        // Only run FFmpeg attached-picture extraction when embedded attached-pic stream is confirmed
        // or for audio containers that carry attached picture streams.
        let allowFFmpegAttachedPic = allowsAttachedPicture(path: path, embedded: embedded)
        if allowFFmpegAttachedPic, let image = await FFmpegPreviewDecoder().decodeArtwork(path: path) {
            return image
        }
        guard !Task.isCancelled else { return nil }
        // Conventional adjacent covers; no recursive scan or network artwork.
        for name in AudioArtworkCache.coverNames {
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            guard let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize, size <= 32 * 1024 * 1024,
                  let bytes = try? Data(contentsOf: candidate, options: .mappedIfSafe) else { continue }
            if let image = thumbnail(bytes) { return image }
        }
        return nil
    }
}

@MainActor @Observable final class AudioArtworkState {
    private(set) var image: NSImage?
    @ObservationIgnored private(set) var revision = 0
    @ObservationIgnored private var key = ""
    @ObservationIgnored private var activePath = ""
    @ObservationIgnored private var displayedImage: CGImage?
    @ObservationIgnored private var lastProbe: TimeInterval = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    func update(path: String, embedded: Bool) {
        // No filesystem work on the main actor or on every playback snapshot.
        let now = ProcessInfo.processInfo.systemUptime
        let desired = path.isEmpty ? "" : "\(path)|\(embedded)"
        if desired == key && (path.isEmpty || task != nil || now - lastProbe < 2) { return }
        lastProbe = now
        task?.cancel(); task = nil; key = desired
        guard !path.isEmpty else {
            activePath = ""; displayedImage = nil
            if image != nil { image = nil; revision &+= 1 }
            return
        }
        if activePath != path {
            activePath = path
            displayedImage = nil
            image = nil
            revision &+= 1
        }
        task = Task { [weak self] in
            let result = await AudioArtworkReader.read(path: path, embedded: embedded)
            guard !Task.isCancelled, let self, self.key == desired else { return }
            if result !== self.displayedImage {
                self.displayedImage = result
                self.image = result.map { NSImage(cgImage: $0, size: .zero) }
                self.revision &+= 1
            }
            self.task = nil
        }
    }
    func clear() { update(path: "", embedded: false) }
}

/// Hit testing stays with VideoView, preserving canvas clicks, scrolling and menus.
struct AudioArtworkView: View {
    let artwork: AudioArtworkState
    let title: String
    let artist: String
    let album: String
    var compact = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let side = max(80, min(420, geometry.size.width * 0.52, geometry.size.height * 0.55))
            ZStack {
                Color.black
                if compact, let image = artwork.image {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        .id(artwork.revision).transition(.opacity)
                    LinearGradient(colors: [.black.opacity(0.12), .clear, .black.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom)
                } else {
                    if let image = artwork.image, !reduceTransparency {
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(width: side * 1.2, height: side * 1.2)
                            .blur(radius: 48).opacity(0.5)
                            .offset(y: -26)
                            .id(artwork.revision).transition(.opacity)
                    }
                    VStack(spacing: 18) {
                        ZStack {
                            if let image = artwork.image {
                                Image(nsImage: image).resizable().scaledToFit()
                                    .id(artwork.revision).transition(.opacity)
                            } else {
                                RoundedRectangle(cornerRadius: 20)
                                    .fill(.white.opacity(0.07))
                                    .overlay { Image(systemName: "music.note").font(.system(size: side * 0.3)).foregroundStyle(.secondary) }
                            }
                        }
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
                        VStack(spacing: 5) {
                            Text(title).font(compact ? .headline : .title2.weight(.semibold)).lineLimit(1)
                                .contentTransition(.opacity)
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: title)
                            if !artist.isEmpty { Text(artist).foregroundStyle(.secondary).lineLimit(1) }
                            if !album.isEmpty && !compact { Text(album).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                        }.frame(maxWidth: min(geometry.size.width - 40, 560))
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: artwork.revision)
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }
}
