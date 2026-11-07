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
    private static func locateJSON(_ name: String) -> URL? {
        let fm = FileManager.default
        if let u = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "Models"), fm.fileExists(atPath: u.path) { return u }
        if let u = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "Resources"), fm.fileExists(atPath: u.path) { return u }
        if let resURL = Bundle.main.resourceURL {
            for rel in [
                "FSRCNNXMetal_FSRCNNXMetal.bundle/Contents/Resources/Resources/\(name).json",
                "FSRCNNXMetal_FSRCNNXMetal.bundle/Resources/\(name).json",
                "Models/\(name).json",
                "Resources/\(name).json"
            ] {
                let candidate = resURL.appendingPathComponent(rel)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        let sourceRelative = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/\(name).json")
        if fm.fileExists(atPath: sourceRelative.path) { return sourceRelative }
        return nil
    }
    static func load(_ tier: FSRCNNXTier) throws -> FSRWeights {
        let name = "fsrcnnx\(tier.rawValue)"
        guard let url = locateJSON(name) ?? Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources") else {
            throw FSRError.unavailable("Model resource missing")
        }
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

/// Shader pipelines are independent of resolution/tier. Keep one device's pair,
/// never frame surfaces or graph workspaces. Every cache access is locked.
private enum FSRKernelCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (UInt64, MTLComputePipelineState, MTLComputePipelineState)?
    static func pipelines(device: MTLDevice, source: String, fallback: URL?) throws -> (MTLComputePipelineState, MTLComputePipelineState) {
        lock.lock(); defer { lock.unlock() }
        if let cached, cached.0 == device.registryID { return (cached.1, cached.2) }
        let library: MTLLibrary
        if let compiled = try? device.makeLibrary(source: source, options: nil) { library = compiled }
        else if let fallback, let bundled = try? device.makeLibrary(URL: fallback) { library = bundled }
        else { library = try device.makeDefaultLibrary(bundle: Bundle.module) }
        guard let read = library.makeFunction(name: "fsrReadLuma"),
              let write = library.makeFunction(name: "fsrWriteNV12") else { throw FSRError.unavailable("Metal kernels missing") }
        let pair = try (device.makeComputePipelineState(function: read), device.makeComputePipelineState(function: write))
        cached = (device.registryID, pair.0, pair.1)
        return pair
    }
}

/// Synchronous per-worker GPU workspace with pre-bound tensor descriptors.
/// One slot is sufficient because process waits for GPU completion before returning.
public final class FSRCNNXModel {
    public let width: Int, height: Int
    let weights: FSRWeights
    private let device: MTLDevice, queue: MTLCommandQueue
    private let executable: MPSGraphExecutable
    private let slot: BufferSlot
    private let inflightSemaphore = DispatchSemaphore(value: 1)
    private var frameCount: UInt64 = 0
    // Serial caller. GPU span includes scheduling gaps between graph submissions;
    // it is not shader-only time and overlaps the CPU wait below.
    public private(set) var lastTiming: (gpuSpanMS: Double, cpuWaitMS: Double)?
    private let readLuma: MTLComputePipelineState, writeNV12: MTLComputePipelineState
    private let cache: CVMetalTextureCache
    private let inputs: CVPixelBufferPool, outputs: CVPixelBufferPool
    public init(device: MTLDevice, width: Int, height: Int, tier: FSRCNNXTier = .fast8) throws {
        guard width > 0, height > 0, width <= 4096, height <= 4096, width % 2 == 0, height % 2 == 0,
              let queue = device.makeCommandQueue() else {throw FSRError.unavailable("Invalid dimensions or GPU queue")}
        let inShape: [NSNumber] = [1, NSNumber(value: height), NSNumber(value: width), 1]
        let outShape: [NSNumber] = [1, NSNumber(value: height), NSNumber(value: width), 4]
        guard let input = device.makeBuffer(length: width * height * 2, options: .storageModePrivate),
              let output = device.makeBuffer(length: width * height * 4 * 2, options: .storageModePrivate) else {
            throw FSRError.unavailable("Invalid dimensions or GPU memory")
        }
        slot=BufferSlot(input:input,output:output,
            inputData:MPSGraphTensorData(input,shape:inShape,dataType:.float16),
            outputData:MPSGraphTensorData(output,shape:outShape,dataType:.float16))
        self.device=device;self.queue=queue;self.width=width;self.height=height
        weights=try FSRWeights.load(tier)
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void fsrReadLuma(texture2d<half,access::read> y [[texture(0)]],
                                device half *out [[buffer(0)]],
                                constant float &lumaScale [[buffer(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
            if(gid.x>=y.get_width() || gid.y>=y.get_height()) return;
            float sampleY = clamp(float(y.read(gid).r) * lumaScale, 0.0f, 1.0f);
            out[gid.y*y.get_width()+gid.x]=half(sampleY);
        }
        kernel void fsrWriteNV12(device const half *subpixel [[buffer(0)]],
                                 texture2d<half,access::sample> sourceUV [[texture(0)]],
                                 texture2d<half,access::write> y [[texture(1)]] ,
                                 texture2d<half,access::write> uv [[texture(2)]],
                                 texture2d<half,access::sample> sourceY [[texture(3)]],
                                 constant float4 &chromaParams [[buffer(1)]],
                                 uint2 gid [[thread_position_in_grid]]) {
            if(gid.x>=y.get_width() || gid.y>=y.get_height()) return;
            constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
            uint w=y.get_width()/2;
            uint i=((gid.y/2)*w+gid.x/2)*4+(gid.x%2)*2+gid.y%2;
            float2 lumaPos = (float2(gid)+0.5f)/float2(y.get_width(),y.get_height());
            float srY = clamp(float(subpixel[i]), 0.0f, 1.0f);
            float splitRatio = chromaParams.z;
            // Comparison must preserve the normal model output on the SR side.
            // The source side uses bilinear scaling to the same output dimensions.
            half lumaOut = half(srY);
            if(splitRatio > 0.0f && lumaPos.x < splitRatio) {
                lumaOut = half(clamp(float(sourceY.sample(s,lumaPos).r) * chromaParams.y, 0.0f, 1.0f));
            }
            y.write(half4(lumaOut,0,0,1),gid);
            if((gid.x%2)==0 && (gid.y%2)==0) {
                float2 pos=(float2(gid/2)+0.5f)/float2(uv.get_width(),uv.get_height());
                pos.x += chromaParams.x / float(sourceUV.get_width());
                float2 chroma = clamp(float2(sourceUV.sample(s,pos).rg) * chromaParams.y, 0.0f, 1.0f);
                uv.write(half4(half2(chroma),0,1),gid/2);
            }
        }
        """
        (readLuma, writeNV12) = try FSRKernelCache.pipelines(device: device, source: shaderSource, fallback: Self.locateMetallib())
        var textureCache:CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil,nil,device,nil,&textureCache)==kCVReturnSuccess,let textureCache else {throw FSRError.unavailable("Texture cache")}
        cache=textureCache
        inputs=try Self.pool(width,height)
        // Retain a small warm output pool across seek/trim. This is an estimate,
        // not a resident-memory cap; large outputs keep the old zero minimum.
        let keepOutputs = UInt64(width*2) * UInt64(height*2) * 3 <= 32 * 1024 * 1024 ? 2 : 0
        outputs=try Self.pool(width*2,height*2,minimum:keepOutputs)
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
    private static func locateMetallib() -> URL? {
        let fm = FileManager.default
        if let resURL = Bundle.main.resourceURL {
            for rel in [
                "FSRCNNXMetal_FSRCNNXMetal.bundle/Contents/Resources/default.metallib",
                "FSRCNNXMetal_FSRCNNXMetal.bundle/default.metallib",
                "default.metallib"
            ] {
                let candidate = resURL.appendingPathComponent(rel)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        let pkgRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for rel in [
            ".build/release/FSRCNNXMetal_FSRCNNXMetal.bundle/Contents/Resources/default.metallib",
            ".build/arm64-apple-macosx/release/FSRCNNXMetal_FSRCNNXMetal.bundle/default.metallib"
        ] {
            let candidate = pkgRoot.appendingPathComponent(rel)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
    private static func pool(_ w:Int,_ h:Int,minimum:Int=0)throws->CVPixelBufferPool {
        var pool:CVPixelBufferPool?
        let attrs:[CFString:Any]=[kCVPixelBufferWidthKey:w,kCVPixelBufferHeightKey:h,
            kCVPixelBufferPixelFormatTypeKey:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey:[:],kCVPixelBufferMetalCompatibilityKey:true]
        let policy=[kCVPixelBufferPoolMinimumBufferCountKey:minimum] as CFDictionary
        guard CVPixelBufferPoolCreate(nil,policy,attrs as CFDictionary,&pool)==kCVReturnSuccess,let pool else {throw FSRError.unavailable("Pixel pool")}
        return pool
    }
    private func allocate(_ pool:CVPixelBufferPool)throws->CVPixelBuffer {
        var out:CVPixelBuffer?
        let limits=[kCVPixelBufferPoolAllocationThresholdKey:12] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil,pool,limits,&out)==kCVReturnSuccess,let out else {throw FSRError.unavailable("Pixel pool capacity")}
        return out
    }
    /// Worker boundary only; outstanding output frames retain their own surfaces.
    public func releaseUnusedResources() {
        inflightSemaphore.wait()
        defer { inflightSemaphore.signal() }
        CVMetalTextureCacheFlush(cache, 0)
        CVPixelBufferPoolFlush(inputs, .excessBuffers)
        CVPixelBufferPoolFlush(outputs, .excessBuffers)
    }
    public func makeInput()throws->CVPixelBuffer {try allocate(inputs)}
    private func plane(_ pixels:CVPixelBuffer,_ index:Int,tenBit:Bool=false,writable:Bool=false)throws->(CVMetalTexture,MTLTexture) {
        var ref:CVMetalTexture?
        let attrs=[kCVMetalTextureUsage:(writable ? MTLTextureUsage.shaderWrite : .shaderRead).rawValue] as CFDictionary
        let format:MTLPixelFormat = tenBit ? (index==0 ? .r16Unorm : .rg16Unorm) : (index==0 ? .r8Unorm : .rg8Unorm)
        let status=CVMetalTextureCacheCreateTextureFromImage(nil,cache,pixels,attrs,format,
            CVPixelBufferGetWidthOfPlane(pixels,index),CVPixelBufferGetHeightOfPlane(pixels,index),index,&ref)
        guard status==kCVReturnSuccess,let ref,let tex=CVMetalTextureGetTexture(ref) else {throw FSRError.unavailable("Metal plane \(status)")}
        return(ref,tex)
    }
    private func dispatch(_ encoder:MTLComputeCommandEncoder,_ pipeline:MTLComputePipelineState,_ w:Int,_ h:Int) {
        encoder.setComputePipelineState(pipeline)
        let x=pipeline.threadExecutionWidth,y=max(1,pipeline.maxTotalThreadsPerThreadgroup/x)
        encoder.dispatchThreads(MTLSize(width:w,height:h,depth:1),threadsPerThreadgroup:MTLSize(width:x,height:y,depth:1))
    }
    public func process(_ pixels:CVPixelBuffer, chromaLeft:Bool=false, splitRatio:Float=0.0)throws->CVPixelBuffer {
        lastTiming = nil
        let fmt=CVPixelBufferGetPixelFormatType(pixels)
        let isTenBit=(fmt==kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        guard CVPixelBufferGetWidth(pixels)==width,CVPixelBufferGetHeight(pixels)==height,
              (fmt==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || isTenBit) else {throw FSRError.unavailable("Expected fixed-size 420v or x420")}
        inflightSemaphore.wait()
        defer { inflightSemaphore.signal() }
        frameCount &+= 1
        let shouldFlushCache = (frameCount & 63) == 0
        if shouldFlushCache { CVMetalTextureCacheFlush(cache, 0) }
        let output=try allocate(outputs)
        let y=try plane(pixels,0,tenBit:isTenBit),uv=try plane(pixels,1,tenBit:isTenBit)
        let oy=try plane(output,0,writable:true),ouv=try plane(output,1,writable:true)
        defer{withExtendedLifetime((y,uv,oy,ouv,pixels,output)) {}}
        guard let cb=queue.makeCommandBuffer() else {throw FSRError.unavailable("Command buffer")}
        let command=MPSCommandBuffer(commandBuffer:cb)
        var inputScale:Float = isTenBit ? (257.0 / 256.0) : 1.0
        guard let read=command.commandBuffer.makeComputeCommandEncoder() else {throw FSRError.unavailable("Input encoder")}
        read.setTexture(y.1,index:0);read.setBuffer(slot.input,offset:0,index:0)
        read.setBytes(&inputScale,length:MemoryLayout<Float>.size,index:1)
        dispatch(read,readLuma,width,height);read.endEncoding()
        executable.encode(to:command,inputs:[slot.inputData],results:[slot.outputData],executionDescriptor:nil)
        guard let write=command.commandBuffer.makeComputeCommandEncoder() else {throw FSRError.unavailable("Output encoder")}
        write.setBuffer(slot.output,offset:0,index:0)
        write.setTexture(uv.1,index:0)
        write.setTexture(oy.1,index:1)
        write.setTexture(ouv.1,index:2)
        write.setTexture(y.1,index:3)
        let clampedSplit = max(0.0, min(1.0, splitRatio))
        var chromaParams=SIMD4<Float>(chromaLeft ? 0.25 : 0.0, inputScale, clampedSplit, 0.0)
        write.setBytes(&chromaParams,length:MemoryLayout<SIMD4<Float>>.size,index:1)
        dispatch(write,writeNV12,width*2,height*2);write.endEncoding()
        // MPSGraph may commitAndContinue internally. The original buffer marks
        // the start; the current root marks completion of ALL graph work.
        let final=command.rootCommandBuffer
        command.commit()
        let waitStart=ProcessInfo.processInfo.systemUptime
        command.waitUntilCompleted()
        let waitMS=(ProcessInfo.processInfo.systemUptime-waitStart)*1000
        if let error=final.error ?? cb.error {throw error}
        let start=cb.gpuStartTime,end=final.gpuEndTime
        if start.isFinite,end.isFinite,start>0,end>=start {
            lastTiming=((end-start)*1000,waitMS)
        }
        // Recycled surfaces must not inherit optional attachments from an old frame.
        CVBufferRemoveAllAttachments(output)
        CVBufferPropagateAttachments(pixels,output)
        CVBufferSetAttachment(output,kCVImageBufferChromaLocationTopFieldKey,kCVImageBufferChromaLocation_Center,.shouldPropagate)
        CVBufferSetAttachment(output,kCVImageBufferChromaLocationBottomFieldKey,kCVImageBufferChromaLocation_Center,.shouldPropagate)
        return output
    }
}
