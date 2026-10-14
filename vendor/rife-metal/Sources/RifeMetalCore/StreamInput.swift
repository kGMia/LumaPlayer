import CoreVideo
import Metal

/// Retains both CVMetalTexture wrappers until synchronous stream inference completes.
/// NV12 is video-range BT.709 with centered chroma; values remain gamma encoded.
public final class StreamInput {
    private let textures: [MTLTexture]
    private let wrappers: [CVMetalTexture]
    private let pixels: CVPixelBuffer
    private let nv12: Bool
    public init(_ pixels: CVPixelBuffer, cache: CVMetalTextureCache) throws {
        self.pixels = pixels
        nv12 = CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if nv12 {
            guard CVPixelBufferGetPlaneCount(pixels) == 2,
                  CVBufferCopyAttachment(pixels, kCVImageBufferYCbCrMatrixKey, nil) as? String == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String,
                  CVBufferCopyAttachment(pixels, kCVImageBufferChromaLocationTopFieldKey, nil) as? String == kCVImageBufferChromaLocation_Center as String else {
                throw IFNetError.commandBufferFailed("NV12 input requires BT.709 matrix and centered chroma attachments")
            }
            var refs: [CVMetalTexture] = []
            var planes: [MTLTexture] = []
            for plane in 0..<2 {
                var ref: CVMetalTexture?
                let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixels, nil,
                    plane == 0 ? .r8Unorm : .rg8Unorm,
                    CVPixelBufferGetWidthOfPlane(pixels, plane), CVPixelBufferGetHeightOfPlane(pixels, plane), plane, &ref)
                guard status == kCVReturnSuccess, let ref, let texture = CVMetalTextureGetTexture(ref) else {
                    throw IFNetError.commandBufferFailed("NV12 Metal plane unavailable: \(status)")
                }
                refs.append(ref); planes.append(texture)
            }
            wrappers = refs; textures = planes
        } else {
            wrappers = []
            textures = [try PixelBufferConvert.makeTexture(from: pixels, textureCache: cache)]
        }
    }
    public func encode(_ encoder: MTLComputeCommandEncoder, kernels: ConversionKernels,
                       output: MTLBuffer, width: Int, height: Int, inverseScale: Float = 1) {
        let pipeline = nv12 ? kernels.nv12ToRGB : (inverseScale == 1 ? kernels.bgraToRGB : kernels.bgraDownsampleToRGB)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(textures[0], index: 0)
        if nv12 { encoder.setTexture(textures[1], index: 1) }
        encoder.setBuffer(output, offset: 0, index: 0)
        var scale = inverseScale
        var size = SIMD2<UInt32>(UInt32(width), UInt32(height))
        encoder.setBytes(&scale, length: MemoryLayout<Float>.size, index: 1)
        encoder.setBytes(&size, length: MemoryLayout<SIMD2<UInt32>>.size, index: 2)
        let w = pipeline.threadExecutionWidth, h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }
}
