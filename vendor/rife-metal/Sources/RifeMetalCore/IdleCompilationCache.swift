import Foundation
import Metal
import MetalPerformanceShadersGraph

/// Single idle entry, transferred out on checkout. Active owners never share a
/// value. The lock covers bookkeeping only, never compilation or GPU execution.
final class IdleCompilationCache<Key: Hashable & Sendable, Value: AnyObject>: @unchecked Sendable {
    private struct Entry {
        let key: Key
        let value: Value
        let expiry: TimeInterval
        let id: UInt64
    }
    private let lock = NSLock()
    private var entry: Entry?
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var pressured = false
    private let lifetime: TimeInterval
    private let pressure: DispatchSourceMemoryPressure

    init(lifetime: TimeInterval = 5) {
        self.lifetime = lifetime
        pressure = DispatchSource.makeMemoryPressureSource(eventMask:[.normal,.warning,.critical], queue:.global(qos:.utility))
        pressure.setEventHandler { [weak self] in
            guard let self else { return }
            self.setPressure(self.pressure.data != DispatchSource.MemoryPressureEvent.normal.rawValue)
        }
        pressure.resume()
    }
    deinit { pressure.cancel() }

    func take(_ key: Key) -> (value: Value?, ticket: UInt64) {
        lock.lock()
        let retired = entry
        entry = nil
        let value = !pressured && retired?.key == key &&
            (retired?.expiry ?? 0) > ProcessInfo.processInfo.systemUptime ? retired?.value : nil
        let ticket = generation
        lock.unlock()
        withExtendedLifetime(retired) {}
        return (value, ticket)
    }

    func put(_ value: Value, key: Key, ticket: UInt64) {
        lock.lock()
        guard !pressured, ticket == generation else { lock.unlock(); return }
        let retired = entry
        sequence &+= 1
        let id = sequence
        entry = Entry(key:key, value:value, expiry:ProcessInfo.processInfo.systemUptime+lifetime, id:id)
        lock.unlock()
        withExtendedLifetime(retired) {}
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+lifetime) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let expired = self.entry?.id == id ? self.entry : nil
            if expired != nil { self.entry = nil }
            self.lock.unlock()
            withExtendedLifetime(expired) {}
        }
    }

    func purge() { invalidate(pressure: nil) }
    func setPressure(_ value: Bool) { invalidate(pressure: value) }
    private func invalidate(pressure: Bool?) {
        lock.lock()
        let retired = entry
        entry = nil
        generation &+= 1 // Old active owners must not refill a purged cache.
        if let pressure { pressured = pressure }
        lock.unlock()
        withExtendedLifetime(retired) {}
    }
}

struct IFNetCompilationKey: Hashable {
    static func accepts(width: Int, height: Int, modelBytes: Int) -> Bool {
        width > 0 && height > 0 && width <= (512 * 288) / height &&
            modelBytes > 0 && modelBytes <= 16 * 1024 * 1024
    }
    let device: ObjectIdentifier
    let modelDigest: String
    let width: Int
    let height: Int
    let scale: Double
    let disableAutoLayout: Bool
}

struct IFNetCompiledStage {
    let executable: MPSGraphExecutable
    let inputTensors: [MPSGraphTensor]
}

/// Compiled code/constants only: no command queue, frames, tensor data, texture
/// cache or BufferPool. Executables stay exclusively owned until graph teardown.
final class IFNetCompiledProgram {
    static let cache = IdleCompilationCache<IFNetCompilationKey, IFNetCompiledProgram>()
    let device: MTLDevice // Keep device identity valid while cached.
    let encoder: MPSGraphExecutable
    let stages: [IFNetCompiledStage]
    let flow: MPSGraphExecutable
    let mask: MPSGraphExecutable?
    init(device: MTLDevice, encoder: MPSGraphExecutable, stages: [IFNetCompiledStage],
         flow: MPSGraphExecutable, mask: MPSGraphExecutable?) {
        self.device=device; self.encoder=encoder; self.stages=stages; self.flow=flow; self.mask=mask
    }
}
