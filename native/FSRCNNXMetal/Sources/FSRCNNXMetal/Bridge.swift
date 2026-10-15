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
    fsrProcessChroma(handle,input,0)
}
@_cdecl("iive_fsr_process_chroma") public func fsrProcessChroma(_ handle:UnsafeMutableRawPointer?,_ input:UnsafeRawPointer?,_ left:Int32)->UnsafeMutableRawPointer? {
    fsrProcessSplit(handle,input,left,0.0)
}
@_cdecl("iive_fsr_process_split") public func fsrProcessSplit(_ handle:UnsafeMutableRawPointer?,_ input:UnsafeRawPointer?,_ left:Int32,_ splitRatio:Float)->UnsafeMutableRawPointer? {
    guard let handle,let input else{return nil}
    return autoreleasepool { do {
        let pixels=Unmanaged<CVPixelBuffer>.fromOpaque(input).takeUnretainedValue()
        return Unmanaged.passRetained(try model(handle).process(pixels,chromaLeft:left != 0,splitRatio:splitRatio)).toOpaque()
    }catch{return nil} }
}
@_cdecl("iive_fsr_destroy") public func fsrDestroy(_ handle:UnsafeMutableRawPointer?) {
    if let handle {Unmanaged<FSRCNNXModel>.fromOpaque(handle).release()}
}
