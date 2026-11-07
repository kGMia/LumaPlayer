import Foundation
import CoreVideo
import RifeMetal
// C ABI for a future separately built mpv/VapourSynth adapter. Not loaded by IINA.
// Each handle is single-threaded. Input is borrowed; output has +1 ownership.
private final class Session {let model:RifeInterpolator;init(_ tier:RifeQualityTier)throws{model=try RifeInterpolator(configuration:.bundled(qualityTier:tier))}}
@c(iive_rife_create) public func create(_ tier:Int32)->UnsafeMutableRawPointer? {
 guard (0...2).contains(tier) else{return nil}
 do{return Unmanaged.passRetained(try Session([.fast,.balanced,.hq][Int(tier)])).toOpaque()}catch{return nil}
}
@c(iive_rife_destroy) public func destroy(_ handle:UnsafeMutableRawPointer?) {if let handle{Unmanaged<Session>.fromOpaque(handle).release()}}
@c(iive_rife_interpolate) public func interpolate(_ handle:UnsafeMutableRawPointer?,_ previous:UnsafeRawPointer?,_ current:UnsafeRawPointer?,_ t:Float)->UnsafeMutableRawPointer? {
 guard let handle,let previous,let current,t>0,t<1 else{return nil}
 let s=Unmanaged<Session>.fromOpaque(handle).takeUnretainedValue()
 let a=Unmanaged<CVPixelBuffer>.fromOpaque(previous).takeUnretainedValue(),b=Unmanaged<CVPixelBuffer>.fromOpaque(current).takeUnretainedValue()
 // Only BGRA accepted here; upstream padded RGBA paths are not validated.
 guard CVPixelBufferGetPixelFormatType(a)==kCVPixelFormatType_32BGRA,CVPixelBufferGetPixelFormatType(b)==kCVPixelFormatType_32BGRA else{return nil}
 do{return Unmanaged.passRetained(try s.model.interpolate(previous:a,current:b,timesteps:[t])[0]).toOpaque()}catch{return nil}
}
@c(iive_rife_release_frame) public func releaseFrame(_ pixels:UnsafeMutableRawPointer?){if let pixels{Unmanaged<CVPixelBuffer>.fromOpaque(pixels).release()}}
