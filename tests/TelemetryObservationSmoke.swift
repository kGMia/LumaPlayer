// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation
import Synchronization

@main struct TelemetryObservationSmoke {
    @MainActor static func main() {
        let telemetry = PlayerTelemetryState()
        let diagnostics = PlayerDiagnosticsState()
        let changes = Mutex(0)
        withObservationTracking { _ = telemetry.revision } onChange: { changes.withLock { $0 += 1 } }
        telemetry.update(["time-pos": 10], visible: false)
        precondition(changes.withLock { $0 } == 0 && telemetry.raw["time-pos"] as? Int == 10)
        telemetry.flush()
        precondition(changes.withLock { $0 } == 1 && telemetry.snapshot["time-pos"] as? Int == 10)

        let statusChanges = Mutex(0)
        withObservationTracking { _ = diagnostics.status } onChange: { statusChanges.withLock { $0 += 1 } }
        diagnostics.samples = 12
        precondition(statusChanges.withLock { $0 } == 0) // A sample counter is not a status subscription.
        diagnostics.status = "Recording"
        precondition(statusChanges.withLock { $0 } == 1)

        let hiddenChanges = Mutex(0)
        let active = false
        withObservationTracking {
            _ = active ? telemetry.revision : 0
            _ = active ? diagnostics.status : ""
        } onChange: { hiddenChanges.withLock { $0 += 1 } }
        telemetry.update(["time-pos": 11], visible: true)
        diagnostics.status = "Saved"
        precondition(hiddenChanges.withLock { $0 } == 0)
        precondition(telemetry.snapshot["time-pos"] as? Int == 11)
        telemetry.reset()
        precondition(telemetry.raw.isEmpty && telemetry.snapshot.isEmpty)
        print("PASS: hidden telemetry, reveal freshness, independent diagnostics, inactive subscriptions, reset")
    }
}
