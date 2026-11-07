// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

@main struct AssetImageReaderSmoke {
    static func main() async throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        let reader = AssetImageReader(asset: asset, maximumSize: CGSize(width: 160, height: 90), tolerance: .zero)
        let frame = try await reader.image(at: CMTime(seconds: 0.25, preferredTimescale: 600))
        precondition(frame.image.width <= 160 && frame.image.height <= 90)
        precondition(abs(frame.actualTime.seconds - 0.25) < 0.1)
        // Cancellation is serialized before any subsequently registered request;
        // it must not poison later reads from the same timeline generator.
        reader.cancelAllCGImageGeneration()
        let next = try await reader.image(at: CMTime(seconds: 0.75, preferredTimescale: 600))
        precondition(abs(next.actualTime.seconds - 0.75) < 0.1)
        let cancelled = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await reader.image(at: .zero)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancelled task generated a frame") }
        catch is CancellationError {}
        reader.cancelAllCGImageGeneration()
        print("PASS: serialized AV image generation, size/PTS, post-cancel reuse and pre-cancel rejection; no GUI used.")
    }
}
