import Foundation
import AVFoundation
import ImageIO

@main struct QueueMetadataSmoke {
    static func verify(_ condition: Bool, line: UInt = #line) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: QueueMetadataSmoke line \(line)\n".utf8))
            exit(1)
        }
    }
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let file = directory.appendingPathComponent("track.wav")
        let cache = QueueMetadataCache()
        let mkv = await cache.read(directory.appendingPathComponent("clip.mkv").path, cover: true)
        verify(abs((mkv.duration ?? 0) - 2) < 0.1 && mkv.cover != nil)
        // ImageIO downsamples during decode instead of rasterizing a large source first.
        let big = CGContext(data: nil, width: 1600, height: 2400, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        big.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.4, alpha: 1))
        big.fill(CGRect(x: 0, y: 0, width: 1600, height: 2400))
        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, big.makeImage()!, nil)
        verify(CGImageDestinationFinalize(destination))
        let slotA = await QueueReadSlots.shared.acquire(), slotB = await QueueReadSlots.shared.acquire()
        verify(slotA && slotB)
        let imageData = encoded as Data
        let jobs = (0..<6).map { _ in Task { await ThumbnailDecoder.shared.decode(imageData) } }
        try? await Task.sleep(for: .milliseconds(50))
        await QueueReadSlots.shared.release(); await QueueReadSlots.shared.release()
        var identities = Set<ObjectIdentifier>()
        for job in jobs {
            let image = (await job.value)!
            verify(max(image.size.width, image.size.height) <= 256)
            identities.insert(ObjectIdentifier(image))
        }
        verify(identities.count == 1)
        let fitted = await ThumbnailDecoder.shared.decode(imageData, maxPixels: 512,
                                                          pixelSize: CGSize(width: 152, height: 88))
        verify(fitted != nil && fitted!.size.width >= 151 && fitted!.size.width <= 153 && fitted!.size.height <= 229)
        print("PASS: bounded portrait decode and six coalesced thumbnail subscribers")
        let direct = RemoteMediaProbe()
        verify(direct.readFile("https://example.invalid/file.mkv", cover: true).isEmpty)
        verify(direct.readFile("/dev/null", cover: true).isEmpty)
        direct.cancel()
        verify(direct.readFile(directory.appendingPathComponent("clip.mkv").path, cover: true).isEmpty)
        print("PASS: local MKV duration + thumbnail fallback; URL/device/cancel rejection")
        let basic = await cache.read(file.path, cover: false)
        verify(abs((basic.duration ?? 0) - 1) < 0.01 && basic.size != nil)
        let context = CGContext(data: nil, width: 640, height: 640, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
        let image = context.makeImage()!
        let output = CGImageDestinationCreateWithURL(directory.appendingPathComponent("cover.jpg") as CFURL,
                                                    "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(output, image, nil)
        verify(CGImageDestinationFinalize(output))
        let detailed = await cache.read(file.path, cover: true)
        verify(detailed.duration == basic.duration)
        let bytes = detailed.cover!
        let source = CGImageSourceCreateWithData(bytes as CFData, nil)!
        let thumbnail = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        // Sidecar covers preserve their aspect ratio in the 320-pixel source cache.
        verify(thumbnail.width <= 320 && thumbnail.height <= 320)
        let concurrentCache = QueueMetadataCache()
        let shared = await withTaskGroup(of: QueueMetadata.self, returning: [QueueMetadata].self) { group in
            for index in 0..<12 { group.addTask { await concurrentCache.read(file.path, cover: index % 2 == 0) } }
            var values: [QueueMetadata] = []
            for await value in group { values.append(value) }
            return values
        }
        verify(shared.count == 12 && shared.allSatisfy { $0.duration == basic.duration })
        // Same path, different bytes/duration must invalidate the cached result.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.copyItem(at: directory.appendingPathComponent("replacement.wav"), to: file)
        let changed = await cache.read(file.path, cover: false)
        verify(abs((changed.duration ?? 0) - 2) < 0.01 && changed.size != basic.size)
        let canceled = Task { await cache.read(file.path, cover: true) }
        canceled.cancel()
        let canceledResult = await canceled.value
        verify(canceledResult.duration == nil)
        let retained = await cache.read(file.path, cover: false)
        verify(retained.duration == changed.duration)
        try FileManager.default.removeItem(at: file)
        let missing = await cache.read(file.path, cover: false)
        verify(missing.duration == nil && missing.cover == nil)
        print("PASS: basic/detail reuse, bounded thumbnail, concurrent reads, replacement, cancellation, deletion")
    }
}
