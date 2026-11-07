// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

private actor RemoteProbeLane {
    private var active = false
    private var waiting: [(UUID, CheckedContinuation<Bool, Never>, MediaReadPriority)] = []
    func acquire(priority: MediaReadPriority, ticket id: UUID) async -> Bool {
        guard !Task.isCancelled else { return false }
        if !active { active = true; return true }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                if Task.isCancelled { c.resume(returning: false) } else { waiting.append((id,c,priority)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        if let i = waiting.firstIndex(where: { $0.0 == id }) { waiting.remove(at: i).1.resume(returning: false) }
    }
    func promote(_ ticket: UUID, to priority: MediaReadPriority) {
        guard let index = waiting.firstIndex(where: { $0.0 == ticket }),
              waiting[index].2.rawValue < priority.rawValue else { return }
        waiting[index].2 = priority
    }
    func release() {
        if let highest = waiting.map({ $0.2.rawValue }).max(),
           let index = waiting.firstIndex(where: { $0.2.rawValue == highest }) {
            waiting.remove(at: index).1.resume(returning: true)
        } else { active = false }
    }
}


/// Per-window, single-reader lane with cancellable subscribers and bounded cache.
actor RemoteQueueMetadataCache {
    private struct Key: Hashable { let media: String; let cover: Bool }
    private struct Entry { let id: UUID; let task: Task<QueueMetadata?, Never>; var readers: Set<UUID> }
    private struct Cached { let value: QueueMetadata; let coverChecked: Bool; let expiry: Date }
    private let lane = RemoteProbeLane()
    private let settleNanoseconds: UInt64
    private let incompleteTTL: TimeInterval
    private var pending: [Key: Entry] = [:]
    private var cache: [String: Cached] = [:]
    private var order: [String] = []
    private var coverBytes = 0
    private var playbackSuspended = false
    private var priorityRevision: UInt64 = 0
    init(settleNanoseconds: UInt64 = 200_000_000, incompleteTTL: TimeInterval = 30) {
        self.settleNanoseconds = settleNanoseconds; self.incompleteTTL = max(0, incompleteTTL)
    }
    /// Independent of SwiftUI row lifetime. Cancel running and queued probes as
    /// soon as transport needs bandwidth; keep completed cache entries visible.
    /// Revisions reject late actor hops from an earlier play/seek transition.
    func setPlaybackPriority(suspended: Bool, revision: UInt64) {
        guard revision > priorityRevision else { return }
        priorityRevision = revision
        playbackSuspended = suspended
        if suspended {
            pending.values.forEach { $0.task.cancel() }
            pending.removeAll()
        }
    }
    func clear() {
        pending.values.forEach { $0.task.cancel() }; pending.removeAll()
        cache.removeAll(); order.removeAll(); coverBytes = 0
    }
    func read(key media: String, size: Int64?, cover: Bool, allowLoad: Bool = true, priorityRevision: UInt64? = nil, priority: MediaReadPriority = .visible,
              load: @escaping @Sendable () async -> QueueMetadata?) async -> QueueMetadata {
        let fallback = QueueMetadata(size: size)
        guard !Task.isCancelled else { return fallback }
        // The row may reach this actor before the model's policy-update task.
        // Apply the same revision here so a resumed row cannot get stranded in
        // cache-only mode until some unrelated UI change triggers another read.
        if let priorityRevision { setPlaybackPriority(suspended: !allowLoad, revision: priorityRevision) }
        if let cached = cache[media], cached.expiry > Date(), !cover || cached.coverChecked {
            order.removeAll { $0 == media }; order.append(media)
            return cached.value
        }
        // Cached details remain usable while playback has priority, without I/O.
        guard allowLoad && !playbackSuspended else { return cache[media]?.value ?? fallback }
        let reader = UUID()
        // A cover read also obtains duration, so basic readers can join it.
        let coverKey = Key(media: media, cover: true)
        let key = !cover && pending[coverKey] != nil ? coverKey : Key(media: media, cover: cover)
        let work: Entry
        if var old = pending[key] {
            old.readers.insert(reader); pending[key] = old; work = old
            await lane.promote(old.id, to: priority)
            await QueueReadSlots.shared.promote(old.id, to: priority)
        }
        else {
            let ticket = UUID()
            let task = Task { [lane, settleNanoseconds] in
                // Fast scrolling never starts a request for briefly visible rows.
                do { try await Task.sleep(nanoseconds: settleNanoseconds) } catch { return nil as QueueMetadata? }
                guard await lane.acquire(priority: priority, ticket: ticket) else { return nil }
                defer {
                    await withTaskCancellationShield {
                        await lane.release()
                    }
                }
                guard await QueueReadSlots.shared.acquire(priority: priority, ticket: ticket) else { return nil }
                defer {
                    await withTaskCancellationShield { await QueueReadSlots.shared.release() }
                }
                return Task.isCancelled || playbackSuspended ? nil : await load()
            }
            work = Entry(id: ticket, task: task, readers: [reader]); pending[key] = work
        }
        return await withTaskCancellationHandler {
            let result = await work.task.value
            if pending[key]?.id == work.id {
                pending[key] = nil
                if !work.task.isCancelled {
                    let old = cache[media]
                    let merged = QueueMetadata(duration: result?.duration ?? old?.value.duration,
                        size: result?.size ?? old?.value.size ?? size, cover: result?.cover ?? old?.value.cover, subtitleCount: result?.subtitleCount ?? old?.value.subtitleCount)
                    coverBytes -= old?.value.cover?.count ?? 0
                    cache[media] = Cached(value: merged, coverChecked: key.cover || old?.coverChecked == true,
                        expiry: Date().addingTimeInterval(merged.duration == nil || (key.cover && merged.cover == nil) ? incompleteTTL : 300))
                    coverBytes += merged.cover?.count ?? 0
                    order.removeAll { $0 == media }; order.append(media)
                    while order.count > 128 || coverBytes > 8*1024*1024 {
                        let removed = cache.removeValue(forKey: order.removeFirst())
                        coverBytes -= removed?.value.cover?.count ?? 0
                    }
                }
            }
            guard !Task.isCancelled else { return fallback }
            // A non-cooperative loader can return after cancellation/clear. It
            // must not publish a stale result or become a negative cache entry.
            guard !work.task.isCancelled else { return cache[media]?.value ?? fallback }
            return cache[media]?.value ?? result ?? fallback
        } onCancel: { Task { await self.unsubscribe(key, id: work.id, reader: reader) } }
    }
    private func unsubscribe(_ key: Key, id: UUID, reader: UUID) {
        guard var entry = pending[key], entry.id == id else { return }
        entry.readers.remove(reader)
        if entry.readers.isEmpty { entry.task.cancel(); pending[key] = nil } else { pending[key] = entry }
    }
}
