// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import Metal
private func model(_ handle:UnsafeMutableRawPointer)->FSRCNNXModel {Unmanaged<FSRCNNXModel>.fromOpaque(handle).takeUnretainedValue()}
@_cdecl("iive_fsr_create") public func fsrCreate(_ w:Int32,_ h:Int32,_ tier:Int32)->UnsafeMutableRawPointer? {
    guard let device=MTLCreateSystemDefaultDevice(),let tier=FSRCNNXTier(rawValue:Int(tier)) else{return nil}
    return autoreleasepool { do{return Unmanaged.passRetained(try FSRCNNXModel(device:device,width:Int(w),height:Int(h),tier:tier)).toOpaque()}catch{return nil} }
}
@_cdecl("iive_fsr_input") public func fsrInput(_ handle:UnsafeMutableRawPointer?)->UnsafeMutableRawPointer? {
    guard let handle else{return nil}
    do{return Unmanaged.passRetained(try model(handle).makeInput()).toOpaque()}catch{return nil}
}
@_cdecl("iive_fsr_process") public func fsrProcess(_ handle:UnsafeMutableRawPointer?,_ input:UnsafeRawPointer?)->UnsafeMutableRawPointer? {
    guard let handle,let input else{return nil}
    return autoreleasepool { do {
        let pixels=Unmanaged<CVPixelBuffer>.fromOpaque(input).takeUnretainedValue()
        return Unmanaged.passRetained(try model(handle).process(pixels)).toOpaque()
    }catch{return nil} }
}
@_cdecl("iive_fsr_destroy") public func fsrDestroy(_ handle:UnsafeMutableRawPointer?) {
    if let handle {Unmanaged<FSRCNNXModel>.fromOpaque(handle).release()}
}
