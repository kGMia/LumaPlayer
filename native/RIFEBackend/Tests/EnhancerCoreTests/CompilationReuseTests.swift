import XCTest
import CoreVideo
import Metal
import RifeMetal
@testable import RifeMetalCore

final class CompilationReuseTests: XCTestCase {
    func testExclusiveCheckoutInvalidationAndAdmission() {
        final class Item {}
        let cache = IdleCompilationCache<String, Item>()
        let item = Item(), ticket = cache.take("a").ticket
        cache.put(item,key:"a",ticket:ticket)
        XCTAssertTrue(cache.take("a").value === item)
        XCTAssertNil(cache.take("a").value)
        cache.put(item,key:"a",ticket:ticket)
        XCTAssertNil(cache.take("different-model").value)
        cache.purge()
        cache.put(item,key:"a",ticket:ticket)
        XCTAssertNil(cache.take("a").value, "Old owner refilled a purged cache")
        cache.setPressure(true)
        cache.put(item,key:"a",ticket:cache.take("a").ticket)
        XCTAssertNil(cache.take("a").value)
        cache.setPressure(false)
        cache.put(item,key:"a",ticket:cache.take("a").ticket)
        XCTAssertTrue(cache.take("a").value === item)
        let expired = IdleCompilationCache<String, Item>(lifetime:0)
        expired.put(item,key:"a",ticket:expired.take("a").ticket)
        XCTAssertNil(expired.take("a").value)
        XCTAssertTrue(IFNetCompilationKey.accepts(width:480,height:272,modelBytes:12_000_000))
        XCTAssertFalse(IFNetCompilationKey.accepts(width:960,height:544,modelBytes:12_000_000))
        XCTAssertFalse(IFNetCompilationKey.accepts(width:64,height:64,modelBytes:16*1024*1024+1))
        XCTAssertFalse(IFNetCompilationKey.accepts(width:Int.max,height:Int.max,modelBytes:1))
    }

    func testArtifactContentInvalidatesIdentity() throws {
        let original = try WeightStore(url:RifeConfiguration.bundledModelURL)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".rmw")
        defer { try? FileManager.default.removeItem(at:url) }
        var bytes = try Data(contentsOf:RifeConfiguration.bundledModelURL)
        try bytes.write(to:url)
        let copy = try WeightStore(url:url)
        XCTAssertEqual(copy.compilationDigest,original.compilationDigest)
        bytes[bytes.count-1] ^= 1
        try bytes.write(to:url,options:.atomic)
        XCTAssertNotEqual(try WeightStore(url:url).compilationDigest,original.compilationDigest)
    }

    private func frame(_ offset: Int) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attrs: [String:Any] = [kCVPixelBufferIOSurfacePropertiesKey as String:[:],
            kCVPixelBufferMetalCompatibilityKey as String:true]
        XCTAssertEqual(CVPixelBufferCreate(nil,64,64,kCVPixelFormatType_32BGRA,attrs as CFDictionary,&result),kCVReturnSuccess)
        let pixels = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(pixels,[])
        defer { CVPixelBufferUnlockBaseAddress(pixels,[]) }
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to:UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<64 { for x in 0..<64 {
            let i=y*stride+x*4
            base[i]=UInt8((x+y+offset)%120+30);base[i+1]=UInt8((x*2+offset)%150)
            base[i+2]=UInt8((y*3+offset)%200);base[i+3]=255
        } }
        return pixels
    }
    private func bytes(_ pixel: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(pixel,.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel,.readOnly) }
        var result = Data()
        let base=CVPixelBufferGetBaseAddress(pixel)!, stride=CVPixelBufferGetBytesPerRow(pixel)
        for y in 0..<64 {result.append(base.advanced(by:y*stride).assumingMemoryBound(to:UInt8.self),count:64*4)}
        return result
    }
    func testReusedProgramPreservesPixelsAndActiveInstancesAreIsolated() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {throw XCTSkip("Metal unavailable")}
        IFNetCompiledProgram.cache.purge()
        defer {IFNetCompiledProgram.cache.purge()}
        let a0=try frame(0),a1=try frame(7),b0=try frame(50),b1=try frame(57)
        let reference: (Data,Data,Double) = try autoreleasepool {
            let a=try RifeInterpolator(configuration:.bundled(qualityTier:.fast))
            let sa=try a.makeStream(width:64,height:64)
            let b=try RifeInterpolator(configuration:.bundled(qualityTier:.fast))
            let sb=try b.makeStream(width:64,height:64)
            XCTAssertFalse(a.compilationCacheHit);XCTAssertFalse(b.compilationCacheHit)
            _=try sa.push(a0,timesteps:[]);_=try sb.push(b0,timesteps:[])
            let outA=try sa.push(a1,timesteps:[0.5])
            let outB=try sb.push(b1,timesteps:[0.5])
            return (bytes(outA[0]),bytes(outB[0]),a.preparationMilliseconds[3])
        }
        XCTAssertNotEqual(reference.0,reference.1)
        let reused=try RifeInterpolator(configuration:.bundled(qualityTier:.fast))
        let stream=try reused.makeStream(width:64,height:64)
        XCTAssertTrue(reused.compilationCacheHit)
        XCTAssertEqual(reused.preparationMilliseconds[3],0)
        let other=try RifeInterpolator(configuration:.bundled(qualityTier:.fast))
        let otherStream=try other.makeStream(width:64,height:64)
        XCTAssertFalse(other.compilationCacheHit, "Active executable was shared")
        _=try stream.push(a0,timesteps:[]);_=try otherStream.push(b0,timesteps:[])
        XCTAssertEqual(bytes(try stream.push(a1,timesteps:[0.5])[0]),reference.0)
        XCTAssertEqual(bytes(try otherStream.push(b1,timesteps:[0.5])[0]),reference.1)
        print("Cold compile ms: \(reference.2); reused graph compile ms: \(reused.preparationMilliseconds[3])")
    }
}
