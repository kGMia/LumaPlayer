// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import CoreVideo
import Metal
import FSRCNNXCoreML
import FSRCNNXMetal

@main struct Bench {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
            exit(1)
        }
    }
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 5, let compute = FSRCompute(rawValue: args[2]),
              let iterations = Int(args[3]), (1...60).contains(iterations),
              !FileManager.default.fileExists(atPath: args[4]) else {
            throw FSRError("Usage: iive-fsrcnnx-coreml MODEL.mlpackage pattern:noise|ramp|edge|constant|INPUT.nv12 all|cpu-gpu|cpu-ne|cpu ITERATIONS NEW_REPORT.json")
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw FSRError("No Metal device") }
        let model = try FSRModel(url: URL(fileURLWithPath: args[0]), compute: compute)
        guard let tierValue = model.metadata["iive.tier"].flatMap(Int.init), let tier = FSRCNNXTier(rawValue: tierValue) else {
            throw FSRError("Missing tier")
        }
        let pipeline = try NV12Pipeline(model: model, device: device)
        let baseline = try FSRCNNXModel(device: device, width: model.width, height: model.height, tier: tier)
        let input = try baseline.makeInput()
        let w = model.width, h = model.height
        var bytes = [UInt8](repeating: 128, count: w * h * 3 / 2)
        if args[1].hasPrefix("pattern:") {
            let name = String(args[1].dropFirst(8))
            guard ["noise", "ramp", "edge", "constant"].contains(name) else { throw FSRError("Unknown pattern") }
            var rng: UInt64 = 25
            for y in 0..<h { for x in 0..<w {
                rng = rng &* 6364136223846793005 &+ 1
                bytes[y*w+x] = switch name {
                case "noise": UInt8(truncatingIfNeeded: rng >> 32)
                case "ramp": UInt8(x * 255 / (w - 1))
                case "edge": x >= w/2 && y >= h/2 ? 255 : 0
                default: 128
                }
            } }
            // Nonconstant chroma tests bilinear geometry as well as luma mapping.
            for y in 0..<h/2 { for x in stride(from: 0, to: w, by: 2) {
                bytes[w*h+y*w+x] = UInt8(16+x*224/w)
                bytes[w*h+y*w+x+1] = UInt8(16+y*224/(h/2))
            } }
        } else {
            let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
            guard data.count == bytes.count else { throw FSRError("Expected exactly one tightly packed NV12 frame") }
            bytes = Array(data)
        }
        guard CVPixelBufferLockBaseAddress(input, []) == kCVReturnSuccess else { throw FSRError("Cannot map fixture") }
        bytes.withUnsafeBytes { source in
            for plane in 0..<2 {
                let rows = plane == 0 ? h : h/2, offset = plane == 0 ? 0 : w*h
                let base = CVPixelBufferGetBaseAddressOfPlane(input, plane)!
                let stride = CVPixelBufferGetBytesPerRowOfPlane(input, plane)
                for row in 0..<rows { memcpy(base.advanced(by: row*stride), source.baseAddress!.advanced(by: offset+row*w), w) }
            }
        }
        CVPixelBufferUnlockBaseAddress(input, [])
        for (key, value) in [(kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
                             (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
                             (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2)] {
            CVBufferSetAttachment(input, key, value, .shouldPropagate)
        }
        let plan = try await model.computePlan()
        // Warmup is separate; fixture IO and compute-plan compilation are excluded.
        let ref = try baseline.process(input)
        let first = try pipeline.process(input)
        let difference = try compare(ref, first)
        let passed = difference.values.allSatisfy { $0["mae"]! <= 1 && $0["rmse"]! <= 1 && $0["max"]! <= 8 }
        var core: [[String: Double]] = [], gpu: [Double] = []
        for _ in 0..<iterations {
            try autoreleasepool { _ = try pipeline.process(input); core.append(pipeline.timing) }
        }
        for _ in 0..<iterations {
            try autoreleasepool {
                let start = ProcessInfo.processInfo.systemUptime
                _ = try baseline.process(input)
                gpu.append((ProcessInfo.processInfo.systemUptime-start)*1000)
            }
        }
        let report: [String: Any] = ["schema": 1, "device": device.name,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "model_metadata": model.metadata,
            "input": args[1], "input_sha256": SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined(),
            "used_requested_output_backing": model.lastOutputUsedBacking, "width": w, "height": h, "format": "NV12 video range8, explicitly tagged SDR BT709",
            "compute": compute.rawValue, "planned_nonconstant_ops": plan, "iterations": iterations,
            "parity": difference, "parity_passed": passed, "coreml_samples": core, "mpsgraph_ms": gpu,
            "coreml_total_mean_ms": core.map { $0["total_ms"]! }.reduce(0,+)/Double(iterations),
            "mpsgraph_mean_ms": gpu.reduce(0,+)/Double(iterations),
            "limits": "Small serial synchronous smoke; planned placement is not measured ANE utilization. Includes GPU pack/assembly waits; excludes startup, decoding, rendering, RIFE contention. Core ML internal transfers opaque. Real raw inputs must already be SDR BT709."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[4]), options: .withoutOverwriting)
        print("Parity \(passed ? "PASS" : "FAIL"); report: \(args[4])")
        guard passed else { throw FSRError("Output differs from MPSGraph beyond thresholds; do not integrate") }
    }

    static func compare(_ a: CVPixelBuffer, _ b: CVPixelBuffer) throws -> [String: [String: Double]] {
        guard CVPixelBufferLockBaseAddress(a, .readOnly) == kCVReturnSuccess else { throw FSRError("Cannot read baseline") }
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly) }
        guard CVPixelBufferLockBaseAddress(b, .readOnly) == kCVReturnSuccess else { throw FSRError("Cannot read prediction") }
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        var result: [String: [String: Double]] = [:]
        for plane in 0..<2 {
            let width = CVPixelBufferGetWidth(a), height = CVPixelBufferGetHeightOfPlane(a, plane)
            let aa = CVPixelBufferGetBaseAddressOfPlane(a, plane)!.assumingMemoryBound(to: UInt8.self)
            let bb = CVPixelBufferGetBaseAddressOfPlane(b, plane)!.assumingMemoryBound(to: UInt8.self)
            let sa = CVPixelBufferGetBytesPerRowOfPlane(a, plane), sb = CVPixelBufferGetBytesPerRowOfPlane(b, plane)
            var sum = 0.0, squares = 0.0, peak = 0.0
            for y in 0..<height { for x in 0..<width {
                let d = abs(Double(aa[y*sa+x])-Double(bb[y*sb+x]))
                sum += d; squares += d*d; peak = max(peak,d)
            } }
            let n = Double(width*height)
            result[plane == 0 ? "y" : "uv"] = ["mae": sum/n, "rmse": sqrt(squares/n), "max": peak]
        }
        return result
    }
}
