import Foundation
@preconcurrency import AVFoundation
import CoreVideo
import CoreMedia
import CryptoKit
import Metal
import RifeMetal
import EnhancerCore

private struct DecodedFrame {let pixels:CVPixelBuffer;let pts:CMTime}

/// Separate readers per pass; at most one endpoint, a reference, a next frame
/// and the current model outputs are retained. Never loads a movie into RAM.
private final class EvaluationReader {
 let asset:AVURLAsset,reader:AVAssetReader,output:AVAssetReaderTrackOutput
 let width:Int,height:Int,fps:Float
 let start:Double
 private init(asset:AVURLAsset,track:AVAssetTrack,width:Int,height:Int,fps:Float,start:Double)throws {
  self.asset=asset;self.width=width;self.height=height;self.fps=fps;self.start=start
  reader=try AVAssetReader(asset:asset)
  output=AVAssetReaderTrackOutput(track:track,outputSettings:[
   kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
   kCVPixelBufferMetalCompatibilityKey as String:true,
   kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
  output.alwaysCopiesSampleData=false
  guard reader.canAdd(output) else{throw BackendError.invalid("Cannot decode this track to BGRA")}
  reader.add(output)
  reader.timeRange=CMTimeRange(start:CMTime(seconds:start,preferredTimescale:60000),duration:.positiveInfinity)
  guard reader.startReading() else{throw reader.error ?? BackendError.invalid("Reader start failed")}
 }
 static func open(_ input:URL,start:Double) async throws -> EvaluationReader {
  let asset=AVURLAsset(url:input)
  guard let track=try await asset.loadTracks(withMediaType:.video).first else{throw BackendError.invalid("No video track")}
  guard try await track.load(.preferredTransform) == .identity else{throw BackendError.invalid("Rotate/normalize test inputs explicitly first")}
  guard let format=try await track.load(.formatDescriptions).first else{throw BackendError.invalid("Missing format")}
  let ext=(CMFormatDescriptionGetExtensions(format) as NSDictionary?) ?? [:]
  guard ext[kCMFormatDescriptionExtension_TransferFunction] as? String == kCVImageBufferTransferFunction_ITU_R_709_2 as String,
        ext[kCMFormatDescriptionExtension_ColorPrimaries] as? String == kCVImageBufferColorPrimaries_ITU_R_709_2 as String else {
   throw BackendError.invalid("Evaluation requires explicitly tagged SDR BT.709; HDR/unknown color rejected")
  }
  let size=CMVideoFormatDescriptionGetDimensions(format),fps=try await track.load(.nominalFrameRate)
  guard size.width>0,size.height>0,size.width<=4096,size.height<=4096,fps.isFinite,fps>0 else{throw BackendError.invalid("Unsupported dimensions/FPS")}
  return try EvaluationReader(asset:asset,track:track,width:Int(size.width),height:Int(size.height),fps:fps,start:start)
 }
 func next()throws->DecodedFrame? {
  while let sample=output.copyNextSampleBuffer() {
   let pts=CMSampleBufferGetPresentationTimeStamp(sample)
   guard pts.isNumeric else{throw BackendError.invalid("Invalid decoded PTS")}
   if CMTimeGetSeconds(pts)<start {continue}
   guard let image=CMSampleBufferGetImageBuffer(sample),
         CVPixelBufferGetPixelFormatType(image)==kCVPixelFormatType_32BGRA,
         CVPixelBufferGetWidth(image)==width,CVPixelBufferGetHeight(image)==height else{throw BackendError.invalid("Decoded format changed")}
   return DecodedFrame(pixels:image,pts:pts)
  }
  if reader.status == .failed {throw reader.error ?? BackendError.invalid("Decode failed")}
  return nil
 }
 deinit {reader.cancelReading()}
}

private func compare(reference:CVPixelBuffer,prediction:CVPixelBuffer,previous:CVPixelBuffer,next:CVPixelBuffer,fraction:Double)throws->RGBComparison {
 let pixels=[reference,prediction,previous,next]
 let width=CVPixelBufferGetWidth(reference),height=CVPixelBufferGetHeight(reference)
 var locked:[CVPixelBuffer]=[]
 defer{for buffer in locked.reversed(){CVPixelBufferUnlockBaseAddress(buffer,.readOnly)}}
 var planes:[(UnsafePointer<UInt8>,Int)]=[]
 for buffer in pixels {
  guard CVPixelBufferGetPixelFormatType(buffer)==kCVPixelFormatType_32BGRA,
        CVPixelBufferGetWidth(buffer)==width,CVPixelBufferGetHeight(buffer)==height,
        CVPixelBufferLockBaseAddress(buffer,.readOnly)==kCVReturnSuccess else{throw BackendError.invalid("Comparison pixel layout/lock failed")}
  locked.append(buffer)
  guard let pointer=CVPixelBufferGetBaseAddress(buffer) else{throw BackendError.invalid("Missing comparison pixels")}
  planes.append((UnsafePointer(pointer.assumingMemoryBound(to:UInt8.self)),CVPixelBufferGetBytesPerRow(buffer)))
 }
 var result=RGBComparison()
 for y in 0..<height {for x in 0..<width {for c in 0..<3 {
  let offset=x*4+c
  result.add(reference:planes[0].0[y*planes[0].1+offset],predicted:planes[1].0[y*planes[1].1+offset],
   previous:planes[2].0[y*planes[2].1+offset],next:planes[3].0[y*planes[3].1+offset],fraction:fraction)
 }}}
 return result
}
private func metrics(_ errors:RGBError)->[String:Any] {
 ["samples":errors.samples,"mse_code_values":errors.mse as Any? ?? NSNull(),
  "mae_code_values":errors.mae as Any? ?? NSNull(),"psnr_db":errors.psnr as Any? ?? NSNull(),"exact_match":errors.exactMatch]
}
private func metrics(_ comparison:RGBComparison)->[String:Any] {
 ["model":metrics(comparison.model),"nearest_frame":metrics(comparison.nearest),"temporal_blend":metrics(comparison.blend)]
}

func evaluateVideo(input:URL,tier:RifeQualityTier,modelURL:URL,start:Double,pairs:Int,targetFPS:Int32) async throws {
 guard start.isFinite,start>=0,(1...120).contains(pairs),[48,60].contains(targetFPS) else{throw BackendError.invalid("Invalid evaluation interval/count/FPS")}
 let source=try await EvaluationReader.open(input,start:start)
 guard Double(source.fps)<Double(targetFPS),var previous=try source.next() else{throw BackendError.invalid("Source must have video below target FPS at the selected start")}
 let setup=ProcessInfo.processInfo.systemUptime
 let model=try RifeInterpolator(configuration:RifeConfiguration(modelURL:modelURL,qualityTier:tier))
 let stream=try model.makeStream(width:source.width,height:source.height)
 // Warm inference on retained decoded pixels, then rebase to the real interval.
 _=try stream.push(previous.pixels,timesteps:[])
 _=try stream.push(previous.pixels,timesteps:[0.5])
 stream.reset();_=try stream.push(previous.pixels,timesteps:[])
 let setupMS=(ProcessInfo.processInfo.systemUptime-setup)*1000
 var quality=RGBComparison(),pairResults:[[String:Any]]=[]
 for _ in 0..<pairs {
  let available=try autoreleasepool { ()throws->Bool in
   guard let reference=try source.next(),let next=try source.next() else{return false}
   let span=CMTimeGetSeconds(CMTimeSubtract(next.pts,previous.pts))
   let fraction=CMTimeGetSeconds(CMTimeSubtract(reference.pts,previous.pts))/span
   guard span.isFinite,span>0,span<=1,fraction.isFinite,fraction>0,fraction<1 else{throw BackendError.invalid("Discontinuous reference timestamps")}
   let generated=try stream.push(next.pixels,timesteps:[Float(fraction)])
   guard generated.count==1 else{throw BackendError.invalid("Missing held-out prediction")}
   let comparison=try compare(reference:reference.pixels,prediction:generated[0],previous:previous.pixels,next:next.pixels,fraction:fraction)
   quality.merge(comparison)
   pairResults.append(["previous_pts":CMTimeGetSeconds(previous.pts),"reference_pts":CMTimeGetSeconds(reference.pts),
    "next_pts":CMTimeGetSeconds(next.pts),"fraction":fraction,"quality":metrics(comparison)])
   previous=next
   return true
  }
  if !available {break}
 }
 guard !pairResults.isEmpty else{throw BackendError.invalid("Need at least three decoded frames for held-out evaluation")}
 // Performance uses ADJACENT source frames at actual PTS. It is a different
 // task from every-other-frame reconstruction; scoring does not contaminate it.
 let playback=try await EvaluationReader.open(input,start:start)
 guard var prior=try playback.next() else{throw BackendError.invalid("No performance frames")}
 stream.reset();_=try stream.push(prior.pixels,timesteps:[])
 var clock=try Timeline(fps:targetFPS),times:[Double]=[],decode:[Double]=[],gpu:[Double]=[],wait:[Double]=[]
 var generatedCount=0
 for _ in 0..<pairs {
  let available=try autoreleasepool { ()throws->Bool in
   let readStart=ProcessInfo.processInfo.systemUptime
   guard let next=try playback.next() else{return false}
   decode.append((ProcessInfo.processInfo.systemUptime-readStart)*1000)
   let steps=try clock.between(prior.pts,next.pts).filter{$0.fraction>0.000001}.map(\.fraction)
   let begin=ProcessInfo.processInfo.systemUptime
   let generated=try stream.push(next.pixels,timesteps:steps)
   times.append((ProcessInfo.processInfo.systemUptime-begin)*1000)
   guard generated.count==steps.count else{throw BackendError.invalid("Unexpected interval output count")}
   generatedCount+=generated.count
   if let timing=stream.lastTiming {gpu.append(timing.gpuSpanMS);wait.append(timing.cpuWaitMS)}
   prior=next
   return true
  }
  if !available {break}
 }
 let hash=SHA256.hash(data:try Data(contentsOf:modelURL,options:.mappedIfSafe)).map{String(format:"%02x",$0)}.joined()
 try Stats.emit(["kind":"real_video_holdout_and_intervals","model":model.modelName,"model_sha256":hash,
  "device":MTLCreateSystemDefaultDevice()?.name ?? "N/A","width":source.width,"height":source.height,
  "source_fps":source.fps,"target_fps":targetFPS,"tier":tier.rawValue,"padding_multiple":model.modelPaddingMultiple,
  "requested_start_s":start,"requested_pairs":pairs,"pixel_format":"bgra","setup_and_warmup_ms":setupMS,
  "quality":["scope":"leave out every other decoded frame; reconstruct source-rate ground truth from half-rate endpoints, NOT target-FPS quality",
             "peak_code_value":255,"pairs":pairResults.count,"aggregate":metrics(quality),"per_pair":pairResults],
  "performance":["source_pairs":times.count,"generated_frames":generatedCount,"model_call":Stats.summarize(times),
                 "decode_call":Stats.summarize(decode),"gpu_span":Stats.summarize(gpu),"cpu_wait":Stats.summarize(wait)],
  "peak_rss_bytes":Stats.memory(),"player_realtime":NSNull(),"dropped_frames":NSNull(),
  "note":"AVFoundation BGRA decoding, no scene-cut/duplicate bypass, no display/audio/FSRCNNX. CPU scoring excluded from performance pass. BGRA padding/cropping differs from native player NV12 path. PSNR/MAE do not measure ghosting or perceptual quality; cuts are included. GPU span overlaps CPU wait. Short samples are not a realtime guarantee."])
}
