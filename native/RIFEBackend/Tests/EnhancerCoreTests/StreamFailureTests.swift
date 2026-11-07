import XCTest
import RifeMetal
@testable import EnhancerCore

final class StreamFailureTests: XCTestCase {
    func testStableCodesDiscardErrorDetails() {
        let privateDetail = "/private/model/path?token=secret"
        let cases: [(Error, Int32)] = [
            (CancellationError(), 102),
            (BackendError.invalid(privateDetail), 200),
            (RifeError.modelLoadFailed(privateDetail), 201),
            (RifeError.unsupportedPixelFormat(0), 202),
            (RifeError.dimensionMismatch, 203),
            (RifeError.metalUnavailable, 204),
            (RifeError.shaderCompilationFailed(privateDetail), 205),
            (RifeError.inferenceFailed(privateDetail), 206),
            (RifeError.invalidTimesteps(privateDetail), 207),
            (NSError(domain: privateDetail, code: -1), 299)
        ]
        for (error, expected) in cases { XCTAssertEqual(StreamFailure.code(for: error), expected) }
    }
}
