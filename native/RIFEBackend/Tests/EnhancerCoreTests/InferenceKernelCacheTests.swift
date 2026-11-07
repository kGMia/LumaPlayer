import XCTest
import Metal
@testable import RifeMetalCore

final class InferenceKernelCacheTests: XCTestCase {
    func testReuseKeepsQueuesAndGraphsIndependentAndEvictionSafe() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        InferenceKernelCache.shared.purge()
        defer { InferenceKernelCache.shared.purge() }
        let first = try InferenceContext(preferredDevice:device)
        let second = try InferenceContext() // same default-device path as player model creation
        XCTAssertTrue(first.warpKernel === second.warpKernel)
        XCTAssertTrue(first.conversionKernels === second.conversionKernels)
        XCTAssertFalse(first.commandQueue === second.commandQueue)
        XCTAssertFalse(first.graph === second.graph)

        // Simulate the same purge used by the memory-pressure handler while
        // both contexts remain alive; their borrowed pipelines must remain valid.
        InferenceKernelCache.shared.purge()
        let third = try InferenceContext(preferredDevice:device)
        XCTAssertFalse(first.warpKernel === third.warpKernel)
        XCTAssertFalse(first.conversionKernels === third.conversionKernels)
        XCTAssertTrue(first.warpKernel.pipeline.device === device)
        XCTAssertGreaterThan(first.conversionKernels.nv12ToRGB.threadExecutionWidth,0)
    }
}
