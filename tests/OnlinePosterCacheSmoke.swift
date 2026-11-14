import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

actor DownloadCounter {
    var count = 0
    func record() { count += 1 }
}
@main struct OnlinePosterCacheSmoke {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        let bytes = encoded as Data
        let count = DownloadCounter()
        let cache = OnlinePosterCache(directory: root) { _ in
            await count.record()
            try? await Task.sleep(for: .milliseconds(80))
            return bytes
        }
        let url = URL(string: "https://image.tmdb.org/t/p/w500/example.png")!
        precondition(OnlinePosterCache.accepts(url))
        precondition(!OnlinePosterCache.accepts(URL(string: "https://example.org/t/p/w500/example.png")!))
        precondition(!OnlinePosterCache.accepts(URL(string: "https://image.tmdb.org/t/p/w500/example.png?token=secret")!))
        async let first = cache.image(for: url)
        async let second = cache.image(for: url)
        let pair = await (first, second)
        precondition(pair.0?.width == 8 && pair.1?.width == 8)
        let initialCount = await count.count; precondition(initialCount == 1)
        let memory = await cache.image(for: url); precondition(memory != nil)
        let disk = OnlinePosterCache(directory: root) { _ in await count.record(); return nil }
        let restored = await disk.image(for: url); precondition(restored?.width == 8)
        let diskCount = await count.count; precondition(diskCount == 1)
        await cache.clear()
        precondition(!FileManager.default.fileExists(atPath: root.path))
        let restarted = await cache.image(for: url); precondition(restarted != nil)
        let restartedCount = await count.count; precondition(restartedCount == 2)
        await cache.clear()
        let pending = Task { await cache.image(for: url) }
        try await Task.sleep(for: .milliseconds(20))
        await cache.clear()
        let cancelled = await pending.value
        precondition(cancelled == nil && !FileManager.default.fileExists(atPath: root.path))
        let automaticURL = URL(string: "https://image.tmdb.org/t/p/w500/automatic.png")!
        await cache.prefetch([automaticURL, automaticURL])
        // Wait for the background operation to persist, without showing a view.
        for _ in 0..<100 {
            if (try? FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty) == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let offline = OnlinePosterCache(directory: root) { _ in nil }
        let automatic = await offline.image(for: automaticURL)
        precondition(automatic?.width == 8)
        print("PASS: URL policy, coalescing, memory/disk reuse, clear and in-flight invalidation")
    }
}
