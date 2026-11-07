import Foundation
import XCTest
import RifeMetal
@testable import RifeMetalCore

final class ModelProfileTests: XCTestCase {
    func testBundledArchitectureAndReplacementMask() throws {
        let store = try WeightStore(url: RifeConfiguration.bundledModelURL)
        try store.header.validateInferenceArchitecture()
        XCTAssertTrue(store.header.replacesStageMask)
        XCTAssertEqual(store.header.scaleList.max(), 16)
    }
    func testLiteArchitectureAndInvalidTensorSchema() throws {
        guard let path = ProcessInfo.processInfo.environment["IIVE_LITE_MODEL"] else {
            throw XCTSkip("Set IIVE_LITE_MODEL for converted official artifact")
        }
        let store = try WeightStore(url: URL(fileURLWithPath: path))
        try store.header.validateInferenceArchitecture()
        XCTAssertTrue(store.header.replacesStageMask)
        XCTAssertEqual(store.header.ifblockChannels.last, 24)
        XCTAssertEqual(store.header.scaleList.max(), 32)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.header)) as! [String: Any]
        json["scale_list"] = [16,8,4,2,1]
        var bad = try JSONDecoder().decode(RifeWeightHeader.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try bad.validateInferenceArchitecture())
        json["scale_list"] = [32,16,8,4,1]
        var tensors = json["tensors"] as! [[String: Any]]
        tensors[0]["dtype"] = "f32";json["tensors"] = tensors
        bad = try JSONDecoder().decode(RifeWeightHeader.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try bad.validateInferenceArchitecture())
    }
}
