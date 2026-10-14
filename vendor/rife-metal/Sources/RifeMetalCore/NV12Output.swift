import CoreVideo
import Metal

/// An IOSurface output with retained CoreVideo texture wrappers; keep until GPU completion.
public final class NV12Output {
    private let pixels: CVPixelBuffer
    private let wrappers: [CVMetalTexture]
    private let planes: [MTLTexture]
    public static func makePool(width:Int,height:Int)throws->CVPixelBufferPool {
        guard width>0,height>0,width%2==0,height%2==0 else {throw IFNetError.dimensionsMismatch}
        var pool:CVPixelBufferPool?
        let attrs:[CFString:Any]=[kCVPixelBufferWidthKey:width,kCVPixelBufferHeightKey:height,
            kCVPixelBufferPixelFormatTypeKey:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey:[:],kCVPixelBufferMetalCompatibilityKey:true]
        guard CVPixelBufferPoolCreate(nil,nil,attrs as CFDictionary,&pool)==kCVReturnSuccess,let pool else {throw IFNetError.textureAllocationFailed}
        return pool
    }
    public static func allocate(_ pool:CVPixelBufferPool)throws->CVPixelBuffer {
        var pixels:CVPixelBuffer?
        let limits=[kCVPixelBufferPoolAllocationThresholdKey:12] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil,pool,limits,&pixels)==kCVReturnSuccess,let pixels else {throw IFNetError.textureAllocationFailed}
        CVBufferSetAttachment(pixels,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
        CVBufferSetAttachment(pixels,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
        CVBufferSetAttachment(pixels,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,.shouldPropagate)
        CVBufferSetAttachment(pixels,kCVImageBufferChromaLocationTopFieldKey,kCVImageBufferChromaLocation_Center,.shouldPropagate)
        return pixels
    }
    public init(_ pixels:CVPixelBuffer,cache:CVMetalTextureCache)throws {
        guard CVPixelBufferGetPixelFormatType(pixels)==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetWidth(pixels)%2==0,CVPixelBufferGetHeight(pixels)%2==0 else {throw IFNetError.dimensionsMismatch}
        self.pixels=pixels
        var refs:[CVMetalTexture]=[],textures:[MTLTexture]=[]
        for i in 0..<2 {
            var ref:CVMetalTexture?
            let attrs=[kCVMetalTextureUsage:MTLTextureUsage.shaderWrite.rawValue] as CFDictionary
            let code=CVMetalTextureCacheCreateTextureFromImage(nil,cache,pixels,attrs,i==0 ? .r8Unorm:.rg8Unorm,
                CVPixelBufferGetWidthOfPlane(pixels,i),CVPixelBufferGetHeightOfPlane(pixels,i),i,&ref)
            guard code==kCVReturnSuccess,let ref,let tex=CVMetalTextureGetTexture(ref) else {throw IFNetError.textureAllocationFailed}
            refs.append(ref);textures.append(tex)
        }
        wrappers=refs;planes=textures
    }
    public func encode(_ enc:MTLComputeCommandEncoder,pipeline:MTLComputePipelineState,
                       previous:MTLBuffer,current:MTLBuffer,mask:MTLBuffer,
                       width:Int,height:Int,maskWidth:Int,maskHeight:Int) {
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(previous,offset:0,index:0);enc.setBuffer(current,offset:0,index:1);enc.setBuffer(mask,offset:0,index:2)
        var full=SIMD2<UInt32>(UInt32(width),UInt32(height)),internalSize=SIMD2<UInt32>(UInt32(maskWidth),UInt32(maskHeight))
        enc.setBytes(&full,length:MemoryLayout<SIMD2<UInt32>>.stride,index:3)
        enc.setBytes(&internalSize,length:MemoryLayout<SIMD2<UInt32>>.stride,index:4)
        enc.setTexture(planes[0],index:0);enc.setTexture(planes[1],index:1)
        let w=pipeline.threadExecutionWidth,h=max(1,pipeline.maxTotalThreadsPerThreadgroup/w)
        enc.dispatchThreads(MTLSize(width:planes[1].width,height:planes[1].height,depth:1),threadsPerThreadgroup:MTLSize(width:w,height:h,depth:1))
    }
}
