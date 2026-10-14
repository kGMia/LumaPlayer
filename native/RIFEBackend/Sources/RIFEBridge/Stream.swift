import Foundation
import CoreVideo
import CoreMedia
import RifeMetal
import EnhancerCore

private final class StreamSession {
 let processor:FrameProcessor
 var pending:[VideoFrame]=[]
 init(_ w:Int32,_ h:Int32,_ fps:Int32,_ tier:Int32,_ fallback:Bool)throws {
  processor=try FrameProcessor(width:Int(w),height:Int(h),fps:fps,tier:[.fast,.balanced,.hq][Int(tier)],autoFallback:fallback,nativeNV12Output:true)
 }
}
private func session(_ p:UnsafeMutableRawPointer)->StreamSession {Unmanaged<StreamSession>.fromOpaque(p).takeUnretainedValue()}
@_cdecl("iive_stream_create") public func streamCreate(_ w:Int32,_ h:Int32,_ fps:Int32,_ tier:Int32,_ fallback:Int32)->UnsafeMutableRawPointer? {
 guard (0...2).contains(tier) else{return nil}
 do{return Unmanaged.passRetained(try StreamSession(w,h,fps,tier,fallback != 0)).toOpaque()}catch{return nil}
}
@_cdecl("iive_stream_destroy") public func streamDestroy(_ p:UnsafeMutableRawPointer?) {if let p{Unmanaged<StreamSession>.fromOpaque(p).release()}}
@_cdecl("iive_stream_reset") public func streamReset(_ p:UnsafeMutableRawPointer?) {if let p{let s=session(p);s.pending=[];s.processor.reset()}}
@_cdecl("iive_stream_push") public func streamPush(_ p:UnsafeMutableRawPointer?,_ pixels:UnsafeRawPointer?,_ pts:Double)->Int32 {
 guard let p,let pixels,pts.isFinite else{return -1}
 let s=session(p);guard s.pending.isEmpty else{return -1}
 let buffer=Unmanaged<CVPixelBuffer>.fromOpaque(pixels).takeUnretainedValue()
 return autoreleasepool {
  do{s.pending=try s.processor.push(buffer,pts:CMTime(seconds:pts,preferredTimescale:1_000_000_000));return Int32(s.pending.count)}catch{return -1}
 }
}
@_cdecl("iive_stream_finish") public func streamFinish(_ p:UnsafeMutableRawPointer?,_ end:Double)->Int32 {
 guard let p,end.isFinite else{return -1};let s=session(p)
 guard s.pending.isEmpty else{return -1}
 do{s.pending=try s.processor.finish(end:CMTime(seconds:end,preferredTimescale:1_000_000_000));return Int32(s.pending.count)}catch{return -1}
}
@_cdecl("iive_stream_pop") public func streamPop(_ p:UnsafeMutableRawPointer?,_ pts:UnsafeMutablePointer<Double>?,_ synthesized:UnsafeMutablePointer<Int32>?)->UnsafeMutableRawPointer? {
 guard let p,let pts,let synthesized else{return nil};let s=session(p)
 guard !s.pending.isEmpty else{return nil}
 let frame=s.pending.removeFirst();pts.pointee=CMTimeGetSeconds(frame.pts);synthesized.pointee=frame.synthesized ? 1 : 0
 return Unmanaged.passRetained(frame.pixels).toOpaque()
}
@_cdecl("iive_stream_fallback") public func streamFallback(_ p:UnsafeMutableRawPointer?)->Int32 {guard let p else{return 1};return session(p).processor.fallback ? 1 : 0}
