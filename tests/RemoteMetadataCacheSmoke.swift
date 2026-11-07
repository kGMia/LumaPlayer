// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

private actor Reads {
    var count = 0, active = 0, peak = 0
    func begin() { count += 1; active += 1; peak = max(peak, active) }
    func end() { active -= 1 }
    func stats() -> (Int, Int, Int) { (count, active, peak) }
    func load() async -> QueueMetadata? {
        begin()
        defer { end() }
        do { try await Task.sleep(nanoseconds: 80_000_000) } catch { return nil }
        return QueueMetadata(duration: 42, size: 100, cover: Data([1, 2, 3]))
    }
}
// Deliberately ignores Task cancellation, like an I/O operation that still
// needs to unwind its native reader before releasing the serial lane.
private actor HeldRead {
    private var continuation: CheckedContinuation<QueueMetadata?, Never>?
    func started() -> Bool { continuation != nil }
    func load() async -> QueueMetadata? {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume(returning: QueueMetadata(duration: 999, size: 100))
        continuation = nil
    }
}
@main enum RemoteMetadataCacheSmoke {
    static func main() async {
        let partial = RemoteQueueMetadataCache(settleNanoseconds: 0, incompleteTTL: 0)
        let first = await partial.read(key: "partial", size: 10, cover: true) { QueueMetadata(duration: 42) }
        let recovered = await partial.read(key: "partial", size: 10, cover: true) { QueueMetadata(cover: Data([1])) }
        precondition(first.duration == 42 && first.cover == nil && recovered.duration == 42 && recovered.cover != nil)
        print("PASS: partial thumbnail failure expires and retries while preserving duration")
        let cache = RemoteQueueMetadataCache(settleNanoseconds: 0)
        let reads = Reads()
        let detail = await cache.read(key: "media", size: 100, cover: true) { await reads.load() }
        precondition(detail.duration == 42)
        let basic = await cache.read(key: "media", size: 100, cover: false) { await reads.load() }
        precondition(basic.duration == 42)
        let held = await cache.read(key: "media", size: 100, cover: true, allowLoad: false) { await reads.load() }
        let missing = await cache.read(key: "unseen", size: 101, cover: true, allowLoad: false) { await reads.load() }
        precondition(held.cover == detail.cover && missing.duration == nil && missing.size == 101)
        let cachedStats = await reads.stats(); precondition(cachedStats.0 == 1)

        await withTaskGroup(of: QueueMetadata.self) { group in
            for _ in 0..<10 {
                group.addTask { await cache.read(key: "coalesced", size: 100, cover: true) { await reads.load() } }
            }
            for await value in group { precondition(value.duration == 42) }
        }
        let coalescedStats = await reads.stats(); precondition(coalescedStats.0 == 2)
        // Serial lane also applies to different media, not just coalesced requests.
        await withTaskGroup(of: QueueMetadata.self) { group in
            for i in 0..<3 {
                group.addTask { await cache.read(key: "serial-\(i)", size: 100, cover: false) { await reads.load() } }
            }
            for await value in group { precondition(value.duration == 42) }
        }
        let serialStats = await reads.stats(); precondition(serialStats.2 == 1 && serialStats.1 == 0)
        // Joining a cover request for basic info must survive one reader leaving.
        let cover = Task { await cache.read(key: "joined", size: 100, cover: true) { await reads.load() } }
        while (await reads.stats()).1 == 0 { await Task.yield() }
        let info = Task { await cache.read(key: "joined", size: 100, cover: false) { await reads.load() } }
        try? await Task.sleep(nanoseconds: 10_000_000)
        info.cancel()
        let covered = await cover.value; _ = await info.value
        precondition(covered.cover != nil)
        let joinStats = await reads.stats(); precondition(joinStats.0 == 6)

        let abandoned = Task { await cache.read(key: "cancel", size: 100, cover: true) { await reads.load() } }
        while (await reads.stats()).1 == 0 { await Task.yield() }
        abandoned.cancel(); _ = await abandoned.value
        let retried = await cache.read(key: "cancel", size: 100, cover: true) { await reads.load() }
        precondition(retried.duration == 42)
        let finalStats = await reads.stats(); precondition(finalStats.0 == 8 && finalStats.2 == 1)

        let scrolling = RemoteQueueMetadataCache()
        let shortVisit = Task { await scrolling.read(key: "fleeting", size: nil, cover: true) { await reads.load() } }
        try? await Task.sleep(nanoseconds: 10_000_000)
        shortVisit.cancel(); _ = await shortVisit.value
        let scrollStats = await reads.stats(); precondition(scrollStats.0 == 8)
        await cache.clear()
        let cleared = await cache.read(key: "media", size: 100, cover: true, allowLoad: false) { await reads.load() }
        precondition(cleared.duration == nil && cleared.cover == nil)
        let priority = RemoteQueueMetadataCache(settleNanoseconds: 0)
        let priorityReads = Reads(), heldRead = HeldRead()
        _ = await priority.read(key: "warm", size: 100, cover: true) { await priorityReads.load() }
        let running = Task { await priority.read(key: "held", size: 100, cover: true) { await heldRead.load() } }
        for _ in 0..<1000 {
            if await heldRead.started() { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let started = await heldRead.started(); precondition(started)
        let queued = Task { await priority.read(key: "queued", size: 100, cover: true) { await priorityReads.load() } }
        try? await Task.sleep(nanoseconds: 10_000_000)
        await priority.setPlaybackPriority(suspended: true, revision: 10)
        let warm = await priority.read(key: "warm", size: 100, cover: true) { await priorityReads.load() }
        let deferred = await priority.read(key: "new", size: 100, cover: true) { await priorityReads.load() }
        precondition(warm.duration == 42 && deferred.duration == nil)
        // A resumed row can arrive before the separately dispatched policy hop.
        let resumed = Task { await priority.read(key: "held", size: 100, cover: true, priorityRevision: 11) { await priorityReads.load() } }
        try? await Task.sleep(nanoseconds: 10_000_000)
        let beforeExit = await priorityReads.stats(); precondition(beforeExit.0 == 1)
        await heldRead.finish()
        let stale = await running.value, canceledQueue = await queued.value, fresh = await resumed.value
        precondition(stale.duration != 999 && canceledQueue.duration == nil && fresh.duration == 42)
        await priority.setPlaybackPriority(suspended: true, revision: 10) // late old update cannot suspend again
        let later = await priority.read(key: "new", size: 100, cover: false) { await priorityReads.load() }
        precondition(later.duration == 42)
        let priorityStats = await priorityReads.stats(); precondition(priorityStats.0 == 3 && priorityStats.2 == 1)
        print("PASS: detail/basic reuse, cache-only reads, coalescing, serial lane, subscriber cancellation, scroll debounce and clear")
        print("PASS: transport preemption, cached display while suspended, queued cancellation, non-cooperative reader exit, stale policy rejection and resumed-row ordering")
    }
}
