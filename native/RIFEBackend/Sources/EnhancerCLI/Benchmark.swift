import Foundation
import CoreVideo
import Metal
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
func benchmark(width:Int,height:Int,tier:RifeQualityTier,iterations:Int) throws {
 guard (1...1000).contains(iterations),width>0,height>0,width<=4096,height<=4096 else {throw BackendError.invalid("Invalid benchmark dimensions/count")}
 let model=try RifeInterpolator(configuration:.bundled(qualityTier:tier))
 let stream=try model.makeStream(width:width,height:height)
 let a=try buffer(width,height,0),b=try buffer(width,height,4)
 _=try stream.push(a);_=try stream.push(b);_=try stream.push(a)
 var samples:[Double]=[]
 let begin=ProcessInfo.processInfo.systemUptime
 for i in 0..<iterations {try autoreleasepool {let start=ProcessInfo.processInfo.systemUptime;_=try stream.push(i%2==0 ? b:a);samples.append((ProcessInfo.processInfo.systemUptime-start)*1000)}}
 let elapsed=ProcessInfo.processInfo.systemUptime-begin
 try Stats.emit(["kind":"model_stream_midpoint","device":MTLCreateSystemDefaultDevice()?.name ?? "N/A","width":width,"height":height,"tier":tier.rawValue,"warmup_pushes":3,"generated_frames":iterations,"wall_seconds":elapsed,"generated_fps":Double(iterations)/elapsed,"latency":Stats.summarize(samples),"peak_rss_bytes":Stats.memory(),"gpu_utilization":NSNull(),"cpu_utilization":NSNull(),"dropped_frames":NSNull(),"player_realtime":NSNull(),"note":"Synthetic moving gradients. Inference + upstream padding/cropping; excludes decode, encode, display and audio. Not player FPS."])
}
