// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreVideo
import Metal
import MetalPerformanceShaders
import MetalPerformanceShadersGraph

public enum FSRCNNXTier: Int, Sendable { case fast8 = 8, quality16 = 16 }
enum FSRError: Error { case unavailable(String) }
struct FSRLayer: Decodable {
    let name: String, input: String
    let shape: [Int], weights: [Float], bias: [Float], alpha: [Float]
    let skip: String?
}
struct FSRWeights: Decodable {
    let format: Int, tier: Int
    let layout: String, subpixelOrder: String, sha256: String
    let layers: [FSRLayer]
    static func load(_ tier: FSRCNNXTier) throws -> FSRWeights {
        guard let url = Bundle.module.url(forResource: "fsrcnnx\(tier.rawValue)", withExtension: "json", subdirectory: "Resources") else {throw FSRError.unavailable("Model resource missing")}
        let w = try JSONDecoder().decode(FSRWeights.self, from: Data(contentsOf: url))
        guard w.format == 1, w.tier == tier.rawValue, w.layout == "HWIO", w.subpixelOrder == "x*2+y", w.layers.count == 7 else {throw FSRError.unavailable("Model format mismatch")}
        return w
    }
}

private struct BufferSlot {
    let input: MTLBuffer
    let output: MTLBuffer
    let inputData: MPSGraphTensorData
    let outputData: MPSGraphTensorData
}

/// Double-buffered GPU workspace, pre-bound MPSGraphTensorData descriptors, and periodic texture-cache maintenance.
public final class FSRCNNXModel {
    public let width: Int, height: Int
    let weights: FSRWeights
    private let device: MTLDevice, queue: MTLCommandQueue
    private let executable: MPSGraphExecutable
    private let slots: [BufferSlot]
    private let inflightSemaphore = DispatchSemaphore(value: 2)
    private let slotLock = NSLock()
    private var nextSlot = 0
    private var frameCount: UInt64 = 0
    private let readLuma: MTLComputePipelineState, writeNV12: MTLComputePipelineState
    private let cache: CVMetalTextureCache
    private let inputs: CVPixelBufferPool, outputs: CVPixelBufferPool
    public init(device: MTLDevice, width: Int, height: Int, tier: FSRCNNXTier = .fast8) throws {
        guard width > 0, height > 0, width <= 4096, height <= 4096, width % 2 == 0, height % 2 == 0,
              let queue = device.makeCommandQueue() else {throw FSRError.unavailable("Invalid dimensions or GPU queue")}
        let inShape: [NSNumber] = [1, NSNumber(value: height), NSNumber(value: width), 1]
        let outShape: [NSNumber] = [1, NSNumber(value: height), NSNumber(value: width), 4]
        var allocatedSlots: [BufferSlot] = []
        allocatedSlots.reserveCapacity(2)
        for _ in 0..<2 {
            guard let input = device.makeBuffer(length: width * height * 2, options: .storageModePrivate),
                  let output = device.makeBuffer(length: width * height * 4 * 2, options: .storageModePrivate) else {
                throw FSRError.unavailable("Invalid dimensions or GPU memory")
            }
            allocatedSlots.append(BufferSlot(
                input: input,
                output: output,
                inputData: MPSGraphTensorData(input, shape: inShape, dataType: .float16),
                outputData: MPSGraphTensorData(output, shape: outShape, dataType: .float16)
            ))
        }
        self.device=device;self.queue=queue;self.width=width;self.height=height
        self.slots=allocatedSlots
        weights=try FSRWeights.load(tier)
        let library=try device.makeDefaultLibrary(bundle: Bundle.module)
        guard let read=library.makeFunction(name:"fsrReadLuma"),let write=library.makeFunction(name:"fsrWriteNV12") else {throw FSRError.unavailable("Metal kernels missing")}
        readLuma=try device.makeComputePipelineState(function:read)
        writeNV12=try device.makeComputePipelineState(function:write)
        var textureCache:CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil,nil,device,nil,&textureCache)==kCVReturnSuccess,let textureCache else {throw FSRError.unavailable("Texture cache")}
        cache=textureCache
        inputs=try Self.pool(width,height);outputs=try Self.pool(width*2,height*2)
        let graph=MPSGraph(), shape:[NSNumber]=inShape
        let tensor=graph.placeholder(shape:shape,dataType:.float16,name:"luma")
        var tensors=["input":tensor]
        func constant(_ values:[Float],_ shape:[Int])->MPSGraphTensor {
            let halves=values.map{Float16($0)}
            let bytes=halves.withUnsafeBytes{Data($0)}
            return graph.constant(bytes,shape:shape.map{NSNumber(value:$0)},dataType:.float16)
        }
        for layer in weights.layers {
            guard layer.shape.count==4,layer.weights.count==layer.shape.reduce(1,*),
                  layer.bias.count==layer.shape[3], let source=tensors[layer.input] else {throw FSRError.unavailable("Invalid layer \(layer.name)")}
            let radius=layer.shape[0]/2
            let padded=radius==0 ? source : graph.padTensor(source,with:.clampToEdge,
                leftPadding:[0,NSNumber(value:radius),NSNumber(value:radius),0],
                rightPadding:[0,NSNumber(value:radius),NSNumber(value:radius),0],constantValue:0,name:nil)
            let descriptor=MPSGraphConvolution2DOpDescriptor(strideInX:1,strideInY:1,dilationRateInX:1,dilationRateInY:1,groups:1,paddingLeft:0,paddingRight:0,paddingTop:0,paddingBottom:0,paddingStyle:.explicit,dataLayout:.NHWC,weightsLayout:.HWIO)!
            var value=graph.convolution2D(padded,weights:constant(layer.weights,layer.shape),descriptor:descriptor,name:layer.name)
            value=graph.addition(value,constant(layer.bias,[1,1,1,layer.bias.count]),name:nil)
            if let skip=layer.skip {
                guard let residual=tensors[skip] else {throw FSRError.unavailable("Missing residual")}
                value=graph.addition(value,residual,name:nil)
            }
            if !layer.alpha.isEmpty {
                guard layer.alpha.count==layer.bias.count else {throw FSRError.unavailable("Invalid PReLU")}
                let zero=graph.constant(0,dataType:.float16)
                value=graph.addition(graph.maximum(value,zero,name:nil),
                    graph.multiplication(constant(layer.alpha,[1,1,1,layer.alpha.count]),graph.minimum(value,zero,name:nil),name:nil),name:nil)
            }
            tensors[layer.name]=value
        }
        guard let result=tensors["stage6"] else {throw FSRError.unavailable("Missing output")}
        let compilation=MPSGraphCompilationDescriptor();compilation.optimizationLevel = .level1
        executable=graph.compile(with:MPSGraphDevice(mtlDevice:device),
            feeds:[tensor:MPSGraphShapedType(shape:shape,dataType:.float16)],targetTensors:[result],targetOperations:nil,compilationDescriptor:compilation)
    }
    private static func pool(_ w:Int,_ h:Int)throws->CVPixelBufferPool {
        var pool:CVPixelBufferPool?
        let attrs:[CFString:Any]=[kCVPixelBufferWidthKey:w,kCVPixelBufferHeightKey:h,
            kCVPixelBufferPixelFormatTypeKey:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey:[:],kCVPixelBufferMetalCompatibilityKey:true]
        guard CVPixelBufferPoolCreate(nil,nil,attrs as CFDictionary,&pool)==kCVReturnSuccess,let pool else {throw FSRError.unavailable("Pixel pool")}
        return pool
    }
    private func allocate(_ pool:CVPixelBufferPool)throws->CVPixelBuffer {
        var out:CVPixelBuffer?
        let limits=[kCVPixelBufferPoolAllocationThresholdKey:12] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil,pool,limits,&out)==kCVReturnSuccess,let out else {throw FSRError.unavailable("Pixel pool capacity")}
        return out
    }
    public func makeInput()throws->CVPixelBuffer {try allocate(inputs)}
    private func plane(_ pixels:CVPixelBuffer,_ index:Int)throws->(CVMetalTexture,MTLTexture) {
        var ref:CVMetalTexture?
        let attrs=[kCVMetalTextureUsage:MTLTextureUsage([.shaderRead,.shaderWrite]).rawValue] as CFDictionary
        let status=CVMetalTextureCacheCreateTextureFromImage(nil,cache,pixels,attrs,index==0 ? .r8Unorm:.rg8Unorm,
            CVPixelBufferGetWidthOfPlane(pixels,index),CVPixelBufferGetHeightOfPlane(pixels,index),index,&ref)
        guard status==kCVReturnSuccess,let ref,let tex=CVMetalTextureGetTexture(ref) else {throw FSRError.unavailable("Metal plane \(status)")}
        return(ref,tex)
    }
    private func dispatch(_ encoder:MTLComputeCommandEncoder,_ pipeline:MTLComputePipelineState,_ w:Int,_ h:Int) {
        encoder.setComputePipelineState(pipeline)
        let x=pipeline.threadExecutionWidth,y=max(1,pipeline.maxTotalThreadsPerThreadgroup/x)
        encoder.dispatchThreads(MTLSize(width:w,height:h,depth:1),threadsPerThreadgroup:MTLSize(width:x,height:y,depth:1))
    }
    public func process(_ pixels:CVPixelBuffer)throws->CVPixelBuffer {
        guard CVPixelBufferGetWidth(pixels)==width,CVPixelBufferGetHeight(pixels)==height,
              CVPixelBufferGetPixelFormatType(pixels)==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {throw FSRError.unavailable("Expected fixed-size 420v")}
        inflightSemaphore.wait()
        var committed = false
        defer { if !committed { inflightSemaphore.signal() } }
        slotLock.lock()
        let slot = slots[nextSlot]
        nextSlot = (nextSlot + 1) % slots.count
        frameCount &+= 1
        let shouldFlushCache = (frameCount & 63) == 0
        slotLock.unlock()
        if shouldFlushCache { CVMetalTextureCacheFlush(cache, 0) }
        let output=try allocate(outputs)
        let y=try plane(pixels,0),uv=try plane(pixels,1),oy=try plane(output,0),ouv=try plane(output,1)
        defer{withExtendedLifetime((y,uv,oy,ouv,pixels,output)) {}}
        guard let cb=queue.makeCommandBuffer() else {throw FSRError.unavailable("Command buffer")}
        let command=MPSCommandBuffer(commandBuffer:cb)
        guard let read=command.commandBuffer.makeComputeCommandEncoder() else {throw FSRError.unavailable("Input encoder")}
        read.setTexture(y.1,index:0);read.setBuffer(slot.input,offset:0,index:0)
        dispatch(read,readLuma,width,height);read.endEncoding()
        executable.encode(to:command,inputs:[slot.inputData],results:[slot.outputData],executionDescriptor:nil)
        guard let write=command.commandBuffer.makeComputeCommandEncoder() else {throw FSRError.unavailable("Output encoder")}
        write.setBuffer(slot.output,offset:0,index:0);write.setTexture(uv.1,index:0);write.setTexture(oy.1,index:1);write.setTexture(ouv.1,index:2)
        dispatch(write,writeNV12,width*2,height*2);write.endEncoding()
        let final=command.commandBuffer
        let sem = inflightSemaphore
        final.addCompletedHandler { _ in sem.signal() }
        committed = true
        command.commit();command.waitUntilCompleted()
        if let error=final.error {throw error}
        CVBufferPropagateAttachments(pixels,output)
        return output
    }
}
