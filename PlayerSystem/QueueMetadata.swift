// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import AVFoundation
import ImageIO

/// Main-actor decoded thumbnail & metadata LRU cache with byte-budget eviction and
/// macOS system memory-pressure handling so scrolling rows never re-decode JPEG Data
/// or flash empty placeholders when revisiting visible items.
@MainActor final class ThumbnailImageCache {
    static let shared = ThumbnailImageCache()

    private struct Entry {
        var image: NSImage?
        var duration: Double?
        var size: Int64?
        var byteCost: Int
        var generation: UInt64
    }

    private var entries: [String: Entry] = [:]
    private var accessCounter: UInt64 = 0
    private var totalBytes = 0
    private let maxEntries = 180
    private let maxBytes = 24 * 1024 * 1024 // 24 MiB decoded pixel budget
    private let pressureSource: DispatchSourceMemoryPressure

    private init() {
        pressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        pressureSource.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let event = self.pressureSource.data
                if event.contains(.critical) {
                    self.clear()
                } else if event.contains(.warning) {
                    self.trim(toBytes: self.maxBytes / 3, maxCount: self.maxEntries / 2)
                }
            }
        }
        pressureSource.resume()
    }

    func lookup(_ key: String) -> (image: NSImage?, duration: Double?, size: Int64?)? {
        guard var entry = entries[key] else { return nil }
        accessCounter &+= 1
        entry.generation = accessCounter
        entries[key] = entry
        return (entry.image, entry.duration, entry.size)
    }

    func store(key: String, image: NSImage?, duration: Double?, size: Int64?) {
        let existing = entries[key]
        let mergedImage = image ?? existing?.image
        let mergedDuration = duration ?? existing?.duration
        let mergedSize = size ?? existing?.size
        let cost = Self.pixelByteCost(of: mergedImage)
        if let old = existing {
            totalBytes = max(0, totalBytes - old.byteCost)
        }
        accessCounter &+= 1
        entries[key] = Entry(
            image: mergedImage,
            duration: mergedDuration,
            size: mergedSize,
            byteCost: cost,
            generation: accessCounter
        )
        totalBytes += cost
        if entries.count > maxEntries || totalBytes > maxBytes {
            trim(toBytes: maxBytes, maxCount: maxEntries)
        }
    }

    func remove(_ key: String) {
        if let removed = entries.removeValue(forKey: key) {
            totalBytes = max(0, totalBytes - removed.byteCost)
        }
    }

    func clear() {
        entries.removeAll()
        totalBytes = 0
    }

    private func trim(toBytes byteBudget: Int, maxCount: Int) {
        guard entries.count > maxCount || totalBytes > byteBudget else { return }
        let sortedKeys = entries.sorted { $0.value.generation < $1.value.generation }.map(\.key)
        for key in sortedKeys {
            guard entries.count > maxCount || totalBytes > byteBudget else { break }
            remove(key)
        }
    }

    private static func pixelByteCost(of image: NSImage?) -> Int {
        guard let image else { return 0 }
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return max(256, cg.bytesPerRow * cg.height)
        }
        let w = max(1, Int(image.size.width))
        let h = max(1, Int(image.size.height))
        return w * h * 4
    }

    /// Decodes compressed thumbnail bytes off the main actor into a pre-rasterized CGImage-backed NSImage.
    nonisolated static func decodeImage(from data: Data, maxPixels: Int = 256, pixelSize: CGSize? = nil) -> NSImage? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        var limit = max(1, maxPixels)
        if let pixelSize, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
           let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
           width.doubleValue > 0, height.doubleValue > 0 {
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let rotated = (5...8).contains(orientation)
            let w = rotated ? height.doubleValue : width.doubleValue
            let h = rotated ? width.doubleValue : height.doubleValue
            let scale = min(1, max(pixelSize.width / w, pixelSize.height / h))
            limit = min(limit, max(1, Int(ceil(max(w, h) * scale))))
        }
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: limit,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// Coalesces identical encoded images and sizes across browser/queue rows.
/// Source bytes are part of the key, so replaced artwork cannot reuse a stale decode.
actor ThumbnailDecoder {
    static let shared = ThumbnailDecoder()
    private struct Key: Hashable { let data: Data; let maxPixels: Int; let width: Int; let height: Int }
    private struct Work {
        let id: UUID
        let task: Task<NSImage?, Never>
        var readers: Set<UUID>
    }
    private var pending: [Key: Work] = [:]

    func decode(_ data: Data, maxPixels: Int = 256, pixelSize: CGSize? = nil,
                priority: MediaReadPriority = .visible) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let key = Key(data: data, maxPixels: maxPixels, width: Int(ceil(pixelSize?.width ?? 0)),
                      height: Int(ceil(pixelSize?.height ?? 0))), reader = UUID()
        let work: Work
        if var existing = pending[key] {
            existing.readers.insert(reader)
            pending[key] = existing
            work = existing
            await QueueReadSlots.shared.promote(existing.id, to: priority)
        } else {
            let ticket = UUID()
            let task = Task.detached(priority: .utility) {
                guard await QueueReadSlots.shared.acquire(priority: priority, ticket: ticket) else { return nil as NSImage? }
                defer {
                    await withTaskCancellationShield { await QueueReadSlots.shared.release() }
                }
                guard !Task.isCancelled else { return nil }
                return ThumbnailImageCache.decodeImage(from: data, maxPixels: maxPixels, pixelSize: pixelSize)
            }
            work = Work(id: ticket, task: task, readers: [reader])
            pending[key] = work
        }
        return await withTaskCancellationHandler {
            let image = await work.task.value
            unsubscribe(key, id: work.id, reader: reader)
            return Task.isCancelled ? nil : image
        } onCancel: {
            Task { await self.unsubscribe(key, id: work.id, reader: reader) }
        }
    }

    private func unsubscribe(_ key: Key, id: UUID, reader: UUID) {
        guard var work = pending[key], work.id == id else { return }
        work.readers.remove(reader)
        if work.readers.isEmpty { work.task.cancel(); pending[key] = nil }
        else { pending[key] = work }
    }
}

// The blocking native read owns its FFmpeg state; only cancel touches an atomic.
private final class LocalQueueProbe: @unchecked Sendable {
    private let probe = RemoteMediaProbe()
    func cancel() { probe.cancel() }
    func read(_ path: String, cover: Bool) -> QueueMetadata {
        let raw = probe.readFile(path, cover: cover)
        return QueueMetadata(duration: (raw["duration"] as? NSNumber)?.doubleValue, cover: raw["cover"] as? Data, subtitleCount: (raw["subtitleCount"] as? NSNumber)?.intValue)
    }
}

actor QueueMetadataCache {
    static let shared = QueueMetadataCache()
    struct FileStamp: Hashable, Sendable {
        let modified: Date?
        let size: Int?
        static func read(_ filename: String) -> FileStamp? {
            guard filename.hasPrefix("/"), let info = try? URL(fileURLWithPath: filename).resourceValues(
                forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]), info.isRegularFile == true else { return nil }
            return FileStamp(modified: info.contentModificationDate, size: info.fileSize)
        }
    }
    private struct Key: Hashable { let filename: String; let cover: Bool; let stamp: FileStamp }
    private struct Entry {
        let id: UUID
        let task: Task<QueueMetadata, Never>
        var subscribers: Set<UUID>
    }
    private struct Cached {
        let stamp: FileStamp
        var value: QueueMetadata
        var coverChecked: Bool
        let retryAfter: Date
    }
    private var cache: [String: Cached] = [:]
    private var recency: [String] = []
    private var pending: [Key: Entry] = [:]
    private var coverBytes = 0

    private func remove(_ key: String) {
        coverBytes = max(0, coverBytes - (cache.removeValue(forKey: key)?.value.cover?.count ?? 0))
        recency.removeAll { $0 == key }
    }

    private func touch(_ key: String) {
        recency.removeAll { $0 == key }; recency.append(key)
        // First strip heavy cover bytes from oldest entries while retaining duration & size
        // so revisiting a row never has to re-probe duration/size from disk.
        if coverBytes > 16 * 1024 * 1024 {
            for candidate in recency where coverBytes > 12 * 1024 * 1024 {
                if var entry = cache[candidate], let bytes = entry.value.cover?.count {
                    coverBytes = max(0, coverBytes - bytes)
                    entry.value.cover = nil
                    entry.coverChecked = false
                    cache[candidate] = entry
                }
            }
        }
        while recency.count > 256 || coverBytes > 16 * 1024 * 1024 {
            guard let oldest = recency.first else { break }
            remove(oldest)
        }
    }

    private func unsubscribe(_ key: Key, id: UUID, subscriber: UUID) {
        guard var entry = pending[key], entry.id == id else { return }
        entry.subscribers.remove(subscriber)
        if entry.subscribers.isEmpty { entry.task.cancel(); pending[key] = nil }
        else { pending[key] = entry }
    }

    nonisolated private static func coverThumbnail(_ image: CGImage) -> CGImage? {
        let scale = min(1, min(320.0 / Double(image.width), 180.0 / Double(image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    private struct DedicatedCoverEntry {
        let stamp: FileStamp?
        let image: NSImage?
        let byteCost: Int
    }
    private static let dedicatedCoverLock = NSLock()
    private nonisolated(unsafe) static var dedicatedCoverCache: [String: DedicatedCoverEntry] = [:]
    private nonisolated(unsafe) static var dedicatedCoverOrder: [String] = []
    private nonisolated(unsafe) static var dedicatedCoverBytes = 0

    nonisolated static func cachedDedicatedArtwork(_ filename: String) -> (found: Bool, image: NSImage?) {
        guard filename.hasPrefix("/") else { return (false, nil) }
        dedicatedCoverLock.lock()
        defer { dedicatedCoverLock.unlock() }
        if let entry = dedicatedCoverCache[filename] {
            return (true, entry.image)
        }
        return (false, nil)
    }

    nonisolated private static func storeDedicatedArtwork(_ image: NSImage?, for filename: String, stamp: FileStamp?) {
        dedicatedCoverLock.lock()
        defer { dedicatedCoverLock.unlock() }
        // Count decoded representations, not compressed JPEG/PNG file sizes.
        let cost = image?.representations.reduce(0) { total, rep in
            total + min(32768, max(0, rep.pixelsWide)) * min(32768, max(0, rep.pixelsHigh)) * 4
        } ?? 0
        dedicatedCoverBytes -= dedicatedCoverCache[filename]?.byteCost ?? 0
        dedicatedCoverCache[filename] = DedicatedCoverEntry(stamp: stamp, image: image, byteCost: cost)
        dedicatedCoverBytes += cost
        dedicatedCoverOrder.removeAll { $0 == filename }
        dedicatedCoverOrder.append(filename)
        while dedicatedCoverOrder.count > 96 || dedicatedCoverBytes > 64 * 1024 * 1024 {
            let oldest = dedicatedCoverOrder.removeFirst()
            dedicatedCoverBytes -= dedicatedCoverCache.removeValue(forKey: oldest)?.byteCost ?? 0
        }
    }

    nonisolated static func dedicatedArtwork(_ filename: String, maxPixels: Int = 900) -> NSImage? {
        guard filename.hasPrefix("/") else { return nil }
        let stamp = FileStamp.read(filename)
        dedicatedCoverLock.lock()
        if let existing = dedicatedCoverCache[filename], existing.stamp == stamp {
            let cachedImage = existing.image
            dedicatedCoverLock.unlock()
            return cachedImage
        }
        dedicatedCoverLock.unlock()

        if let sidecar = sidecarCoverImage(filename, maxPixels: maxPixels) {
            storeDedicatedArtwork(sidecar, for: filename, stamp: stamp)
            return sidecar
        }
        if let attachedData = RemoteMediaProbe().readAttachedCover(filename),
           let source = CGImageSourceCreateWithData(attachedData as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: maxPixels,
               kCGImageSourceShouldCacheImmediately: true
           ] as CFDictionary) {
            let embedded = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            storeDedicatedArtwork(embedded, for: filename, stamp: stamp)
            return embedded
        }
        storeDedicatedArtwork(nil, for: filename, stamp: stamp)
        return nil
    }

    func updateCoverCache(for filename: String, detailImage: NSImage, thumbData: Data?) {
        let stamp = FileStamp.read(filename)
        Self.storeDedicatedArtwork(detailImage, for: filename, stamp: stamp)
        if let stamp {
            let oldDuration = cache[filename]?.value.duration
            let oldSubCount = cache[filename]?.value.subtitleCount
            remove(filename)
            if let thumbData {
                let updated = QueueMetadata(
                    duration: oldDuration,
                    size: stamp.size.map(Int64.init),
                    cover: thumbData,
                    subtitleCount: oldSubCount
                )
                cache[filename] = Cached(
                    stamp: stamp,
                    value: updated,
                    coverChecked: true,
                    retryAfter: Date().addingTimeInterval(300)
                )
                coverBytes += thumbData.count
                touch(filename)
            }
        }
    }

    nonisolated static func detailArtwork(_ filename: String) -> NSImage? {
        dedicatedArtwork(filename, maxPixels: 900)
    }

    nonisolated private static func sidecarCoverImage(_ filename: String, maxPixels: Int = 900) -> NSImage? {
        let media = URL(fileURLWithPath: filename), folder = media.deletingLastPathComponent()
        let base = media.deletingPathExtension().lastPathComponent
        for stem in [base + "-poster", base + "-cover", base + "-thumb", base, "poster", "folder", "cover", "front"] {
            for ext in ["jpg", "jpeg", "png", "heic", "webp"] {
                let url = folder.appendingPathComponent(stem).appendingPathExtension(ext)
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                        kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { continue }
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }
        return nil
    }

    nonisolated private static func sidecarCover(_ filename: String, maxPixels: Int = 320) -> Data? {
        let media = URL(fileURLWithPath: filename), folder = URL(fileURLWithPath: filename).deletingLastPathComponent()
        let base = media.deletingPathExtension().lastPathComponent
        for stem in [base + "-poster", base + "-cover", base + "-thumb", base, "poster", "folder", "cover", "front"] {
            for ext in ["jpg", "jpeg", "png", "heic", "webp"] {
                let url = folder.appendingPathComponent(stem).appendingPathExtension(ext)
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary) else { continue }
                let data = NSMutableData()
                guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                if CGImageDestinationFinalize(dest) { return data as Data }
            }
        }
        return nil
    }

    func read(_ filename: String, cover: Bool, priority: MediaReadPriority = .visible) async -> QueueMetadata {
        guard !Task.isCancelled else { return QueueMetadata() }
        guard let stamp = FileStamp.read(filename) else {
            remove(filename)
            await MainActor.run { ThumbnailImageCache.shared.remove(filename) }
            return QueueMetadata()
        }
        if let cached = cache[filename], cached.stamp != stamp {
            remove(filename)
            await MainActor.run { ThumbnailImageCache.shared.remove(filename) }
        }
        if let cached = cache[filename], (!cover || cached.coverChecked),
           (cached.value.duration != nil && (!cover || cached.value.cover != nil)) || cached.retryAfter > Date() {
            touch(filename); return cached.value
        }
        let requested = Key(filename: filename, cover: cover, stamp: stamp)
        let full = Key(filename: filename, cover: true, stamp: stamp)
        let basic = Key(filename: filename, cover: false, stamp: stamp)
        // Basic subscribers can share a detailed read. A detailed upgrade waits
        // for the existing basic read, then reuses its duration instead of probing twice.
        let key = !cover && pending[full] != nil ? full : requested
        if cover, pending[key] == nil, pending[basic] != nil, cache[filename] == nil {
            _ = await read(filename, cover: false, priority: priority)
            guard !Task.isCancelled else { return QueueMetadata() }
            return await read(filename, cover: true, priority: priority)
        }
        let subscriber = UUID()
        let entry: Entry
        if var existing = pending[key] {
            existing.subscribers.insert(subscriber); pending[key] = existing; entry = existing
            await QueueReadSlots.shared.promote(existing.id, to: priority)
        } else {
            let seed = cache[filename]?.value
            let ticket = UUID()
            let task = Task.detached(priority: .utility) {
                guard await QueueReadSlots.shared.acquire(priority: priority, ticket: ticket) else { return QueueMetadata() }
                defer {
                    await withTaskCancellationShield {
                        await QueueReadSlots.shared.release()
                    }
                }
                let artwork = cover ? (Self.sidecarCover(filename) ?? seed?.cover) : seed?.cover
                // Use the existing bounded FFmpeg probe directly for non-AVFoundation containers.
                if ["mkv", "webm", "avi", "ts", "m2ts"].contains(URL(fileURLWithPath: filename).pathExtension.lowercased()) {
                    let probe = LocalQueueProbe()
                    var native = await withTaskCancellationHandler {
                        await Task.detached(priority: .utility) { probe.read(filename, cover: cover && artwork == nil) }.value
                    } onCancel: { probe.cancel() }
                    native.cover = artwork ?? native.cover
                    native.size = stamp.size.map(Int64.init)
                    return native
                }
                let asset = AVURLAsset(url: URL(fileURLWithPath: filename))
                let generator = AssetImageReader(asset: asset, maximumSize: CGSize(width: 320, height: 180), tolerance: .positiveInfinity)
                let result: QueueMetadata? = await mediaReadWithDeadline(seconds: 6, cancel: {
                    asset.cancelLoading(); generator.cancelAllCGImageGeneration()
                }) {
                    let attributes = try? URL(fileURLWithPath: filename).resourceValues(forKeys: [.fileSizeKey])
                    var result = QueueMetadata(duration: seed?.duration, size: attributes?.fileSize.map(Int64.init), cover: artwork)
                    if result.duration == nil, let time = try? await asset.load(.duration), time.seconds.isFinite, time.seconds > 0 { result.duration = time.seconds }
                    guard !Task.isCancelled else { return nil }
                    var coverImage: CGImage?
                    if cover && result.cover == nil {
                        if FolderMedia.audioExtensions.contains(URL(fileURLWithPath: filename).pathExtension.lowercased()) {
                            coverImage = await AudioArtworkReader.read(path: filename, embedded: false)
                        } else {
                            coverImage = try? await generator.image(at: CMTime(seconds: min(5, (result.duration ?? 0) * 0.1), preferredTimescale: 600)).image
                        }
                    }
                    if let image = coverImage {
                        let data = NSMutableData()
                        if let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) {
                            let scaled = Self.coverThumbnail(image) ?? image
                            CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
                            if CGImageDestinationFinalize(destination) { result.cover = data as Data }
                        }
                    }
                    return result
                }
                var merged = result ?? QueueMetadata(duration: seed?.duration, size: stamp.size.map(Int64.init), cover: artwork)
                if !Task.isCancelled && (merged.duration == nil || (cover && merged.cover == nil)) {
                    let probe = LocalQueueProbe(), needsCover = cover && merged.cover == nil
                    // Keep the slot until the native reader has actually exited.
                    let native = await withTaskCancellationHandler {
                        await Task.detached(priority: .utility) { probe.read(filename, cover: needsCover) }.value
                    } onCancel: { probe.cancel() }
                    merged.duration = merged.duration ?? native.duration
                    merged.cover = merged.cover ?? native.cover
                    merged.subtitleCount = merged.subtitleCount ?? native.subtitleCount
                }
                return merged
            }
            entry = Entry(id: ticket, task: task, subscribers: [subscriber]); pending[key] = entry
        }
        return await withTaskCancellationHandler {
            let result = await entry.task.value
            let valid = !Task.isCancelled && FileStamp.read(filename) == stamp
            if valid, pending[key]?.id == entry.id {
                // Partial/missing metadata expires, rather than caching a failed
                // duration/cover read forever merely because file size was available.
                remove(filename)
                cache[filename] = Cached(stamp: stamp, value: result, coverChecked: key.cover || result.cover != nil,
                                         retryAfter: Date().addingTimeInterval(30))
                coverBytes += result.cover?.count ?? 0; touch(filename)
            }
            unsubscribe(key, id: entry.id, subscriber: subscriber)
            return valid ? result : QueueMetadata()
        } onCancel: { Task { await self.unsubscribe(key, id: entry.id, subscriber: subscriber) } }
    }
}
