import CryptoKit
import Foundation
import XCTest
@testable import RifeMetalCore

final class AdditionRoundingPatternTests: XCTestCase {
    func testPatternPreservesOriginalReferenceBytes() throws {
        #if arch(arm64)
        let pattern = AdditionRoundingPattern.forCount(1_000_000)
        let values = [pattern.lhs, pattern.rhs, pattern.nearestEven, pattern.nearestAway]
        // Captured from the original probe before refactoring (arm64 Float16).
        let expected = [
            "e39eb41b8a2a17ff271502f407a863af2785e019096341fa64a9e222b98b11ab",
            "cccdc5055d7399b199f2356574069eccb1ec0bef347888c3723a1d1db0735b67",
            "cfcab75bcb81b9abc690564153c7877e2b4feb146ea5b75a157ecd0a56799923",
            "a7c2b1208b3d2b86d81df4df139e84cb098521561cde7f036a0ce72c02cabe55"
        ]
        for (value, hash) in zip(values, expected) {
            XCTAssertEqual(value.count, AdditionRoundingPattern.period)
            let digest = value.withUnsafeBytes { SHA256.hash(data: Data($0)) }
            XCTAssertEqual(digest.map { String(format:"%02x", $0) }.joined(), hash)
        }
        let small = AdditionRoundingPattern.forCount(17)
        XCTAssertEqual(small.lhs, Array(pattern.lhs.prefix(17)))
        XCTAssertEqual(small.rhs, Array(pattern.rhs.prefix(17)))
        XCTAssertEqual(small.nearestEven, Array(pattern.nearestEven.prefix(17)))
        XCTAssertEqual(small.nearestAway, Array(pattern.nearestAway.prefix(17)))
        let reused = AdditionRoundingPattern.forCount(2_000_000)
        pattern.lhs.withUnsafeBufferPointer { first in
            reused.lhs.withUnsafeBufferPointer { XCTAssertEqual(first.baseAddress, $0.baseAddress) }
        }
        #else
        throw XCTSkip("Float16 reference probe is arm64 only")
        #endif
    }
}
