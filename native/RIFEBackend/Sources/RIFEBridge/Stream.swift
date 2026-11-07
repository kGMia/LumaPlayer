import Foundation
import CoreVideo
import CoreMedia
import RifeMetal
import EnhancerCore

private final class StreamSession {
 let processor:FrameProcessor
 var pending:[VideoFrame]=[]
 var lastError:Int32=0
 init(_ w:Int32,_ h:Int32,_ fps:Int32,_ tier:Int32,_ fallback:Bool,checkCancellation:() throws -> Void = {})throws {
  processor=try FrameProcessor(width:Int(w),height:Int(h),fps:fps,tier:[.fast,.balanced,.hq][Int(tier)],autoFallback:fallback,nativeNV12Output:true,checkCancellation:checkCancellation)
 }
}
private func session(_ p:UnsafeMutableRawPointer)->StreamSession {Unmanaged<StreamSession>.fromOpaque(p).takeUnretainedValue()}
@c(iive_stream_create) public func streamCreate(_ w:Int32,_ h:Int32,_ fps:Int32,_ tier:Int32,_ fallback:Int32)->UnsafeMutableRawPointer? {
 streamCreateWithError(w,h,fps,tier,fallback,nil)
}
@c(iive_stream_create_with_error) public func streamCreateWithError(_ w:Int32,_ h:Int32,_ fps:Int32,_ tier:Int32,_ fallback:Int32,_ error:UnsafeMutablePointer<Int32>?)->UnsafeMutableRawPointer? {
 streamCreateCancellable(w,h,fps,tier,fallback,nil,nil,error)
}
@c(iive_stream_create_cancellable) public func streamCreateCancellable(_ w:Int32,_ h:Int32,_ fps:Int32,_ tier:Int32,_ fallback:Int32,_ canceled:(@convention(c) (UnsafeMutableRawPointer?)->Int32)?,_ context:UnsafeMutableRawPointer?,_ error:UnsafeMutablePointer<Int32>?)->UnsafeMutableRawPointer? {
 error?.pointee=0
 guard (0...2).contains(tier) else{error?.pointee=100;return nil}
 do{return Unmanaged.passRetained(try StreamSession(w,h,fps,tier,fallback != 0) {
  if let canceled, canceled(context) != 0 {throw CancellationError()}
 }).toOpaque()}
 catch let failure {error?.pointee=StreamFailure.code(for:failure);return nil}
}
@c(iive_stream_last_error) public func streamLastError(_ p:UnsafeMutableRawPointer?)->Int32 {
 guard let p else{return 100};return session(p).lastError
}
@c(iive_stream_destroy) public func streamDestroy(_ p:UnsafeMutableRawPointer?) {if let p{Unmanaged<StreamSession>.fromOpaque(p).release()}}
@c(iive_stream_reset) public func streamReset(_ p:UnsafeMutableRawPointer?) {if let p{let s=session(p);s.pending=[];s.lastError=0;s.processor.reset()}}
@c(iive_stream_set_tier) public func streamSetTier(_ p:UnsafeMutableRawPointer?,_ tier:Int32)->Int32 {
 guard let p else{return -1}
 let s=session(p);s.lastError=0
 guard (0...2).contains(tier) else{s.lastError=100;return -1}
 guard s.pending.isEmpty else{s.lastError=101;return -1}
 return autoreleasepool {
  do {try s.processor.setQualityTier([.fast,.balanced,.hq][Int(tier)]);return 0}
  catch {s.lastError=StreamFailure.code(for:error);return -1}
 }
}
@c(iive_stream_push) public func streamPush(_ p:UnsafeMutableRawPointer?,_ pixels:UnsafeRawPointer?,_ pts:Double)->Int32 {
 return streamPushPreroll(p,pixels,pts,0)
}
@c(iive_stream_push_preroll) public func streamPushPreroll(_ p:UnsafeMutableRawPointer?,_ pixels:UnsafeRawPointer?,_ pts:Double,_ preroll:Int32)->Int32 {
 guard let p else{return -1}
 let s=session(p);s.lastError=0
 guard let pixels,pts.isFinite else{s.lastError=100;return -1}
 guard s.pending.isEmpty else{s.lastError=101;return -1}
 let buffer=Unmanaged<CVPixelBuffer>.fromOpaque(pixels).takeUnretainedValue()
 return autoreleasepool {
  do{s.pending=try s.processor.push(buffer,pts:CMTime(seconds:pts,preferredTimescale:1_000_000_000),preroll:preroll != 0);return Int32(s.pending.count)}catch{s.lastError=StreamFailure.code(for:error);return -1}
 }
}
@c(iive_stream_request_tier) public func streamRequestTier(_ p:UnsafeMutableRawPointer?,_ tier:Int32)->Int32 {
 guard let p else{return -1}
 let s=session(p);s.lastError=0
 guard (0...2).contains(tier) else{s.lastError=100;return -1}
 guard s.pending.isEmpty else{s.lastError=101;return -1}
 return autoreleasepool {
  do {return try s.processor.requestQualityTier([.fast,.balanced,.hq][Int(tier)]) ? 0 : 1}
  catch {s.lastError=StreamFailure.code(for:error);return -1}
 }
}
@c(iive_stream_finish) public func streamFinish(_ p:UnsafeMutableRawPointer?,_ end:Double)->Int32 {
 guard let p else{return -1};let s=session(p);s.lastError=0
 guard end.isFinite else{s.lastError=100;return -1}
 guard s.pending.isEmpty else{s.lastError=101;return -1}
 do{s.pending=try s.processor.finish(end:CMTime(seconds:end,preferredTimescale:1_000_000_000));return Int32(s.pending.count)}catch{s.lastError=StreamFailure.code(for:error);return -1}
}
@c(iive_stream_pop) public func streamPop(_ p:UnsafeMutableRawPointer?,_ pts:UnsafeMutablePointer<Double>?,_ synthesized:UnsafeMutablePointer<Int32>?)->UnsafeMutableRawPointer? {
 guard let p,let pts,let synthesized else{return nil};let s=session(p)
 guard !s.pending.isEmpty else{return nil}
 let frame=s.pending.removeFirst();pts.pointee=CMTimeGetSeconds(frame.pts);synthesized.pointee=frame.synthesized ? 1 : 0
 return Unmanaged.passRetained(frame.pixels).toOpaque()
}
@c(iive_stream_fallback) public func streamFallback(_ p:UnsafeMutableRawPointer?)->Int32 {guard let p else{return 1};return session(p).processor.fallback ? 1 : 0}

// Snapshot only; never waits for the GPU. Same serial-caller contract as process/push.
@c(iive_stream_compilation_cache_hit) public func streamCompilationCacheHit(_ handle:UnsafeMutableRawPointer?)->Int32 {
 guard let handle else{return -1}
 return session(handle).processor.initialCompilationCacheHit ? 1 : 0
}

@c(iive_stream_preparation_timing) public func streamPreparationTiming(_ handle:UnsafeMutableRawPointer?,_ values:UnsafeMutablePointer<Double>?,_ capacity:Int32)->Int32 {
 guard let values,capacity>=5 else{return 0}
 for i in 0..<5 {values[i] = -1}
 guard let handle else{return 0}
 let timing=session(handle).processor.initialPreparationMilliseconds
 for i in 0..<5 {values[i]=timing[i]}
 return 1
}

@c(iive_stream_timing) public func iive_stream_timing(_ handle:UnsafeMutableRawPointer?,_ gpuSpan:UnsafeMutablePointer<Double>?,_ cpuWait:UnsafeMutablePointer<Double>?)->Int32 {
    guard let gpuSpan,let cpuWait else {return 0}
    gpuSpan.pointee = -1;cpuWait.pointee = -1
    guard let handle,let timing=session(handle).processor.lastTiming else {return 0}
    gpuSpan.pointee=timing.gpuSpanMS;cpuWait.pointee=timing.cpuWaitMS
    return 1
}
