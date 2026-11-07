// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@main struct LiveTextSessionSmoke {
    @MainActor static func main() {
        let session = LiveTextSession()
        var presentations = 0
        var dismissals = 0
        session.presentWindow = {
            precondition(session.capture != nil, "Capture state must exist before presenting")
            presentations += 1
        }
        session.dismissWindow = {
            precondition(session.capture == nil, "Clear resources before dismissing")
            dismissals += 1
        }
        let first = session.begin(source: "Movie · 00:01:20")
        precondition(session.focusIfBusy())
        precondition(presentations == 2 && session.contains(first.id))
        session.windowDidClose()
        precondition(!session.contains(first.id) && first.result.phase == .cancelled)
        precondition(!session.focusIfBusy() && dismissals == 0)

        // A delayed capture/OCR callback must not revive a closed result.
        first.result.fail("Late capture error")
        first.result.recognize(NSImage(size: NSSize(width: 1, height: 1)))
        precondition(first.result.phase == .cancelled && first.result.image == nil)
        precondition(first.result.analysis == nil && first.result.transcript.isEmpty)

        let second = session.begin(source: "New Frame")
        precondition(second.id != first.id && session.contains(second.id))
        second.result.fail("No frame available")
        precondition(!session.focusIfBusy())
        let third = session.begin(source: "Retry Frame")
        precondition(second.result.phase == .cancelled && !session.contains(second.id))
        precondition(session.contains(third.id) && presentations == 4)
        var cancellations = 0
        session.onCancelCapture = { cancellations += 1 }
        session.close()
        precondition(session.capture == nil && third.result.phase == .cancelled && dismissals == 1)
        session.windowDidClose()
        precondition(cancellations == 1, "Closing repeatedly must cancel the capture once")
        print("PASS: Live Text session reuse, close/cancel, stale-result rejection and retry; no windows opened or OCR invoked.")
    }
}
