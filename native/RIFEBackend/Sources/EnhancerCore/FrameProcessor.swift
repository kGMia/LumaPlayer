import Foundation
import CoreVideo
import CoreMedia
import RifeMetal

public struct VideoFrame { public let pixels:CVPixelBuffer; public let pts:CMTime; public let synthesized:Bool }
public final class FrameProcessor {
 private let interpolator:RifeInterpolator
 private let width:Int, height:Int
 private var stream:RifeStream
 private var timeline:Timeline
 private var previous:(CVPixelBuffer,CMTime)?
 public private(set) var inferenceMilliseconds:[Double]=[]
 public private(set) var inferenceCount=0
 public private(set) var inferenceTotalMilliseconds=0.0
 public private(set) var sceneCuts=0
 public private(set) var duplicates=0
 public private(set) var fallback=false
 private var bad=0
 private var pushes=0
 private let nativeNV12Output:Bool
 private let autoFallback:Bool
 private let sceneThreshold:Double
 public init(width:Int,height:Int,fps:Int32,tier:RifeQualityTier,autoFallback:Bool=true,sceneThreshold:Double=0.30,nativeNV12Output:Bool=false) throws {
  guard width>0,height>0,width<=4096,height<=4096 else {throw BackendError.invalid("Unsupported dimensions")}
  self.width=width;self.height=height;self.autoFallback=autoFallback;self.sceneThreshold=sceneThreshold;self.nativeNV12Output=nativeNV12Output
  interpolator=try RifeInterpolator(configuration:.bundled(qualityTier:tier))
  stream=try interpolator.makeStream(width:width,height:height)
  timeline=try Timeline(fps:fps)
 }
 public func reset(){stream.reset();timeline.reset();previous=nil;bad=0;pushes=0;fallback=false}
 public func push(_ pixels:CVPixelBuffer,pts:CMTime) throws -> [VideoFrame] {
  guard pts.isNumeric,CVPixelBufferGetWidth(pixels)==width,CVPixelBufferGetHeight(pixels)==height,[kCVPixelFormatType_32BGRA,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].contains(CVPixelBufferGetPixelFormatType(pixels)) else {throw BackendError.invalid("Expected fixed-size BGRA8 or BT.709 centered NV12 and numeric PTS")}
  guard let (prev,prevPTS)=previous else {
   _=try stream.push(pixels,timesteps:[]);previous=(pixels,pts);return []
  }
  guard CVPixelBufferGetPixelFormatType(prev)==CVPixelBufferGetPixelFormatType(pixels) else {throw BackendError.invalid("Reset stream before changing input format")}
  let schedule=try timeline.between(prevPTS,pts)
  let difference=Self.meanDifference(prev,pixels)
  let cut=difference>sceneThreshold || schedule.count>4, duplicate=difference<0.0005
  if cut {sceneCuts+=1};if duplicate {duplicates+=1}
  if fallback {
   previous=(pixels,pts)
   return [VideoFrame(pixels:prev,pts:prevPTS,synthesized:false)]
  }
  let times=schedule.filter{$0.fraction>0.000001}.map(\.fraction)
  let start=ProcessInfo.processInfo.systemUptime
  var outputs:[CVPixelBuffer]=[]
  if cut || duplicate {
   stream.reset();_=try stream.push(pixels,timesteps:[])
  } else { outputs=try stream.push(pixels,timesteps:times,outputNV12:nativeNV12Output && CVPixelBufferGetPixelFormatType(pixels)==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) }
  let ms=(ProcessInfo.processInfo.systemUptime-start)*1000
  if !times.isEmpty && !cut && !duplicate {
   inferenceCount+=1;inferenceTotalMilliseconds+=ms
   if inferenceMilliseconds.count==4096 {inferenceMilliseconds.removeFirst()}
   inferenceMilliseconds.append(ms)
  }
  pushes+=1
  let budget=CMTimeGetSeconds(CMTimeSubtract(pts,prevPTS))*1000
  if autoFallback && pushes>3 {bad=ms>budget*1.1 ? bad+1 : max(0,bad-1);if bad>=3 {fallback=true}}
  var i=0
  let result=schedule.map { t -> VideoFrame in
   if t.fraction<=0.000001 || cut || duplicate {return VideoFrame(pixels:prev,pts:t.pts,synthesized:false)}
   let out=outputs[i];i+=1
   CVBufferPropagateAttachments(prev,out)
   return VideoFrame(pixels:out,pts:t.pts,synthesized:true)
  }
  previous=(pixels,pts)
  return result
 }
 /// Tail policy: hold final frame to declared end time; never infer beyond EOF.
 public func finish(end:CMTime) throws -> [VideoFrame] {
  guard let (prev,pts)=previous else{return []}
  defer {previous=nil;stream.reset()}
  guard CMTimeCompare(end,pts)>0 else{return []}
  if fallback {return [VideoFrame(pixels:prev,pts:pts,synthesized:false)]}
  return try timeline.between(pts,end).map{VideoFrame(pixels:prev,pts:$0.pts,synthesized:false)}
 }
 // Sparse CPU read (32x18 samples), explicitly not a full-frame copy or learned cut detector.
 private static func meanDifference(_ a:CVPixelBuffer,_ b:CVPixelBuffer)->Double {
  guard CVPixelBufferLockBaseAddress(a,.readOnly)==kCVReturnSuccess else{return 1}
  defer{CVPixelBufferUnlockBaseAddress(a,.readOnly)}
  guard CVPixelBufferLockBaseAddress(b,.readOnly)==kCVReturnSuccess else{return 1}
  defer{CVPixelBufferUnlockBaseAddress(b,.readOnly)}
  let planar=CVPixelBufferIsPlanar(a)
  guard let ap=(planar ? CVPixelBufferGetBaseAddressOfPlane(a,0) : CVPixelBufferGetBaseAddress(a))?.assumingMemoryBound(to:UInt8.self),
        let bp=(planar ? CVPixelBufferGetBaseAddressOfPlane(b,0) : CVPixelBufferGetBaseAddress(b))?.assumingMemoryBound(to:UInt8.self) else{return 1}
  let w=CVPixelBufferGetWidth(a),h=CVPixelBufferGetHeight(a)
  let sa=planar ? CVPixelBufferGetBytesPerRowOfPlane(a,0) : CVPixelBufferGetBytesPerRow(a)
  let sb=planar ? CVPixelBufferGetBytesPerRowOfPlane(b,0) : CVPixelBufferGetBytesPerRow(b)
  let auv=planar ? CVPixelBufferGetBaseAddressOfPlane(a,1)?.assumingMemoryBound(to:UInt8.self) : nil
  let buv=planar ? CVPixelBufferGetBaseAddressOfPlane(b,1)?.assumingMemoryBound(to:UInt8.self) : nil
  if planar && (auv == nil || buv == nil) {return 1}
  let sua=planar ? CVPixelBufferGetBytesPerRowOfPlane(a,1) : 0
  let sub=planar ? CVPixelBufferGetBytesPerRowOfPlane(b,1) : 0
  var total=0.0,count=0
  for y in stride(from:0,to:h,by:max(1,h/18)) {
   for x in stride(from:0,to:w,by:max(1,w/32)) {
    if let auv, let buv {
     total+=Double(abs(Int(ap[y*sa+x])-Int(bp[y*sb+x])))/219
     // Chroma participates too: equal luma does not imply a duplicate frame.
     for c in 0..<2 {
      total+=Double(abs(Int(auv[(y/2)*sua+(x/2)*2+c])-Int(buv[(y/2)*sub+(x/2)*2+c])))/224
     }
    } else {
     for c in 0..<3 {total+=Double(abs(Int(ap[y*sa+x*4+c])-Int(bp[y*sb+x*4+c])))/255}
    }
    count+=3
   }
  }
  return total/Double(count)
 }
}
