import Foundation
import Metal

/// Only immutable shader pipelines are shared. No weights, graphs, queues,
/// textures, tensor data or per-frame workspace may be retained here.
final class InferenceKernelCache: @unchecked Sendable {
    static let shared = InferenceKernelCache()
    private struct Entry {
        let device: MTLDevice
        let warp: BackwardWarpKernel
        let conversion: ConversionKernels
    }
    private let lock = NSLock()
    private var cached: Entry?
    private let pressure: DispatchSourceMemoryPressure

    private init() {
        pressure = DispatchSource.makeMemoryPressureSource(eventMask:[.warning,.critical], queue:.global(qos:.utility))
        pressure.setEventHandler { [weak self] in self?.purge() }
        pressure.resume()
    }
    deinit { pressure.cancel() }

    func kernels(device: MTLDevice) throws -> (BackwardWarpKernel, ConversionKernels) {
        lock.lock(); defer { lock.unlock() }
        // Metal pipelines must only be used with the device that created them.
        if let cached, cached.device === device { return (cached.warp,cached.conversion) }
        let entry = try Entry(device:device, warp:BackwardWarpKernel(device:device),
                              conversion:ConversionKernels(device:device))
        // Publish only the complete set. Failure does not replace a valid entry.
        cached = entry
        return (entry.warp,entry.conversion)
    }

    func purge() {
        lock.lock()
        let retired = cached
        cached = nil
        lock.unlock()
        // Active contexts still own their pipelines. Release the cache's
        // references outside the lock without waiting for any GPU work.
        withExtendedLifetime(retired) {}
    }
}
