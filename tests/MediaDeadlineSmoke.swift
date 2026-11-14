// Compiled alongside the production scheduling module.
import Foundation
@main struct MediaDeadlineSmoke {
    static func main() async {
        let normal: Int? = await mediaReadWithDeadline(seconds: 1, cancel: {}) { 42 }
        precondition(normal == 42)
        let expired: Int? = await mediaReadWithDeadline(seconds: 0.02, cancel: {}) {
            try? await Task.sleep(for: .seconds(1))
            return 99 // The canceled operation's late result must not win.
        }
        precondition(expired == nil)
        let read = Task<Int?, Never> {
            await mediaReadWithDeadline(seconds: 5, cancel: {}) {
                try? await Task.sleep(for: .seconds(5)); return 99
            }
        }
        read.cancel()
        let canceled = await read.value
        precondition(canceled == nil)
        let slots = QueueReadSlots()
        let first = await slots.acquire(), second = await slots.acquire()
        precondition(first && second)
        let waiting = Task { await slots.acquire() }
        try? await Task.sleep(for: .milliseconds(10))
        waiting.cancel()
        let acquired = await waiting.value
        precondition(!acquired)
        await slots.release(); await slots.release()
        let next = await slots.acquire()
        precondition(next)
        await slots.release()
        let heldA = await slots.acquire(), heldB = await slots.acquire()
        precondition(heldA && heldB)
        let order = ReadOrder()
        let background = Task {
            let granted = await slots.acquire(priority: .background)
            if granted { await order.append("background"); await slots.release() }
        }
        try? await Task.sleep(for: .milliseconds(20))
        let visible = Task {
            let granted = await slots.acquire(priority: .visible)
            if granted { await order.append("visible"); await slots.release() }
        }
        try? await Task.sleep(for: .milliseconds(20))
        await slots.release()
        await visible.value
        await slots.release() // Background scans wait until remaining visible work drains.
        await background.value
        let sequence = await order.values
        precondition(sequence == ["visible", "background"])
        let backgroundHeld = await slots.acquire(priority: .background)
        precondition(backgroundHeld)
        let backgroundTicket = UUID()
        let queuedBackground = Task { await slots.acquire(priority: .background, ticket: backgroundTicket) }
        try? await Task.sleep(for: .milliseconds(20))
        // Promotion must use the reserved slot immediately, without a release.
        await slots.promote(backgroundTicket, to: .detail)
        let promoted: Bool? = await mediaReadWithDeadline(seconds: 1, cancel: { queuedBackground.cancel() }) { await queuedBackground.value }
        precondition(promoted == true)
        await slots.release(); await slots.release()
        let hold1 = await slots.acquire(), hold2 = await slots.acquire()
        precondition(hold1 && hold2)
        await slots.setConstrained(true)
        let constrainedOrder = ReadOrder()
        let blocked = Task {
            let granted = await slots.acquire()
            if granted { await constrainedOrder.append("resumed") }
        }
        try? await Task.sleep(for: .milliseconds(20))
        await slots.release()
        try? await Task.sleep(for: .milliseconds(20))
        let stillBlocked = await constrainedOrder.values
        precondition(stillBlocked.isEmpty)
        // Restoring the normal budget must wake queued work without another release.
        await slots.setConstrained(false)
        await blocked.value
        let resumed = await constrainedOrder.values
        precondition(resumed == ["resumed"])
        await slots.release(); await slots.release()
        print("PASS: shrinking concurrency drains active work; restoring budget wakes waiters")
        print("PASS: visible reads precede queued background reads")
        print("PASS: completion, deadline/late result, cancellation, canceled slot waiter")
    }
}

private actor ReadOrder {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
