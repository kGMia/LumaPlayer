// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main struct FileDialogsSmoke {
    @MainActor static func main() async throws {
        let dialogs = PlayerFileDialogs()
        var importCount = 0
        var exportCount = 0
        dialogs.activeHost = .settings
        dialogs.importFiles(title: "ICC") { _ in importCount += 1 }
        let first = dialogs.operation
        precondition(dialogs.owner == .settings && dialogs.importing)
        dialogs.activeHost = .mini
        dialogs.importFiles(title: "Ignored duplicate") { _ in fatalError("Replaced active import") }
        precondition(dialogs.operation == first && dialogs.owner == .settings)
        dialogs.cancel(for: .player)
        precondition(dialogs.isBusy)
        dialogs.cancel(for: .settings)
        precondition(!dialogs.isBusy && importCount == 0)

        // Simulate slow capture finishing after its window was closed and a new
        // import started. No old completion may reset or reopen the new request.
        var releaseCapture: CheckedContinuation<Data, Never>?
        var captureFinished = false
        dialogs.export(title: "Frame", filename: "frame.png", type: .png, load: {
            let data = await withCheckedContinuation { releaseCapture = $0 }
            captureFinished = true
            return data
        }) { _ in exportCount += 1 }
        let stale = dialogs.operation
        try await wait { releaseCapture != nil }
        precondition(dialogs.owner == .mini && !dialogs.exporting)
        dialogs.cancel(for: .mini)
        dialogs.importFiles(title: "Media", multiple: true) { result in
            precondition((try? result.get().count) == 2)
            importCount += 1
        }
        let current = dialogs.operation
        releaseCapture?.resume(returning: Data([1, 2, 3]))
        try await wait { captureFinished }
        dialogs.finishExport(.success(URL(fileURLWithPath: "/tmp/stale.png")), operation: stale)
        dialogs.finishImport(.success([]), operation: first)
        precondition(dialogs.operation == current && dialogs.importing && !dialogs.exporting)
        dialogs.finishImport(.success([URL(fileURLWithPath: "/tmp/a.mp4"), URL(fileURLWithPath: "/tmp/b.mkv")]), operation: current)
        precondition(!dialogs.isBusy && importCount == 1 && exportCount == 0)

        let bytes = Data("one JSONL record\n".utf8)
        dialogs.export(title: "Log", filename: "profile.jsonl", type: .plainText, load: { bytes }) { result in
            precondition((try? result.get().lastPathComponent) == "profile.jsonl")
            exportCount += 1
        }
        try await wait { dialogs.exporting }
        precondition(dialogs.document?.data == bytes)
        dialogs.finishExport(.success(URL(fileURLWithPath: "/tmp/profile.jsonl")), operation: dialogs.operation)
        precondition(!dialogs.isBusy && dialogs.document == nil && exportCount == 1)
        dialogs.shutdown()
        print("PASS: dialog ownership, duplicate suppression, cancellation, stale completions, multi-file import and export preparation; no windows opened.")
    }

    @MainActor static func wait(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !ready() {
            precondition(ContinuousClock.now < deadline, "Timed out")
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
