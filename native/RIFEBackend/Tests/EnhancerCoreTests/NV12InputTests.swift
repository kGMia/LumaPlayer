import XCTest
import CoreVideo
import CoreMedia
import Metal
import RifeMetalCore
@testable import EnhancerCore

/// Opt-in GPU checks: IIVE_GPU_TESTS=1 swift test --filter NV12InputTests
final class NV12InputTests: XCTestCase {
    func testBackstepPrerollPreservesClockAndRebasesInference() throws {
        try requireGPU()
        for fps: Int32 in [48, 60] {
            let reference = try FrameProcessor(width: 128, height: 72, fps: fps, tier: .fast,
                                              autoFallback: false, nativeNV12Output: true)
            let optimized = try FrameProcessor(width: 128, height: 72, fps: fps, tier: .fast,
                                              autoFallback: false, nativeNV12Output: true)
            for i in 0..<10 {
                let pixels = try frame(width: 128, height: 72, y: UInt8(80 + i * 5))
                // Offset the origin to catch accidental 24->60 clock re-anchoring.
                let pts = CMTime(value: Int64(i + 1), timescale: 24)
                let expected = try reference.push(pixels, pts: pts)
                let actual = try optimized.push(pixels, pts: pts, preroll: i < 6)
                XCTAssertEqual(actual.count, expected.count)
                for (a, b) in zip(actual, expected) {
                    XCTAssertEqual(CMTimeCompare(a.pts, b.pts), 0)
                    if i < 6 { XCTAssertFalse(a.synthesized) }
                    else {
                        XCTAssertEqual(a.synthesized, b.synthesized)
                        XCTAssertEqual(try meanLuma(a.pixels), try meanLuma(b.pixels), accuracy: 0.5)
                    }
                }
                if i < 6 { XCTAssertEqual(optimized.inferenceCount, 0) }
            }
            XCTAssertGreaterThan(optimized.inferenceCount, 0)
            XCTAssertLessThan(optimized.inferenceCount, reference.inferenceCount)
            optimized.reset()
            XCTAssertTrue(try optimized.push(frame(width: 128, height: 72, y: 80), pts: .zero).isEmpty)
        }
    }
    private func meanLuma(_ pixels: CVPixelBuffer) throws -> Double {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixels, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixels, 0)).assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        var sum = 0
        for y in 0..<height { for x in 0..<width { sum += Int(base[y * stride + x]) } }
        return Double(sum) / Double(width * height)
    }
    func testPreparedTierPreservesClockAndCancelsOnReset() throws {
        try requireGPU()
        for fps: Int32 in [48, 60] {
            let processor = try FrameProcessor(width: 128, height: 72, fps: fps, tier: .balanced,
                                               autoFallback: false, nativeNV12Output: true)
            var frames = try processor.push(frame(width: 128, height: 72, y: 90), pts: .zero)
            XCTAssertFalse(try processor.requestQualityTier(.fast))
            XCTAssertTrue(processor.isPreparingTier)
            // A pending preparation must still emit source frames immediately.
            let held = try processor.push(frame(width: 128, height: 72, y: 94), pts: CMTime(value: 1, timescale: 24))
            XCTAssertFalse(held.isEmpty)
            XCTAssertTrue(held.allSatisfy { !$0.synthesized })
            frames += held
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            var applied = false
            var index: Int64 = 2
            while !applied && ProcessInfo.processInfo.systemUptime < deadline {
                applied = try processor.requestQualityTier(.fast)
                frames += try processor.push(frame(width: 128, height: 72, y: UInt8(90 + (index % 10) * 4)),
                                             pts: CMTime(value: index, timescale: 24))
                index += 1
                if !applied { Thread.sleep(forTimeInterval: 0.005) }
            }
            XCTAssertTrue(applied)
            XCTAssertTrue(frames.contains { $0.synthesized })
            frames += try processor.finish(end: CMTime(value: index, timescale: 24))
            XCTAssertEqual(frames.count, Int(ceil(Double(index) / 24 * Double(fps))))
            for (i, output) in frames.enumerated() {
                XCTAssertEqual(CMTimeGetSeconds(output.pts), Double(i) / Double(fps), accuracy: 1e-8)
            }
            processor.reset()
            _ = try processor.push(frame(width: 128, height: 72, y: 90), pts: CMTime(value: 10, timescale: 1))
            XCTAssertFalse(try processor.requestQualityTier(.balanced))
            processor.reset()
            XCTAssertFalse(processor.isPreparingTier)
            XCTAssertTrue(try processor.requestQualityTier(.fast))
            XCTAssertTrue(try processor.push(frame(width: 128, height: 72, y: 94), pts: .zero).isEmpty)
        }
    }
    func testTierSwitchPreserves48And60Timeline() throws {
        try requireGPU()
        for fps: Int32 in [48, 60] {
            let processor = try FrameProcessor(width: 128, height: 72, fps: fps, tier: .balanced,
                                               autoFallback: false, nativeNV12Output: true)
            var frames: [VideoFrame] = []
            for i in 0..<5 {
                // Switch after a seeded previous frame, without resetting the output clock.
                if i == 2 { try processor.setQualityTier(.fast) }
                let pixels = try frame(width: 128, height: 72, y: UInt8(90 + i * 4))
                frames += try processor.push(pixels, pts: CMTime(value: Int64(i), timescale: 24))
            }
            frames += try processor.finish(end: CMTime(value: 5, timescale: 24))
            let expected = Int(ceil(5.0 / 24.0 * Double(fps)))
            XCTAssertEqual(frames.count, expected)
            for (i, frame) in frames.enumerated() {
                XCTAssertEqual(CMTimeGetSeconds(frame.pts), Double(i) / Double(fps), accuracy: 1e-8)
            }
            XCTAssertTrue(frames.contains { $0.synthesized && CMTimeGetSeconds($0.pts) > 2.0 / 24.0 })
        }
    }
    private func requireGPU() throws {
        guard ProcessInfo.processInfo.environment["IIVE_GPU_TESTS"] == "1" else {
            throw XCTSkip("Set IIVE_GPU_TESTS=1 on a Mac with Metal")
        }
    }
    private func frame(width: Int, height: Int, y: UInt8, u: UInt8 = 128, v: UInt8 = 128) throws -> CVPixelBuffer {
        var pixels: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &pixels), kCVReturnSuccess)
        let out = try XCTUnwrap(pixels)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(out, []), kCVReturnSuccess)
        for row in 0..<height {
            memset(CVPixelBufferGetBaseAddressOfPlane(out, 0)! + row * CVPixelBufferGetBytesPerRowOfPlane(out, 0), Int32(y), width)
        }
        let base = CVPixelBufferGetBaseAddressOfPlane(out, 1)!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height/2 { for col in 0..<width/2 {
            let i = row * CVPixelBufferGetBytesPerRowOfPlane(out, 1) + col * 2
            base[i] = u; base[i+1] = v
        }}
        CVPixelBufferUnlockBaseAddress(out, [])
        CVBufferSetAttachment(out, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center, .shouldPropagate)
        return out
    }
    func testVideoRangeRGBLayoutAndPadding() throws {
        try requireGPU()
        let ctx = try InferenceContext()
        var cache: CVMetalTextureCache?
        XCTAssertEqual(CVMetalTextureCacheCreate(nil, nil, ctx.device, nil, &cache), kCVReturnSuccess)
        // Black, white, neutral gray and saturated colors test range, channel order and NHWC stride.
        for (y, u, v) in [(16,128,128), (235,128,128), (126,128,128), (63,102,240), (32,240,118)] {
            let pixels = try frame(width: 4, height: 2, y: UInt8(y), u: UInt8(u), v: UInt8(v))
            let input = try StreamInput(pixels, cache: XCTUnwrap(cache))
            // A larger destination exercises replication of the source's right/bottom edges.
            for inverseScale: Float in [1, 2] {
                let out = try XCTUnwrap(ctx.device.makeBuffer(length: 6 * 4 * 3 * 2, options: .storageModeShared))
                let cb = try XCTUnwrap(ctx.commandQueue.makeCommandBuffer())
                let enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
                input.encode(enc, kernels: ctx.conversionKernels, output: out, width: 6, height: 4, inverseScale: inverseScale)
                enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
                XCTAssertNil(cb.error)
                let yy = Float(y - 16)/219, uu = Float(u - 128)/224, vv = Float(v - 128)/224
                let expected = [yy + 1.5748 * vv, yy - 0.187324 * uu - 0.468124 * vv, yy + 1.8556 * uu].map { min(1, max(0, $0)) }
                let values = out.contents().assumingMemoryBound(to: Float16.self)
                for i in 0..<24 { for c in 0..<3 {
                    XCTAssertEqual(Float(values[i*3+c]), expected[c], accuracy: 0.002)
                }}
                withExtendedLifetime(input) {}
            }
        }
        let invalid = try frame(width: 4, height: 2, y: 16)
        CVBufferRemoveAttachment(invalid, kCVImageBufferYCbCrMatrixKey)
        XCTAssertThrowsError(try StreamInput(invalid, cache: XCTUnwrap(cache)))
    }
    func testNV12Stream48FPSAndReset() throws {
        try requireGPU()
        let processor = try FrameProcessor(width: 128, height: 72, fps: 48, tier: .fast, autoFallback: false, nativeNV12Output: true)
        let first = try frame(width: 128, height: 72, y: 90)
        // Chroma-only change must not be classified as a duplicate.
        let second = try frame(width: 128, height: 72, y: 90, u: 116, v: 140)
        XCTAssertTrue(try processor.push(first, pts: .zero).isEmpty)
        let out = try processor.push(second, pts: CMTime(value: 1, timescale: 24))
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.map(\.synthesized), [false, true])
        XCTAssertEqual(out.map { CMTimeGetSeconds($0.pts) }, [0, 1.0/48])
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(out[0].pixels), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(out[1].pixels), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(CVPixelBufferGetHeight(out[1].pixels), 72)
        XCTAssertEqual(processor.inferenceCount, 1)
        XCTAssertFalse(try processor.finish(end: CMTime(value: 2, timescale: 24)).isEmpty)
        processor.reset()
        XCTAssertTrue(try processor.push(first, pts: CMTime(value: 10, timescale: 1)).isEmpty)
    }
}
