// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreML
import CoreVideo

public struct FSRError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum FSRCompute: String, CaseIterable, Sendable {
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

/// Experimental, serial worker. Raw grayscale8 luma. Core ML controls internal copies
/// and dispatch; an IOSurface input is not a promise of end-to-end zero copy.
public final class FSRModel {
    public let width: Int, height: Int
    public let compiledURL: URL
    public let configuration: MLModelConfiguration
    public let metadata: [String: String]
    public private(set) var lastOutputUsedBacking = false
    private let model: MLModel
    private let ownsCompilation: Bool
    private let lock = NSLock()

    public init(url: URL, compute: FSRCompute) throws {
        configuration = MLModelConfiguration()
        configuration.computeUnits = compute.units
        ownsCompilation = url.pathExtension != "mlmodelc"
        compiledURL = ownsCompilation ? try MLModel.compileModel(at: url) : url
        do {
            model = try MLModel(contentsOf: compiledURL, configuration: configuration)
            let description = model.modelDescription
            metadata = description.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
            guard metadata["iive.contract"] == "fsrcnnx-x2-gray8-v1",
                  let input = description.inputDescriptionsByName["luma"]?.imageConstraint,
                  let output = description.outputDescriptionsByName["upscaled"]?.imageConstraint,
                  input.pixelFormatType == kCVPixelFormatType_OneComponent8,
                  output.pixelFormatType == kCVPixelFormatType_OneComponent8,
                  input.pixelsWide >= 8, input.pixelsHigh >= 8,
                  input.pixelsWide % 2 == 0, input.pixelsHigh % 2 == 0,
                  input.pixelsWide <= 1920, input.pixelsHigh <= 1920,
                  output.pixelsWide == input.pixelsWide * 2,
                  output.pixelsHigh == input.pixelsHigh * 2 else {
                throw FSRError("Expected a fixed-size IIVE FSRCNNX x2 grayscale image model")
            }
            width = input.pixelsWide; height = input.pixelsHigh
        } catch {
            if ownsCompilation { try? FileManager.default.removeItem(at: compiledURL) }
            throw error
        }
    }

    public func process(_ input: CVPixelBuffer, outputBacking: CVPixelBuffer? = nil) throws -> CVPixelBuffer {
        guard CVPixelBufferGetWidth(input) == width, CVPixelBufferGetHeight(input) == height,
              CVPixelBufferGetPixelFormatType(input) == kCVPixelFormatType_OneComponent8 else {
            throw FSRError("Expected fixed-size raw grayscale8 luma")
        }
        lock.lock(); defer { lock.unlock() }
        lastOutputUsedBacking = false
        let features = try MLDictionaryFeatureProvider(dictionary: ["luma": MLFeatureValue(pixelBuffer: input)])
        let options = MLPredictionOptions()
        if let outputBacking { options.outputBackings = ["upscaled": outputBacking] }
        guard let output = try model.prediction(from: features, options: options).featureValue(for: "upscaled")?.imageBufferValue,
              CVPixelBufferGetWidth(output) == width * 2, CVPixelBufferGetHeight(output) == height * 2,
              CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_OneComponent8 else {
            throw FSRError("Invalid FSR output image")
        }
        lastOutputUsedBacking = outputBacking.map { output === $0 } ?? false
        return output
    }

    /// Planned device placement only, not a utilization measurement.
    public func computePlan() async throws -> [String: Int] {
        let plan = try await MLComputePlan.load(contentsOf: compiledURL, configuration: configuration)
        guard case .program(let program) = plan.modelStructure else { throw FSRError("No ML Program compute plan") }
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
