import Foundation
import CoreVideo
import Metal
import CoreMedia
import CryptoKit
import RifeMetal
import EnhancerCore
func buffer(_ width:Int,_ height:Int,_ shift:Int) throws -> CVPixelBuffer {
 var p:CVPixelBuffer?
 let attrs:[String:Any]=[kCVPixelBufferMetalCompatibilityKey as String:true,kCVPixelBufferIOSurfacePropertiesKey as String:[:]]
 guard CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,attrs as CFDictionary,&p)==kCVReturnSuccess,let p else {throw BackendError.invalid("Allocation failed")}
 CVPixelBufferLockBaseAddress(p,[]);defer{CVPixelBufferUnlockBaseAddress(p,[])}
 let a=CVPixelBufferGetBaseAddress(p)!.assumingMemoryBound(to:UInt8.self),s=CVPixelBufferGetBytesPerRow(p)
 for y in 0..<height {for x in 0..<width {let i=y*s+x*4;a[i]=UInt8((x+shift)%256);a[i+1]=UInt8((y+shift)%256);a[i+2]=UInt8((x+y+shift)%256);a[i+3]=255}}
 return p
}
func nv12Buffer(_ width:Int,_ height:Int,_ shift:Int) throws -> CVPixelBuffer {
 var pixel:CVPixelBuffer?
 let attrs:[String:Any]=[kCVPixelBufferMetalCompatibilityKey as String:true,kCVPixelBufferIOSurfacePropertiesKey as String:[:]]
 guard width%2==0,height%2==0,CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,attrs as CFDictionary,&pixel)==kCVReturnSuccess,let pixel else {throw BackendError.invalid("NV12 allocation failed")}
 guard CVPixelBufferLockBaseAddress(pixel,[])==kCVReturnSuccess else {throw BackendError.invalid("Pixel lock failed")}
 defer{CVPixelBufferUnlockBaseAddress(pixel,[])}
 for plane in 0..<2 {
  guard let base=CVPixelBufferGetBaseAddressOfPlane(pixel,plane) else{throw BackendError.invalid("Missing NV12 plane")}
  let stride=CVPixelBufferGetBytesPerRowOfPlane(pixel,plane),rows=CVPixelBufferGetHeightOfPlane(pixel,plane)
  let bytes=base.assumingMemoryBound(to:UInt8.self)
  for y in 0..<rows {for x in 0..<stride {bytes[y*stride+x]=plane==0 ? UInt8(16+(x+y+shift)%220) : 128}}
 }
 CVBufferSetAttachment(pixel,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
 CVBufferSetAttachment(pixel,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,.shouldPropagate)
 CVBufferSetAttachment(pixel,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
 CVBufferSetAttachment(pixel,kCVImageBufferChromaLocationTopFieldKey,kCVImageBufferChromaLocation_Center,.shouldPropagate)
 return pixel
}
func benchmark(width:Int,height:Int,tier:RifeQualityTier,iterations:Int,
               modelURL:URL=RifeConfiguration.bundledModelURL,sourceFPS:Int32=24,targetFPS:Int32=48,nv12:Bool=false) throws {
 guard (1...1000).contains(iterations),width>0,height>0,width<=4096,height<=4096,
       [24,30].contains(sourceFPS),[48,60].contains(targetFPS),targetFPS>sourceFPS else {throw BackendError.invalid("Invalid benchmark dimensions/count/FPS")}
 let setupStart=ProcessInfo.processInfo.systemUptime
 let model=try RifeInterpolator(configuration:RifeConfiguration(modelURL:modelURL,qualityTier:tier))
 let stream=try model.makeStream(width:width,height:height)
 let a=try (nv12 ? nv12Buffer(width,height,0) : buffer(width,height,0))
 let b=try (nv12 ? nv12Buffer(width,height,4) : buffer(width,height,4))
 var timeline=try Timeline(fps:targetFPS)
 var pair=0
 func pushPair()throws->Int {
  let from=CMTime(value:Int64(pair),timescale:sourceFPS),to=CMTime(value:Int64(pair+1),timescale:sourceFPS)
  let fractions=try timeline.between(from,to).filter{$0.fraction>0.000001}.map(\.fraction)
  let output=try stream.push(pair%2==0 ? b:a,timesteps:fractions,outputNV12:nv12)
  guard output.count==fractions.count else{throw BackendError.invalid("Unexpected output count")}
  pair+=1
  return output.count
 }
 _=try stream.push(a,timesteps:[])
 for _ in 0..<3 {_=try pushPair()}
 let setupMS=(ProcessInfo.processInfo.systemUptime-setupStart)*1000
 var samples:[Double]=[],gpu:[Double]=[],wait:[Double]=[]
 var generated=0
 let begin=ProcessInfo.processInfo.systemUptime
 for _ in 0..<iterations {try autoreleasepool {
  let start=ProcessInfo.processInfo.systemUptime
  generated+=try pushPair()
  samples.append((ProcessInfo.processInfo.systemUptime-start)*1000)
  if let timing=stream.lastTiming {gpu.append(timing.gpuSpanMS);wait.append(timing.cpuWaitMS)}
 }}
 let elapsed=ProcessInfo.processInfo.systemUptime-begin
 let hash=SHA256.hash(data:try Data(contentsOf:modelURL,options:.mappedIfSafe)).map{String(format:"%02x",$0)}.joined()
 try Stats.emit(["kind":"model_stream_intervals","model":model.modelName,"model_sha256":hash,
  "device":MTLCreateSystemDefaultDevice()?.name ?? "N/A","width":width,"height":height,"tier":tier.rawValue,
  "source_fps":sourceFPS,"target_fps":targetFPS,"pixel_format":nv12 ? "nv12" : "bgra",
  "padding_multiple":model.modelPaddingMultiple,"warmup_pairs":3,"setup_and_warmup_ms":setupMS,
  "source_pairs":iterations,"generated_frames":generated,"wall_seconds":elapsed,
  "generated_fps":Double(generated)/elapsed,"source_pair_fps":Double(iterations)/elapsed,
  "latency":Stats.summarize(samples),"gpu_span":Stats.summarize(gpu),"cpu_wait":Stats.summarize(wait),
  "peak_rss_bytes":Stats.memory(),"gpu_utilization":NSNull(),"cpu_utilization":NSNull(),
  "dropped_frames":NSNull(),"player_realtime":NSNull(),
  "note":"Synthetic gradients; exact interval timesteps including alternating 24-to-60 batches. Excludes decode, encode, display and audio; not player FPS or a quality assessment. GPU span includes submission gaps and overlaps CPU wait."])
}
