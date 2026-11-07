import Foundation
import ImageIO

// Gate only the decoder completion; the production cache/coalescing logic is unchanged.
private actor DecodeProbe {
    private(set) var count = 0
    private var gates: [CheckedContinuation<Void, Never>] = []
    func begin() async {
        count += 1
        await withCheckedContinuation { gates.append($0) }
    }
    func release() { let pending = gates; gates.removeAll(); for gate in pending { gate.resume() } }
}

@main struct AudioArtworkDecodeSmoke {
    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        for filename in ["covered.mp3", "covered.flac"] {
            guard let image = await FFmpegPreviewDecoder().decodeArtwork(path: folder.appendingPathComponent(filename).path) else {
                fatalError("Embedded cover missing: \(filename)")
            }
            precondition(image.width > 0 && image.height > 0 && image.width <= 1024 && image.height <= 1024)
            print("PASS: \(filename) embedded artwork \(image.width)×\(image.height)")
        }
        let absent = await FFmpegPreviewDecoder().decodeArtwork(path: folder.appendingPathComponent("plain.wav").path)
        precondition(absent == nil)
        let canceled = FFmpegPreviewDecoder(); canceled.cancel()
        let image = await canceled.decodeArtwork(path: folder.appendingPathComponent("covered.mp3").path)
        precondition(image == nil)
        print("PASS: absent cover and canceled decoder return no image")

        guard let cover = await FFmpegPreviewDecoder().decodeArtwork(path: folder.appendingPathComponent("covered.mp3").path) else { fatalError("Fixture missing") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("iive-artwork-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let copyURL = temporary.appendingPathComponent("sample.mp3")
        try FileManager.default.copyItem(at: folder.appendingPathComponent("covered.mp3"), to: copyURL)
        let probe = DecodeProbe()
        let cache = AudioArtworkCache(decoder: { _, _ in await probe.begin(); return cover })
        let leader = Task { await cache.readOrCoalesce(path: copyURL.path, embedded: false) }
        try await Task.sleep(for: .milliseconds(30))
        let follower = Task { await cache.readOrCoalesce(path: copyURL.path, embedded: true) }
        let canceledSubscriber = Task { await cache.readOrCoalesce(path: copyURL.path, embedded: true) }
        try await Task.sleep(for: .milliseconds(30))
        let count = await probe.count
        precondition(count == 1, "Mixed embedded hints must share exactly one decode")
        leader.cancel(); canceledSubscriber.cancel()
        await probe.release()
        let leaderImage = await leader.value, followerImage = await follower.value, canceledImage = await canceledSubscriber.value
        precondition(leaderImage == nil && canceledImage == nil && followerImage != nil)
        let cached = await cache.cachedImageIfValid(for: copyURL.path)
        precondition(cached != nil, "Canceling the leader must not prevent shared cache insertion")
        print("PASS: exactly one decode for mixed hints; canceled subscribers return nil; survivor populates cache")

        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: copyURL.path)
        let invalidated = await cache.cachedImageIfValid(for: copyURL.path)
        precondition(invalidated == nil)
        let stale = Task { await cache.readOrCoalesce(path: copyURL.path, embedded: true) }
        try await Task.sleep(for: .milliseconds(30))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(20)], ofItemAtPath: copyURL.path)
        await probe.release()
        let staleImage = await stale.value
        let staleCache = await cache.cachedImageIfValid(for: copyURL.path)
        precondition(staleImage == nil && staleCache == nil, "A changed file must reject an in-flight old result")
        print("PASS: mtime invalidation and mutation during decode reject stale results")

        let sidecarCache = AudioArtworkCache(decoder: { _, _ in cover })
        _ = await sidecarCache.readOrCoalesce(path: copyURL.path, embedded: true)
        try FileManager.default.copyItem(at: folder.appendingPathComponent("cover.png"), to: temporary.appendingPathComponent("cover.png"))
        let changedCover = await sidecarCache.cachedImageIfValid(for: copyURL.path)
        precondition(changedCover == nil, "Creating an adjacent cover must invalidate the cache")
        print("PASS: adjacent artwork changes invalidate cache")
    }
}
