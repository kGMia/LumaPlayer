import Foundation
import CoreVideo
import CoreMedia
import RifeMetal

public struct VideoFrame { public let pixels:CVPixelBuffer; public let pts:CMTime; public let synthesized:Bool }
public final class FrameProcessor {
 private let modelURL:URL
 private var interpolator:RifeInterpolator
 private let width:Int, height:Int
 private var stream:RifeStream
 private var qualityTier:RifeQualityTier
 private var preparation:TierPreparation?
 public var isPreparingTier:Bool { preparation != nil }
 private var timeline:Timeline
 private var previous:(CVPixelBuffer,CMTime)?
 private var previousSignature:[UInt8]?
 private var needsPrerollRebase=false
 public private(set) var inferenceMilliseconds:[Double]=[]
 public private(set) var lastTiming:(gpuSpanMS:Double,cpuWaitMS:Double)?
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
 public let initialPreparationMilliseconds:[Double]
 public let initialCompilationCacheHit:Bool
 public init(width:Int,height:Int,fps:Int32,tier:RifeQualityTier,autoFallback:Bool=true,sceneThreshold:Double=0.30,nativeNV12Output:Bool=false,modelURL:URL=RifeConfiguration.bundledModelURL,checkCancellation:() throws -> Void = {}) throws {
  try checkCancellation()
  guard width>0,height>0,width<=4096,height<=4096 else {throw BackendError.invalid("Unsupported dimensions")}
  self.modelURL=modelURL
  self.width=width;self.height=height;self.autoFallback=autoFallback;self.sceneThreshold=sceneThreshold;self.nativeNV12Output=nativeNV12Output;self.qualityTier=tier
  timeline=try Timeline(fps:fps)
  interpolator=try RifeInterpolator(configuration:RifeConfiguration(modelURL:modelURL,qualityTier:tier))
  try checkCancellation()
  stream=try interpolator.makeStream(width:width,height:height,checkCancellation:checkCancellation)
  initialPreparationMilliseconds=interpolator.preparationMilliseconds
  initialCompilationCacheHit=interpolator.compilationCacheHit
 }
 deinit { preparation?.cancel() }
 public func reset(){lastTiming=nil;preparation?.cancel();preparation=nil;stream.reset(releasingUnusedResources:true);timeline.reset();previous=nil;previousSignature=nil;needsPrerollRebase=false;bad=0;pushes=0;fallback=false}
 /// Serial caller only. Prepare and seed before replacing the old stream;
 /// retain the output clock and pending source frame across a quality change.
 public func setQualityTier(_ tier:RifeQualityTier) throws {
  preparation?.cancel();preparation=nil
  let nextInterpolator=try RifeInterpolator(configuration:RifeConfiguration(modelURL:modelURL,qualityTier:tier))
  let nextStream=try nextInterpolator.makeStream(width:width,height:height)
  if let (pixels,_)=previous { _=try nextStream.push(pixels,timesteps:[]) }
  stream=nextStream;interpolator=nextInterpolator;qualityTier=tier
  bad=0;pushes=0;fallback=false
 }
 /// Serial playback caller. Poll once per source frame until true. While false,
 /// push() returns source holds on the existing output clock, never AI claims.
 public func requestQualityTier(_ tier:RifeQualityTier) throws -> Bool {
  if tier==qualityTier {
   // A request back to the old tier must rebase its dormant encoder first.
   if preparation != nil,let (pixels,_)=previous { _=try stream.push(pixels,timesteps:[]) }
   preparation?.cancel();preparation=nil;return true
  }
  if let preparation,preparation.tier != tier { preparation.cancel();self.preparation=nil }
  if preparation == nil {
   guard let (pixels,_)=previous else {try setQualityTier(tier);return true}
   preparation=TierPreparation(tier:tier,modelURL:modelURL,source:pixels,outputNV12:nativeNV12Output && CVPixelBufferGetPixelFormatType(pixels)==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
   return false
  }
  guard let preparation else {return false}
  if let result=preparation.takeResult() {
   defer {self.preparation=nil}
   let (model,nextStream)=try result.get()
   if let (pixels,_)=previous { _=try nextStream.push(pixels,timesteps:[]) }
   stream=nextStream;interpolator=model;qualityTier=tier
   bad=0;pushes=0;fallback=false
   return true
  }
  if ProcessInfo.processInfo.systemUptime-preparation.started>30 {
   preparation.cancel();self.preparation=nil
   throw BackendError.invalid("RIFE tier preparation timed out")
  }
  return false
 }
 public func push(_ pixels:CVPixelBuffer,pts:CMTime,preroll:Bool=false) throws -> [VideoFrame] {
  lastTiming=nil
  guard pts.isNumeric,CVPixelBufferGetWidth(pixels)==width,CVPixelBufferGetHeight(pixels)==height,[kCVPixelFormatType_32BGRA,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].contains(CVPixelBufferGetPixelFormatType(pixels)) else {throw BackendError.invalid("Expected fixed-size BGRA8 or BT.709 centered NV12 and numeric PTS")}
  guard let (prev,prevPTS)=previous else {
   if preroll { needsPrerollRebase=true }
   else { _=try stream.push(pixels,timesteps:[]);previousSignature=Self.signature(pixels) }
   previous=(pixels,pts);return []
  }
  guard CVPixelBufferGetPixelFormatType(prev)==CVPixelBufferGetPixelFormatType(pixels) else {throw BackendError.invalid("Reset stream before changing input format")}
  let schedule=try timeline.between(prevPTS,pts)
  // Exact backsteps decode the full GOP. Advance the same output clock, but
  // don't run inference on intervals guaranteed to be discarded by mpv.
  if preroll && !fallback && preparation == nil {
   needsPrerollRebase=true;previous=(pixels,pts);previousSignature=nil
   return schedule.map {VideoFrame(pixels:prev,pts:$0.pts,synthesized:false)}
  }
  if needsPrerollRebase {
   stream.reset();_=try stream.push(prev,timesteps:[])
   previousSignature=Self.signature(prev);needsPrerollRebase=false
  }
  if preparation != nil {
   previous=(pixels,pts);previousSignature=Self.signature(pixels)
   return schedule.map {VideoFrame(pixels:prev,pts:$0.pts,synthesized:false)}
  }
  if fallback {
   previous=(pixels,pts);previousSignature=nil
   return [VideoFrame(pixels:prev,pts:prevPTS,synthesized:false)]
  }
  let signature=Self.signature(pixels)
  let difference=Self.meanDifference(previousSignature,signature,planar:CVPixelBufferIsPlanar(pixels))
  let cut=difference>sceneThreshold || schedule.count>4, duplicate=difference<0.0005
  if cut {sceneCuts+=1};if duplicate {duplicates+=1}
  let times=schedule.filter{$0.fraction>0.000001}.map(\.fraction)
  let start=ProcessInfo.processInfo.systemUptime
  var outputs:[CVPixelBuffer]=[]
  if cut || duplicate {
   stream.reset();_=try stream.push(pixels,timesteps:[])
  } else { outputs=try stream.push(pixels,timesteps:times,outputNV12:nativeNV12Output && CVPixelBufferGetPixelFormatType(pixels)==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) }
  let ms=(ProcessInfo.processInfo.systemUptime-start)*1000
  if !times.isEmpty && !cut && !duplicate {
   lastTiming=stream.lastTiming
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
  previous=(pixels,pts);previousSignature=signature
  return result
 }
 /// Tail policy: hold final frame to declared end time; never infer beyond EOF.
 public func finish(end:CMTime) throws -> [VideoFrame] {
  lastTiming=nil
  guard let (prev,pts)=previous else{return []}
  defer {preparation?.cancel();preparation=nil;previous=nil;previousSignature=nil;needsPrerollRebase=false;stream.reset(releasingUnusedResources:true)}
  guard CMTimeCompare(end,pts)>0 else{return []}
  if fallback {return [VideoFrame(pixels:prev,pts:pts,synthesized:false)]}
  return try timeline.between(pts,end).map{VideoFrame(pixels:prev,pts:$0.pts,synthesized:false)}
 }
 // Cache one sparse signature per source frame. Adjacent pairs reuse the previous
 // signature rather than locking and reading the same GPU-backed surface twice.
 static func signature(_ pixels:CVPixelBuffer)->[UInt8]? {
  guard CVPixelBufferLockBaseAddress(pixels,.readOnly)==kCVReturnSuccess else{return nil}
  defer{CVPixelBufferUnlockBaseAddress(pixels,.readOnly)}
  let planar=CVPixelBufferIsPlanar(pixels)
  guard let base=(planar ? CVPixelBufferGetBaseAddressOfPlane(pixels,0) : CVPixelBufferGetBaseAddress(pixels))?.assumingMemoryBound(to:UInt8.self) else{return nil}
  let uv=planar ? CVPixelBufferGetBaseAddressOfPlane(pixels,1)?.assumingMemoryBound(to:UInt8.self) : nil
  if planar && uv == nil {return nil}
  let w=CVPixelBufferGetWidth(pixels),h=CVPixelBufferGetHeight(pixels)
  let strideY=planar ? CVPixelBufferGetBytesPerRowOfPlane(pixels,0) : CVPixelBufferGetBytesPerRow(pixels)
  let strideUV=planar ? CVPixelBufferGetBytesPerRowOfPlane(pixels,1) : 0
  let stepX=max(1,w/32),stepY=max(1,h/18)
  let columns=(w+stepX-1)/stepX,rows=(h+stepY-1)/stepY
  return Array(unsafeUninitializedCapacity:columns*rows*3) { result,count in
   var index=0
   for y in stride(from:0,to:h,by:stepY) {
    let row=base+y*strideY
    let uvRow=uv.map{$0+(y/2)*strideUV}
    for x in stride(from:0,to:w,by:stepX) {
     if let uvRow {
      result[index]=row[x]
      result[index+1]=uvRow[(x/2)*2]
      result[index+2]=uvRow[(x/2)*2+1]
     } else {
      result[index]=row[x*4]
      result[index+1]=row[x*4+1]
      result[index+2]=row[x*4+2]
     }
     index+=3
    }
   }
   count=index
  }
 }
 static func meanDifference(_ a:[UInt8]?,_ b:[UInt8]?,planar:Bool)->Double {
  guard let a,let b,!a.isEmpty,a.count==b.count else{return 1}
  guard a.count%3==0 else{return 1}
  // Sum exactly in integer space; normalize once per channel group. Preserve
  // the old NV12 (Y/219, U,V/224) and BGRA (B,G,R/255) weighting.
  var first=0,other=0
  for i in stride(from:0,to:a.count,by:3) {
   first+=abs(Int(a[i])-Int(b[i]))
   other+=abs(Int(a[i+1])-Int(b[i+1]))+abs(Int(a[i+2])-Int(b[i+2]))
  }
  return (Double(first)/(planar ? 219 : 255)+Double(other)/(planar ? 224 : 255))/Double(a.count)
 }
}
