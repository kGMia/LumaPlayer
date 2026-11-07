// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main enum TransportFeedbackSmoke {
    static func main() {
        // Shorter threshold; exact boundary restarts instead of skipping.
        precondition(PreviousMediaPolicy.isNearBeginning(position: 4.9, duration: 20))
        precondition(!PreviousMediaPolicy.isNearBeginning(position: 5, duration: 20))
        precondition(!PreviousMediaPolicy.isNearBeginning(position: 9.9, duration: 20))
        precondition(PreviousMediaPolicy.isNearBeginning(position: 9.9, duration: 3600))
        precondition(!PreviousMediaPolicy.isNearBeginning(position: 10, duration: 3600))
        precondition(!PreviousMediaPolicy.isNearBeginning(position: 20, duration: 3600))
        precondition(!PreviousMediaPolicy.isNearBeginning(position: 24.9, duration: 100))
        precondition(PreviousMediaPolicy.isNearBeginning(position: 9.9, duration: 40))
        precondition(!PreviousMediaPolicy.isNearBeginning(position: 10, duration: 40))
        precondition(PreviousMediaPolicy.isNearBeginning(position: 5, duration: 0))
        precondition(!PreviousMediaPolicy.isNearBeginning(position: 11, duration: .infinity))
        precondition(!PreviousMediaPolicy.isNearBeginning(position: 30, duration: .nan))
        precondition(PreviousMediaPolicy.isNearBeginning(position: .nan, duration: 100))

        var notice = MediaTitleNotice()
        // Slow network/model preparation must not consume the visible interval.
        precondition(notice.update(epoch: 1, ready: false, title: "One", now: 0).isEmpty)
        precondition(notice.update(epoch: 1, ready: false, title: "One", now: 20).isEmpty)
        precondition(notice.update(epoch: 1, ready: true, title: "One", now: 30) == "One")
        // Metadata corrections can replace the label but cannot extend its lifetime.
        precondition(notice.update(epoch: 1, ready: true, title: "Corrected", now: 31) == "Corrected")
        precondition(notice.update(epoch: 1, ready: true, title: "Corrected", now: 32.31).isEmpty)
        // Seek/pause/buffering/repeated polls in the same entry never retrigger it.
        precondition(notice.update(epoch: 1, ready: false, title: "One", now: 32).isEmpty)
        precondition(notice.update(epoch: 1, ready: true, title: "One", now: 35).isEmpty)
        // Reloading even the same URL gets a fresh epoch and a fresh notice.
        precondition(notice.update(epoch: 2, ready: false, title: "One", now: 36).isEmpty)
        precondition(notice.update(epoch: 2, ready: true, title: "One", now: 37) == "One")
        // A rapid replacement must hide the old label before the next item is ready.
        precondition(notice.update(epoch: 3, ready: false, title: "Two", now: 37.1).isEmpty)
        precondition(notice.update(epoch: 3, ready: true, title: "Two", now: 38) == "Two")
        precondition(notice.update(epoch: 3, ready: true, title: "Two", now: 40.31).isEmpty)
        precondition(notice.update(epoch: 4, ready: true, title: "Hover", now: 50) == "Hover")
        precondition(notice.update(epoch: 4, ready: true, title: "Hover", now: 52, hovering: true) == "Hover")
        precondition(notice.update(epoch: 4, ready: true, title: "Hover", now: 60, hovering: true) == "Hover")
        precondition(notice.update(epoch: 4, ready: true, title: "Hover", now: 60.2) == "Hover")
        precondition(notice.update(epoch: 4, ready: true, title: "Hover", now: 60.6).isEmpty)
        print("PASS: Previous thresholds and bounds; title timing, readiness, metadata, seek and replacement")
    }
}
