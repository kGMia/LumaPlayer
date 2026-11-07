// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreVideo
import Metal
import CryptoKit
import Darwin
import RifeMetal
import FSRCNNXCoreML

@main struct Benchmark {
    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("Error: \(error)\n".utf8)); exit(1) }
    }

    static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 8, ["mpsgraph", "coreml"].contains(args[0]), ["serial", "pipeline"].contains(args[1]),
              let w = Int(args[4]), let h = Int(args[5]), w >= 8, h >= 8, w <= 1920, h <= 1920, w%2 == 0, h%2 == 0,
              let pairs = Int(args[6]), (2...12).contains(pairs), !FileManager.default.fileExists(atPath: args[7]),
              let device = MTLCreateSystemDefaultDevice() else {
            throw FSRError("Usage: iive-enhancement-bench mpsgraph|coreml serial|pipeline MODEL_OR_- INPUT.nv12 WIDTH HEIGHT PAIRS(2..12) NEW_REPORT.json")
        }
        let setup = ProcessInfo.processInfo.systemUptime
        let data = try Data(contentsOf: URL(fileURLWithPath: args[3]), options: .mappedIfSafe)
        let frameSize = w * h * 3 / 2
        guard data.count == (pairs + 1) * frameSize else { throw FSRError("Provide exactly PAIRS+1 packed NV12 SDR BT709 frames") }
        let inputs = try (0...pairs).map { try fixture(data: data, offset: $0*frameSize, width: w, height: h) }
        let sr = try SRWorker(backend: args[0], modelPath: args[2], width: w, height: h, device: device)
        // This worker alone owns RIFE stream state. SR has a separate serial worker.
        let rife = try RifeInterpolator(configuration: .bundled(qualityTier: .fast, preferredDevice: device))
        let stream = try rife.makeStream(width: w, height: h)
        _ = try stream.push(inputs[0], timesteps: [], outputNV12: true)
        try autoreleasepool {
            let warm = try stream.push(inputs[1], timesteps: [0.5], outputNV12: true)
            guard warm.count == 1 else { throw FSRError("Missing warmup intermediate") }
            try sr.warmup([inputs[0], warm[0]])
        }
        stream.reset()
        _ = try stream.push(inputs[0], timesteps: [], outputNV12: true)
        let setupMS = (ProcessInfo.processInfo.systemUptime - setup) * 1000
        var inference: [[String: Double]] = []
        // Always drain retained GPU work before exit, including on producer errors.
        defer { try? sr.drain() }
        let start = ProcessInfo.processInfo.systemUptime
        for pair in 0..<pairs { try autoreleasepool {
            let began = ProcessInfo.processInfo.systemUptime
            let generated = try stream.push(inputs[pair+1], timesteps: [0.5], outputNV12: true)
            guard generated.count == 1 else { throw FSRError("Missing intermediate") }
            let ended = ProcessInfo.processInfo.systemUptime
            var row = ["call_ms": (ended - began) * 1000, "start_uptime": began, "end_uptime": ended]
            if let timing = stream.lastTiming { row["gpu_span_ms"] = timing.gpuSpanMS; row["cpu_wait_ms"] = timing.cpuWaitMS }
            inference.append(row)
            try sr.submit(FrameBatch(frames: [inputs[pair], generated[0]], pair: pair, started: began), serial: args[1] == "serial")
        } }
        try sr.drain()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        var report = try sr.report()
        guard report["output_frames"] as? Int == pairs * 2 else { throw FSRError("Wrong output count") }
        var usage = rusage()
        let rss: Any = getrusage(RUSAGE_SELF, &usage) == 0 ? Int64(usage.ru_maxrss) : NSNull()
        report.merge([
            "schema": 1, "backend": args[0], "scheduling": args[1], "device": device.name,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "sr_metadata": sr.metadata, "source_fps": 24, "target_fps": 48, "rife_tier": "fast", "rife_model": rife.modelName,
            "rife_model_sha256": hash(try Data(contentsOf: RifeConfiguration.bundledModelURL, options: .mappedIfSafe)),
            "input_sha256": hash(data), "width": w, "height": h, "source_pairs": pairs,
            "rife_pairs": inference, "setup_and_warmup_ms": setupMS, "wall_ms": elapsed * 1000,
            "completed_output_fps": Double(pairs*2)/elapsed, "amortized_pair_ms": elapsed*1000/Double(pairs),
            "process_lifetime_peak_rss_bytes": rss, "player_realtime": NSNull(), "dropped_frames": NSNull(),
            "limits": "Short unpaced in-memory interval benchmark, not player playback. Includes pipeline fill/drain and bounded backpressure. One warmup pair excluded. Two SR batches maximum including running batch, plus at most one producer batch; inputs preloaded. Peak RSS includes setup and is not GPU memory. No decoder/display/audio/scene-cut handling. Last source endpoint intentionally omitted: each measured interval emits source + midpoint. Raw fixture must already be tagged/normalized as SDR BT709; CPU staging excluded. Core ML internal transfers and actual ANE utilization are opaque."
        ]) { _, new in new }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[7]), options: .withoutOverwriting)
        print("Completed \(pairs*2) ordered 48fps timestamps; \(args[7])")
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func fixture(data: Data, offset: Int, width: Int, height: Int) throws -> CVPixelBuffer {
        var pixel: CVPixelBuffer?
        let attrs = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs, &pixel) == kCVReturnSuccess,
              let pixel, CVPixelBufferLockBaseAddress(pixel, []) == kCVReturnSuccess else { throw FSRError("Fixture allocation failed") }
        data.withUnsafeBytes { bytes in
            for plane in 0..<2 {
                let rows = plane == 0 ? height : height/2, start = offset + (plane == 0 ? 0 : width*height)
                let base = CVPixelBufferGetBaseAddressOfPlane(pixel, plane)!, stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, plane)
                for row in 0..<rows { memcpy(base.advanced(by: row*stride), bytes.baseAddress!.advanced(by: start+row*width), width) }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        for (key, value) in [(kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
                             (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
                             (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2)] {
            CVBufferSetAttachment(pixel, key, value, .shouldPropagate)
        }
        CVBufferSetAttachment(pixel, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center, .shouldPropagate)
        return pixel
    }
}
