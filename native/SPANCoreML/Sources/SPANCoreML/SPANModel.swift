// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreML
import CoreVideo

public struct SPANError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum SPANCompute: String, CaseIterable, Sendable {
    case all, cpuGPU = "cpu-gpu", cpuNeuralEngine = "cpu-ne", cpu
    public var units: MLComputeUnits {
        switch self {
        case .all: .all
        case .cpuGPU: .cpuAndGPU
        case .cpuNeuralEngine: .cpuAndNeuralEngine
        case .cpu: .cpuOnly
        }
    }
}

/// Experimental, serial worker. RGB8 SDR only. Core ML controls internal copies
/// and dispatch; an IOSurface input is not a promise of end-to-end zero copy.
public final class SPANModel {
    public let width: Int, height: Int
    public let compiledURL: URL
    public let configuration: MLModelConfiguration
    public let metadata: [String: String]
    private let model: MLModel
    private let ownsCompilation: Bool
    private let lock = NSLock()

    public init(url: URL, compute: SPANCompute) throws {
        configuration = MLModelConfiguration()
        configuration.computeUnits = compute.units
        ownsCompilation = url.pathExtension != "mlmodelc"
        compiledURL = ownsCompilation ? try MLModel.compileModel(at: url) : url
        do {
            model = try MLModel(contentsOf: compiledURL, configuration: configuration)
            let description = model.modelDescription
            metadata = description.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
            guard metadata["iive.contract"] == "span-x2-rgb8-sdr-v1",
                  let input = description.inputDescriptionsByName["image"]?.imageConstraint,
                  let output = description.outputDescriptionsByName["upscaled"]?.imageConstraint,
                  input.pixelFormatType == kCVPixelFormatType_32BGRA,
                  output.pixelFormatType == kCVPixelFormatType_32BGRA,
                  input.pixelsWide > 0, input.pixelsHigh > 0,
                  input.pixelsWide <= 1920, input.pixelsHigh <= 1920,
                  output.pixelsWide == input.pixelsWide * 2,
                  output.pixelsHigh == input.pixelsHigh * 2 else {
                throw SPANError("Expected a fixed-size IIVE SPAN x2 SDR image model")
            }
            width = input.pixelsWide; height = input.pixelsHigh
        } catch {
            if ownsCompilation { try? FileManager.default.removeItem(at: compiledURL) }
            throw error
        }
    }

    public func process(_ input: CVPixelBuffer) throws -> CVPixelBuffer {
        guard CVPixelBufferGetWidth(input) == width, CVPixelBufferGetHeight(input) == height,
              CVPixelBufferGetPixelFormatType(input) == kCVPixelFormatType_32BGRA,
              let transfer = CVBufferCopyAttachment(input, kCVImageBufferTransferFunctionKey, nil),
              CFEqual(transfer, kCVImageBufferTransferFunction_sRGB),
              let primaries = CVBufferCopyAttachment(input, kCVImageBufferColorPrimariesKey, nil),
              CFEqual(primaries, kCVImageBufferColorPrimaries_ITU_R_709_2) else {
            throw SPANError("SPAN prototype requires fixed-size BGRA8 sRGB / BT.709 primaries; HDR/unknown color rejected")
        }
        lock.lock(); defer { lock.unlock() }
        let features = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)])
        guard let output = try model.prediction(from: features).featureValue(for: "upscaled")?.imageBufferValue,
              CVPixelBufferGetWidth(output) == width * 2, CVPixelBufferGetHeight(output) == height * 2,
              CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_32BGRA else {
            throw SPANError("Invalid SPAN output image")
        }
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        return output
    }

    /// Planned device placement only, not a utilization measurement.
    public func computePlan() async throws -> [String: Int] {
        let plan = try await MLComputePlan.load(contentsOf: compiledURL, configuration: configuration)
        guard case .program(let program) = plan.modelStructure else { throw SPANError("No ML Program compute plan") }
        var counts: [String: Int] = [:]
        func visit(_ block: MLModelStructure.Program.Block) {
            for operation in block.operations {
                if operation.operatorName != "const" {
                    var name = "unknown"
                    if let usage = plan.deviceUsage(for: operation) {
                        switch usage.preferred {
                        case .cpu: name = "cpu"
                        case .gpu: name = "gpu"
                        case .neuralEngine: name = "neural_engine"
                        @unknown default: break
                        }
                    }
                    counts[name, default: 0] += 1
                }
                for nested in operation.blocks { visit(nested) }
            }
        }
        for function in program.functions.values { visit(function.block) }
        return counts
    }

    deinit { if ownsCompilation { try? FileManager.default.removeItem(at: compiledURL) } }
}
