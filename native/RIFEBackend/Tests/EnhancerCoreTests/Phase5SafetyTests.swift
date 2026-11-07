import XCTest
import CoreVideo
import Metal
import RifeMetal
@testable import RifeMetalCore
@testable import EnhancerCore

final class Phase5SafetyTests: XCTestCase {
    private func frame(_ format: OSType, width: Int = 68, height: Int = 38, offset: Int = 0) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, format, attrs as CFDictionary, &result), kCVReturnSuccess)
        let pixels = try XCTUnwrap(result)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixels, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        if CVPixelBufferIsPlanar(pixels) {
            CVBufferSetAttachment(pixels,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
            CVBufferSetAttachment(pixels,kCVImageBufferChromaLocationTopFieldKey,kCVImageBufferChromaLocation_Center,.shouldPropagate)
            CVBufferSetAttachment(pixels,kCVImageBufferChromaLocationBottomFieldKey,kCVImageBufferChromaLocation_Center,.shouldPropagate)
            for plane in 0..<2 {
                let base = CVPixelBufferGetBaseAddressOfPlane(pixels, plane)!.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, plane)
                let rows = CVPixelBufferGetHeightOfPlane(pixels, plane)
                for y in 0..<rows { for x in 0..<stride { base[y*stride+x] = UInt8((x*3+y*7+offset+plane*31)%220+16) } }
            }
        } else {
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<height { for x in 0..<stride { base[y*stride+x] = UInt8((x*3+y*7+offset)%256) } }
        }
        return pixels
    }
    private func referenceSignature(_ pixels: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let planar = CVPixelBufferIsPlanar(pixels)
        let base = (planar ? CVPixelBufferGetBaseAddressOfPlane(pixels,0) : CVPixelBufferGetBaseAddress(pixels))!.assumingMemoryBound(to: UInt8.self)
        let uv = planar ? CVPixelBufferGetBaseAddressOfPlane(pixels,1)!.assumingMemoryBound(to: UInt8.self) : nil
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        let sy = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixels,0) : CVPixelBufferGetBytesPerRow(pixels)
        let suv = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixels,1) : 0
        var values: [UInt8] = []
        for y in stride(from:0,to:h,by:max(1,h/18)) { for x in stride(from:0,to:w,by:max(1,w/32)) {
            if let uv { values += [base[y*sy+x],uv[y/2*suv+x/2*2],uv[y/2*suv+x/2*2+1]] }
            else { for c in 0..<3 { values.append(base[y*sy+x*4+c]) } }
        } }
        return values
    }
    func testSignatureMatchesPreviousSamplingAndWeighting() throws {
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,kCVPixelFormatType_32BGRA] {
            let a = try frame(format), b = try frame(format,offset:39)
            let sa = referenceSignature(a), sb = referenceSignature(b)
            XCTAssertEqual(FrameProcessor.signature(a),sa)
            XCTAssertEqual(FrameProcessor.signature(b),sb)
            let planar = CVPixelBufferIsPlanar(a)
            let reference = sa.indices.reduce(0.0) { $0 + Double(abs(Int(sa[$1])-Int(sb[$1])))/(planar ? ($1%3==0 ? 219 : 224) : 255) } / Double(sa.count)
            XCTAssertEqual(FrameProcessor.meanDifference(sa,sb,planar:planar),reference,accuracy:1e-12)
        }
        XCTAssertEqual(FrameProcessor.meanDifference(nil,[],planar:true),1)
    }
    func testTimestepCacheTrimPreservesBorrowedBuffers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let pool = try BufferPool(device:device,paddedW:64,paddedH:64,internalWidth:32,internalHeight:32,internalScale:0.5)
        let borrowed = try pool.timestepBuffer(0.5)
        let original = borrowed.contents().load(as: UInt16.self)
        pool.releaseCachedTimesteps()
        let replacement = try pool.timestepBuffer(0.5)
        XCTAssertFalse(borrowed === replacement)
        XCTAssertEqual(borrowed.contents().load(as: UInt16.self), original)
        XCTAssertEqual(replacement.contents().load(as: UInt16.self), original)
        XCTAssertTrue(replacement === (try pool.timestepBuffer(0.5)))
        pool.releaseCachedTimesteps()
        pool.releaseCachedTimesteps() // repeated reset/EOF is harmless
    }
    func testTimestepCacheRetainsImmutableEvictedBuffers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let pool = try BufferPool(device:device,paddedW:64,paddedH:64,internalWidth:32,internalHeight:32,internalScale:0.5)
        let initial = try pool.timestepBuffer(0.5)
        XCTAssertTrue(initial === (try pool.timestepBuffer(Float(0.5).nextUp)))
        for t in 1...16 { _ = try pool.timestepBuffer(Float(t)/20) }
        let words = initial.contents().assumingMemoryBound(to:UInt16.self)
        for i in 0..<1024 { XCTAssertEqual(words[i],HalfPrecision.floatToBits(0.5)) }
        let current = try pool.timestepBuffer(0.4)
        XCTAssertTrue(current === (try pool.timestepBuffer(0.4)))
    }
    private func bytes(_ pixels: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixels,.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels,.readOnly) }
        var result: [UInt8] = []
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(pixels,plane)!.assumingMemoryBound(to:UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels,plane)
            let width = CVPixelBufferGetWidth(pixels), rows = CVPixelBufferGetHeightOfPlane(pixels,plane)
            for row in 0..<rows { result.append(contentsOf:UnsafeBufferPointer(start:base+row*stride,count:width)) }
        }
        return result
    }
    func testBatchedTimestepsMatchSerialOutputs() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let interpolator = try RifeInterpolator(configuration:.bundled(qualityTier:.fast))
        let stream = try interpolator.makeStream(width:256,height:128)
        let a = try frame(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,width:256,height:128)
        let b = try frame(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,width:256,height:128,offset:15)
        _ = try stream.push(a,timesteps:[])
        let batch = try stream.push(b,timesteps:[0.4,0.8],outputNV12:true).map(bytes)
        XCTAssertEqual(batch.count,2)
        for (i,t) in [Float(0.4),0.8].enumerated() {
            stream.reset();_ = try stream.push(a,timesteps:[])
            let serial = try stream.push(b,timesteps:[t],outputNV12:true)
            let reference = bytes(try XCTUnwrap(serial.first))
            XCTAssertEqual(batch[i].count,reference.count)
            let maximumDifference = zip(batch[i],reference).map{abs(Int($0)-Int($1))}.max() ?? 0
            XCTAssertLessThanOrEqual(maximumDifference,1,"t=\(t) batch/serial mismatch")
        }
    }
}
