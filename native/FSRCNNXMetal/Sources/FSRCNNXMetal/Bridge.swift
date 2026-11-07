// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import Metal
private func model(_ handle:UnsafeMutableRawPointer)->FSRCNNXModel {Unmanaged<FSRCNNXModel>.fromOpaque(handle).takeUnretainedValue()}
@c(iive_fsr_create) public func fsrCreate(_ w:Int32,_ h:Int32,_ tier:Int32)->UnsafeMutableRawPointer? {
    guard let device=MTLCreateSystemDefaultDevice(),let tier=FSRCNNXTier(rawValue:Int(tier)) else{return nil}
    return autoreleasepool { do{return Unmanaged.passRetained(try FSRCNNXModel(device:device,width:Int(w),height:Int(h),tier:tier)).toOpaque()}catch{return nil} }
}
@c(iive_fsr_input) public func fsrInput(_ handle:UnsafeMutableRawPointer?)->UnsafeMutableRawPointer? {
    guard let handle else{return nil}
    do{return Unmanaged.passRetained(try model(handle).makeInput()).toOpaque()}catch{return nil}
}
@c(iive_fsr_process) public func fsrProcess(_ handle:UnsafeMutableRawPointer?,_ input:UnsafeRawPointer?)->UnsafeMutableRawPointer? {
    fsrProcessChroma(handle,input,0)
}
@c(iive_fsr_process_chroma) public func fsrProcessChroma(_ handle:UnsafeMutableRawPointer?,_ input:UnsafeRawPointer?,_ left:Int32)->UnsafeMutableRawPointer? {
    fsrProcessSplit(handle,input,left,0.0)
}
@c(iive_fsr_process_split) public func fsrProcessSplit(_ handle:UnsafeMutableRawPointer?,_ input:UnsafeRawPointer?,_ left:Int32,_ splitRatio:Float)->UnsafeMutableRawPointer? {
    guard let handle,let input else{return nil}
    return autoreleasepool { do {
        let pixels=Unmanaged<CVPixelBuffer>.fromOpaque(input).takeUnretainedValue()
        return Unmanaged.passRetained(try model(handle).process(pixels,chromaLeft:left != 0,splitRatio:splitRatio)).toOpaque()
    }catch{return nil} }
}
@c(iive_fsr_destroy) public func fsrDestroy(_ handle:UnsafeMutableRawPointer?) {
    if let handle {Unmanaged<FSRCNNXModel>.fromOpaque(handle).release()}
}

@c(iive_fsr_trim) public func fsrTrim(_ handle:UnsafeMutableRawPointer?) {
    if let handle { autoreleasepool { model(handle).releaseUnusedResources() } }
}

// Snapshot only; never waits for the GPU. Same serial-caller contract as process/push.
@c(iive_fsr_timing) public func iive_fsr_timing(_ handle:UnsafeMutableRawPointer?,_ gpuSpan:UnsafeMutablePointer<Double>?,_ cpuWait:UnsafeMutablePointer<Double>?)->Int32 {
    guard let gpuSpan,let cpuWait else {return 0}
    gpuSpan.pointee = -1;cpuWait.pointee = -1
    guard let handle,let timing=model(handle).lastTiming else {return 0}
    gpuSpan.pointee=timing.gpuSpanMS;cpuWait.pointee=timing.cpuWaitMS
    return 1
}
