import XCTest
import Metal
import RifeMetal
@testable import RifeMetalCore
@testable import EnhancerCore

final class PreparationCancellationTests: XCTestCase {
    func testCancelAndInvalidFPSBeforeModelAccess() {
        let missing = URL(fileURLWithPath: "/nonexistent/iive-test-model.rmw")
        XCTAssertThrowsError(try FrameProcessor(width:64,height:64,fps:60,tier:.fast,modelURL:missing,
            checkCancellation: { throw CancellationError() })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertThrowsError(try FrameProcessor(width:64,height:64,fps:17,tier:.fast,modelURL:missing)) {
            XCTAssertEqual(StreamFailure.code(for:$0),200)
        }
    }

    func testPartialPreparationCancellationDoesNotPoisonNextStream() throws {
        IFNetCompiledProgram.cache.purge()
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let model = try RifeInterpolator(configuration:.bundled(qualityTier:.fast))
        var checks = 0
        // Stop after preparation has entered the graph compiler, rather than
        // only testing the initial no-allocation shortcut.
        XCTAssertThrowsError(try model.makeStream(width:64,height:64) {
            checks += 1
            if checks == 5 { throw CancellationError() }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks,5)
        var retryChecks = 0
        let stream = try model.makeStream(width:64,height:64) { retryChecks += 1 }
        XCTAssertGreaterThan(retryChecks,checks)
        stream.reset(releasingUnusedResources:true)
    }

    func testCompletedPreparationHasFiniteTimingSnapshot() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let processor = try FrameProcessor(width:64,height:64,fps:60,tier:.fast)
        let timing = processor.initialPreparationMilliseconds
        XCTAssertEqual(timing.count,5)
        XCTAssertTrue(timing.allSatisfy { $0.isFinite && $0 >= 0 })
        processor.reset()
        XCTAssertEqual(processor.initialPreparationMilliseconds,timing)
    }
}
