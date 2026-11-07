import Foundation
import CoreVideo
import Metal
import CryptoKit
import Darwin
import SPANCoreML
import FSRCNNXMetal

@main struct SPANBench {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
    }
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 6, let compute = SPANCompute(rawValue: args[3]),
              let iterations = Int(args[4]), (1...60).contains(iterations) else {
            throw SPANError("Usage: iive-span MODEL.mlpackage INPUT.png REFERENCE_2X.png all|cpu-gpu|cpu-ne|cpu ITERATIONS NEW_OUTPUT_DIRECTORY")
        }
        let modelURL = URL(fileURLWithPath: args[0]), inputURL = URL(fileURLWithPath: args[1])
        let referenceURL = URL(fileURLWithPath: args[2]), directory = URL(fileURLWithPath: args[5], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path), let device = MTLCreateSystemDefaultDevice() else {
            throw SPANError("Need a new output directory and Apple GPU")
        }
        let input = try ImageBuffers.read(inputURL), reference = try ImageBuffers.read(referenceURL)
        let w = CVPixelBufferGetWidth(input), h = CVPixelBufferGetHeight(input)
        guard w%2 == 0, h%2 == 0, CVPixelBufferGetWidth(reference) == w*2, CVPixelBufferGetHeight(reference) == h*2 else {
            throw SPANError("Need even input dimensions and a matching 2x reference")
        }
        let start = ProcessInfo.processInfo.systemUptime
        let span = try SPANModel(url: modelURL, compute: compute)
        if span.metadata["iive.validation"] != "passed_small_parity" {
            FileHandle.standardError.write(Data("Diagnostic model: numerical parity is unvalidated or failed; not suitable for player integration.\n".utf8))
        }
        guard span.width == w, span.height == h else { throw SPANError("Model and input dimensions differ") }
        let compilationMS = (ProcessInfo.processInfo.systemUptime-start)*1000
        let placement: [String: Int]?, planError: String?
        do { placement = try await span.computePlan(); planError = nil }
        catch { placement = nil; planError = "Compute plan unavailable" }
        _ = try span.process(input) // excluded warmup
        var spanTimes: [Double] = [], spanOutput: CVPixelBuffer?
        for _ in 0..<iterations {
            try autoreleasepool {
                let begin = ProcessInfo.processInfo.systemUptime
                spanOutput = try span.process(input)
                spanTimes.append((ProcessInfo.processInfo.systemUptime-begin)*1000)
            }
        }
        guard let spanOutput else { throw SPANError("Missing SPAN output") }
        // Keep decoded source and output sizes identical. FSR retains its actual
        // luma-only NV12 path; RGB<->NV12 conversion is excluded from model timing.
        let nv12 = try ImageBuffers.transfer(input, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let fsr = try FSRCNNXModel(device: device, width: w, height: h, tier: .fast8)
        _ = try fsr.process(nv12)
        var fsrTimes: [Double] = [], fsrOutput: CVPixelBuffer?
        for _ in 0..<iterations {
            try autoreleasepool {
                let begin = ProcessInfo.processInfo.systemUptime
                fsrOutput = try fsr.process(nv12)
                fsrTimes.append((ProcessInfo.processInfo.systemUptime-begin)*1000)
            }
        }
        guard let fsrOutput else { throw SPANError("Missing FSRCNNX output") }
        let fsrRGB = try ImageBuffers.transfer(fsrOutput, format: kCVPixelFormatType_32BGRA)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ImageBuffers.write(spanOutput, to: directory.appendingPathComponent("span.png"))
        try ImageBuffers.write(fsrRGB, to: directory.appendingPathComponent("fsrcnnx8.png"))
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        func hash(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
        let report: [String: Any] = ["kind":"single_image_sr_prototype", "device":device.name, "compute_units_requested":compute.rawValue,
            "model_metadata":span.metadata,
            "planned_nonconstant_operations":placement as Any? ?? NSNull(), "plan_error":planError as Any? ?? NSNull(),
            "width":w,"height":h,"output_width":w*2,"output_height":h*2,"iterations":iterations,
            "input_sha256":try hash(inputURL),"reference_sha256":try hash(referenceURL),
            "span_compile_and_load_ms":compilationMS,
            "span":["model_call":stats(spanTimes),"quality":try ImageBuffers.error(spanOutput, reference:reference)],
            "fsrcnnx8":["model_call":stats(fsrTimes),"quality":try ImageBuffers.error(fsrRGB, reference:reference)],
            "peak_rss_bytes":usage.ru_maxrss,"player_realtime":NSNull(),"ane_utilization":NSNull(),
            "note":"Single repeated SDR image; SPAN RGB8 Core ML vs FSRCNNX8 luma NV12 MPSGraph. Setup/warmup, input decode, conversion, quality scoring and PNG writes excluded from model-call timing. Quality includes NV12 chroma subsampling. Compute plan is planned placement, not measured utilization. No audio/display/video timing or temporal quality claim."]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
        try data.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        print(directory.appendingPathComponent("report.json").path)
    }
    static func stats(_ values: [Double]) -> [String: Any] {
        let sorted = values.sorted()
        return ["mean_ms":values.reduce(0,+)/Double(values.count),"p50_ms":sorted[(values.count-1)/2],
                "p95_ms":sorted[min(values.count-1,Int(ceil(Double(values.count)*0.95))-1)],"samples":values.count]
    }
}
