// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A deadline resumes the caller even if an OS media read is slow to acknowledge
/// cancellation. The operation's late result cannot resume its continuation twice.
private final class MediaReadGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<Value?, Never>?
    private var worker: Task<Void, Never>?
    private var deadline: DispatchWorkItem?
    private let cancelOperation: @Sendable () -> Void
    init(cancel: @escaping @Sendable () -> Void) { cancelOperation = cancel }
    func start(_ continuation: CheckedContinuation<Value?, Never>, seconds: Double,
               operation: @escaping @Sendable () async -> Value?) {
        lock.lock()
        guard !finished else { lock.unlock(); continuation.resume(returning: nil); return }
        self.continuation = continuation
        let timer = DispatchWorkItem { [weak self] in self?.complete(nil, cancel: true) }
        deadline = timer
        worker = Task.detached(priority: Task.currentPriority) { [self] in
            let value = Task.isCancelled ? nil : await operation()
            complete(value, cancel: false)
        }
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: timer)
    }
    func complete(_ value: Value?, cancel: Bool) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation, worker = worker, deadline = deadline
        self.continuation = nil; self.worker = nil; self.deadline = nil
        lock.unlock()
        deadline?.cancel()
        if cancel { worker?.cancel(); cancelOperation() }
        continuation?.resume(returning: value)
    }
}
func mediaReadWithDeadline<Value: Sendable>(seconds: Double, cancel: @escaping @Sendable () -> Void,
                                          operation: @escaping @Sendable () async -> Value?) async -> Value? {
    let gate = MediaReadGate<Value>(cancel: cancel)
    return await withTaskCancellationHandler {
        await withCheckedContinuation { gate.start($0, seconds: seconds, operation: operation) }
    } onCancel: { gate.complete(nil, cancel: true) }
}

/// Shared budget for local/remote queue probes and thumbnail rasterization.
/// Timeline decoding and playback never wait on these background slots.
enum MediaReadPriority: Int, Sendable {
    case background, visible, detail
}

actor QueueReadSlots {
    static let shared = QueueReadSlots()
    private var active = 0
    private var limit = 2
    private var waiting: [(UUID, CheckedContinuation<Bool, Never>, MediaReadPriority)] = []
    func acquire(priority: MediaReadPriority = .visible, ticket: UUID = UUID()) async -> Bool {
        guard !Task.isCancelled else { return false }
        // Background scans run only while the pool is otherwise idle. They cannot
        // occupy both slots before visible thumbnails arrive.
        if active < limit && (priority != .background || active == 0) { active += 1; return true }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { waiting.append((ticket, continuation, priority)) }
            }
        } onCancel: { Task { await self.cancel(ticket) } }
    }
    private func cancel(_ ticket: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == ticket }) else { return }
        waiting.remove(at: index).1.resume(returning: false)
    }
    func promote(_ ticket: UUID, to priority: MediaReadPriority) {
        guard let index = waiting.firstIndex(where: { $0.0 == ticket }),
              waiting[index].2.rawValue < priority.rawValue else { return }
        waiting[index].2 = priority
        drain()
    }
    func setConstrained(_ constrained: Bool) {
        limit = constrained ? 1 : 2
        drain()
    }
    func release() {
        precondition(active > 0)
        active -= 1
        drain()
    }
    private func drain() {
        while active < limit,
              let highest = waiting.map({ $0.2.rawValue }).max(),
              let index = waiting.firstIndex(where: { $0.2.rawValue == highest }) {
            guard highest > MediaReadPriority.background.rawValue || active == 0 else { break }
            active += 1
            waiting.remove(at: index).1.resume(returning: true)
        }
    }
}
