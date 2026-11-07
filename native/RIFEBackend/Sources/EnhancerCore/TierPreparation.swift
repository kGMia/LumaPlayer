import Foundation
import CoreVideo
import RifeMetal

/// One owned preparation job. Only its result crosses threads; a RifeStream is
/// never used by the preparation queue and playback worker simultaneously.
final class TierPreparation: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "org.iive.rife.prepare", qos: .utility)
    let tier: RifeQualityTier
    let started = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private var canceled = false
    private var source: CVPixelBuffer?
    private var result: Result<(RifeInterpolator, RifeStream), Error>?

    init(tier: RifeQualityTier, modelURL: URL, source: CVPixelBuffer, outputNV12: Bool) {
        self.tier = tier
        self.source = source
        Self.queue.async { [self] in
            autoreleasepool {
                lock.lock()
                let pixels = canceled ? nil : self.source
                self.source = nil
                lock.unlock()
                guard let pixels else { return }
                let prepared = Result { () throws -> (RifeInterpolator, RifeStream) in
                    let model = try RifeInterpolator(configuration: RifeConfiguration(modelURL: modelURL, qualityTier: tier))
                    guard !isCanceled else { throw CancellationError() }
                    let stream = try model.makeStream(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels)) {
                        if self.isCanceled { throw CancellationError() }
                    }
                    guard !isCanceled else { throw CancellationError() }
                    _ = try stream.push(pixels, timesteps: [])
                    guard !isCanceled else { throw CancellationError() }
                    // Empty timesteps only warm the encoder. Execute one real
                    // inference to compile IFNet and the requested output path.
                    _ = try stream.push(pixels, timesteps: [0.5], outputNV12: outputNV12)
                    stream.reset()
                    return (model, stream)
                }
                lock.lock()
                if !canceled { result = prepared }
                lock.unlock()
            }
        }
    }

    private var isCanceled: Bool {
        lock.lock(); defer { lock.unlock() }
        return canceled
    }

    func takeResult() -> Result<(RifeInterpolator, RifeStream), Error>? {
        lock.lock(); defer { lock.unlock() }
        defer { result = nil }
        return result
    }

    func cancel() {
        lock.lock()
        canceled = true
        source = nil
        let retired = result
        result = nil
        lock.unlock()
        withExtendedLifetime(retired) {}
    }
}
