// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreVideo
import Metal
import FSRCNNXCoreML
import FSRCNNXMetal

// Frames are immutable after submission; the owning job retains their surfaces
// until synchronous GPU completion. No CVPixelBuffer is mutated by two workers.
struct FrameBatch: @unchecked Sendable {
    let frames: [CVPixelBuffer]
    let pair: Int
    let started: Double
}

/// Model access and results are confined to queue. Capacity includes the running
/// batch; the producer can additionally hold one freshly generated pair.
final class SRWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "iive.bench.sr", qos: .userInitiated)
    private let capacity = DispatchSemaphore(value: 2)
    private let group = DispatchGroup()
    private let core: NV12Pipeline?
    private let gpu: FSRCNNXModel?
    private let width: Int, height: Int
    private var failure: Error?
    private var expectedTick = 0
    private var rows: [[String: Double]] = []
    private var latencies: [Double] = []
    private var backpressure: [Double] = [] // producer only, read after drain
    private let countLock = NSLock()
    private var pending = 0, maximumPending = 0
    let metadata: [String: String]

    init(backend: String, modelPath: String, width: Int, height: Int, device: MTLDevice) throws {
        self.width = width; self.height = height
        if backend == "coreml" {
            let model = try FSRModel(url: URL(fileURLWithPath: modelPath), compute: .cpuNeuralEngine)
            guard model.width == width, model.height == height, model.metadata["iive.tier"] == "8",
                  model.metadata["iive.weights_sha256"] == "97db353764d9e474e649e56a79be42bfedcb0faa7b5026ce00875a9d3fa064fa" else {
                throw FSRError("Expected the matching FSRCNNX8 model and fixed dimensions")
            }
            core = try NV12Pipeline(model: model, device: device); gpu = nil; metadata = model.metadata
        } else {
            gpu = try FSRCNNXModel(device: device, width: width, height: height, tier: .fast8)
            core = nil; metadata = ["backend": "MPSGraph", "tier": "8"]
        }
    }

    private func process(_ input: CVPixelBuffer) throws -> [String: Double] {
        let start = ProcessInfo.processInfo.systemUptime
        let output: CVPixelBuffer
        if let core { output = try core.process(input) }
        else if let gpu { output = try gpu.process(input) }
        else { throw FSRError("Missing SR backend") }
        guard CVPixelBufferGetWidth(output) == width * 2, CVPixelBufferGetHeight(output) == height * 2,
              CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
            throw FSRError("Invalid enhanced frame")
        }
        var row = core?.timing ?? [:]
        let end = ProcessInfo.processInfo.systemUptime
        row["sr_call_ms"] = (end - start) * 1000
        row["start_uptime"] = start; row["end_uptime"] = end
        if let timing = gpu?.lastTiming { row["gpu_span_ms"] = timing.gpuSpanMS; row["cpu_wait_ms"] = timing.cpuWaitMS }
        return row
    }

    func warmup(_ frames: [CVPixelBuffer]) throws {
        try queue.sync { for frame in frames { try autoreleasepool { _ = try process(frame) } } }
    }

    func submit(_ batch: FrameBatch, serial: Bool) throws {
        let start = ProcessInfo.processInfo.systemUptime
        capacity.wait()
        backpressure.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        countLock.lock(); pending += 1; maximumPending = max(maximumPending, pending); countLock.unlock()
        group.enter()
        queue.async { [self] in
            defer {
                countLock.lock(); pending -= 1; countLock.unlock()
                capacity.signal(); group.leave()
            }
            guard failure == nil else { return }
            do {
                guard batch.frames.count == 2, batch.pair * 2 == expectedTick else { throw FSRError("Out-of-order pair") }
                for frame in batch.frames {
                    var row = try autoreleasepool { try process(frame) }
                    row["pts_seconds"] = Double(expectedTick) / 48
                    rows.append(row); expectedTick += 1
                }
                latencies.append((ProcessInfo.processInfo.systemUptime - batch.started) * 1000)
            } catch { failure = error }
        }
        if serial { try drain() }
    }

    func drain() throws {
        group.wait()
        try queue.sync { if let failure { throw failure } }
    }

    // Called only after the single producer has stopped submitting.
    func report() throws -> [String: Any] {
        try drain()
        return queue.sync {
            ["sr_frames": rows, "pair_completion_ms": latencies, "producer_backpressure_ms": backpressure,
             "output_frames": expectedTick, "maximum_pending_batches": maximumPending,
             "requested_coreml_output_backing_used": core.map { $0.model.lastOutputUsedBacking } as Any? ?? NSNull()]
        }
    }
}
