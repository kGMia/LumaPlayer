// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Metal
import CoreVideo

/// Serial, bounded prototype. GPU packing is explicit; Core ML internal copies are opaque.
public final class NV12Pipeline {
    public let model: FSRModel
    public private(set) var timing: [String: Double] = [:]
    private let device: MTLDevice, queue: MTLCommandQueue
    private let cache: CVMetalTextureCache
    private let luma: CVPixelBuffer, upscaledLuma: CVPixelBuffer
    private let outputs: CVPixelBufferPool
    private let assemble: MTLComputePipelineState
    private let lock = NSLock()

    public init(model: FSRModel, device: MTLDevice) throws {
        self.model = model; self.device = device
        guard let queue = device.makeCommandQueue() else { throw FSRError("No Metal queue") }
        self.queue = queue
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw FSRError("No texture cache")
        }
        self.cache = cache
        func attributes(_ w: Int, _ h: Int, _ format: OSType) -> CFDictionary {
            [kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
             kCVPixelBufferPixelFormatTypeKey: format, kCVPixelBufferMetalCompatibilityKey: true,
             kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        }
        var gray: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, model.width, model.height, kCVPixelFormatType_OneComponent8,
            attributes(model.width, model.height, kCVPixelFormatType_OneComponent8), &gray) == kCVReturnSuccess,
              let gray else { throw FSRError("No luma surface") }
        luma = gray
        var grayOutput: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, model.width * 2, model.height * 2, kCVPixelFormatType_OneComponent8,
            attributes(model.width * 2, model.height * 2, kCVPixelFormatType_OneComponent8), &grayOutput) == kCVReturnSuccess,
              let grayOutput else { throw FSRError("No output luma surface") }
        upscaledLuma = grayOutput
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attributes(model.width * 2, model.height * 2,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange), &pool) == kCVReturnSuccess, let pool else {
            throw FSRError("No output pool")
        }
        outputs = pool
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void assemble(texture2d<float, access::read> y [[texture(0)]],
                             texture2d<float, access::sample> uv [[texture(1)]],
                             texture2d<float, access::write> outY [[texture(2)]],
                             texture2d<float, access::write> outUV [[texture(3)]],
                             constant uint &left [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
            if (p.x >= outY.get_width() || p.y >= outY.get_height()) return;
            outY.write(y.read(p), p);
            if ((p.x & 1) == 0 && (p.y & 1) == 0) {
                float2 pos = (float2(p / 2) + 0.5) / float2(outUV.get_width(), outUV.get_height());
                if (left) pos.x += 0.25 / uv.get_width();
                constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
                outUV.write(uv.sample(s, pos), p / 2);
            }
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        guard let function = library.makeFunction(name: "assemble") else { throw FSRError("Missing assembly shader") }
        assemble = try device.makeComputePipelineState(function: function)
    }

    private func texture(_ pixels: CVPixelBuffer, _ plane: Int, _ format: MTLPixelFormat) throws -> (CVMetalTexture, MTLTexture) {
        let planar = CVPixelBufferIsPlanar(pixels)
        let w = planar ? CVPixelBufferGetWidthOfPlane(pixels, plane) : CVPixelBufferGetWidth(pixels)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pixels, plane) : CVPixelBufferGetHeight(pixels)
        var ref: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixels, nil, format, w, h, plane, &ref) == kCVReturnSuccess,
              let ref, let value = CVMetalTextureGetTexture(ref) else { throw FSRError("Image is not Metal texture compatible (format \(CVPixelBufferGetPixelFormatType(pixels)), plane \(plane), \(w)x\(h))") }
        return (ref, value)
    }

    private func finish(_ command: MTLCommandBuffer) throws {
        command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? FSRError("GPU command failed") }
    }

    public func process(_ input: CVPixelBuffer, chromaLeft: Bool = false) throws -> CVPixelBuffer {
        lock.lock(); defer { lock.unlock() }
        timing = [:]
        guard CVPixelBufferGetWidth(input) == model.width, CVPixelBufferGetHeight(input) == model.height,
              CVPixelBufferGetPixelFormatType(input) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
            throw FSRError("Prototype requires fixed-size NV12 video-range8")
        }
        for (key, expected) in [(kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
                                (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
                                (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2)] {
            guard let value = CVBufferCopyAttachment(input, key, nil), CFEqual(value, expected) else {
                throw FSRError("Prototype accepts explicitly tagged SDR BT.709 only; unknown/HDR rejected")
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        let src = try texture(input, 0, .r8Unorm), dst = try texture(luma, 0, .r8Unorm)
        guard let pack = queue.makeCommandBuffer(), let blit = pack.makeBlitCommandEncoder() else { throw FSRError("No pack command") }
        blit.copy(from: src.1, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                  sourceSize: .init(width: model.width, height: model.height, depth: 1),
                  to: dst.1, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
        blit.endEncoding()
        try withExtendedLifetime((src, dst)) { try finish(pack) }
        let packed = ProcessInfo.processInfo.systemUptime
        let prediction = try model.process(luma, outputBacking: upscaledLuma)
        let predicted = ProcessInfo.processInfo.systemUptime
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, outputs,
            [kCVPixelBufferPoolAllocationThresholdKey: 12] as CFDictionary, &output) == kCVReturnSuccess, let output else {
            throw FSRError("Output pool exhausted")
        }
        let textures = try [texture(prediction, 0, .r8Unorm), texture(input, 1, .rg8Unorm),
                            texture(output, 0, .r8Unorm), texture(output, 1, .rg8Unorm)]
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw FSRError("No assembly command") }
        encoder.setComputePipelineState(assemble)
        for (index, pair) in textures.enumerated() { encoder.setTexture(pair.1, index: index) }
        var left: UInt32 = chromaLeft ? 1 : 0
        encoder.setBytes(&left, length: 4, index: 0)
        encoder.dispatchThreads(.init(width: model.width * 2, height: model.height * 2, depth: 1),
                                threadsPerThreadgroup: .init(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        try withExtendedLifetime((textures, prediction)) { try finish(command) }
        CVBufferPropagateAttachments(input, output)
        for key in [kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocationBottomFieldKey] {
            CVBufferSetAttachment(output, key, kCVImageBufferChromaLocation_Center, .shouldPropagate)
        }
        let end = ProcessInfo.processInfo.systemUptime
        timing = ["pack_ms": (packed - start) * 1000, "prediction_call_ms": (predicted - packed) * 1000,
                  "assembly_ms": (end - predicted) * 1000, "total_ms": (end - start) * 1000]
        return output
    }
}
