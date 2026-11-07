import XCTest
@testable import RifeMetalCore

final class WeightStoreTests: XCTestCase {

    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RifeMetalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testLoadValidFile() throws {
        let url = tempDir.appendingPathComponent("test.rmw")
        try RMWTestFixture.write(
            tensors: [
                .init(name: "block0.weight", shape: [2, 1, 1, 2], values: [1, 2, 3, 4]),
                .init(name: "block0.bias",   shape: [2],           values: [0.5, -0.5]),
            ],
            to: url
        )

        let store = try WeightStore(url: url)
        XCTAssertEqual(store.header.model, "test-model")
        XCTAssertEqual(store.header.tensors.count, 2)
        XCTAssertEqual(store.header.tensors[0].name, "block0.weight")
        XCTAssertEqual(store.header.tensors[0].shape, [2, 1, 1, 2])
        XCTAssertEqual(store.header.tensors[0].size, 8)  // 4 fp16 values
    }

    func testTensorBytesCorrectness() throws {
        let url = tempDir.appendingPathComponent("test.rmw")
        try RMWTestFixture.write(
            tensors: [.init(name: "x", shape: [4], values: [1, 2, 3, 4])],
            to: url
        )

        let store = try WeightStore(url: url)
        let bytes = try store.tensorBytes(named: "x")
        XCTAssertEqual(bytes.count, 8)

        // Decode fp16 back to fp32 and compare.
        let decoded = bytes.withUnsafeBytes { buf -> [Float] in
            let ptr = buf.bindMemory(to: UInt16.self)
            return ptr.map { HalfPrecision.bitsToFloat(UInt16(littleEndian: $0)) }
        }
        XCTAssertEqual(decoded, [1, 2, 3, 4])
    }

    func testMissingTensorThrows() throws {
        let url = tempDir.appendingPathComponent("test.rmw")
        try RMWTestFixture.write(
            tensors: [.init(name: "x", shape: [1], values: [1])],
            to: url
        )

        let store = try WeightStore(url: url)
        XCTAssertThrowsError(try store.tensorBytes(named: "nope"))
    }

    func testInvalidMagicThrows() throws {
        let url = tempDir.appendingPathComponent("bad.rmw")
        try Data(repeating: 0xFF, count: 32).write(to: url)
        XCTAssertThrowsError(try WeightStore(url: url))
    }

    func testTruncatedPayloadRejectedBeforeTensorAccess() throws {
        let url = tempDir.appendingPathComponent("truncated.rmw")
        try RMWTestFixture.write(tensors:[.init(name:"x",shape:[2],values:[1,2])],to:url)
        var bytes = try Data(contentsOf:url)
        bytes.removeLast()
        try bytes.write(to:url)
        XCTAssertThrowsError(try WeightStore(url:url)) {
            XCTAssertEqual($0 as? WeightStoreError,.fileTooSmall)
        }
    }

    func testDuplicateNamesCannotShadowAnotherTensor() throws {
        let url = tempDir.appendingPathComponent("duplicate.rmw")
        try RMWTestFixture.write(tensors:[.init(name:"x",shape:[1],values:[1]),
                                         .init(name:"x",shape:[1],values:[2])],to:url)
        XCTAssertThrowsError(try WeightStore(url:url)) {
            guard case WeightStoreError.headerParseFailed = $0 else {
                return XCTFail("Expected duplicate-name validation, got \($0)")
            }
        }
    }

    func testInvalidRangesRejectWithoutIntegerOverflow() throws {
        for (offset,size) in [(-1,2),(0,-1),(Int.max,2),(2,Int.max),(8,1)] {
            let header:[String:Any] = ["model":"test-model","ifblock_channels":[4,2],
                "scale_list":[2,1],"input_layout":"NHWC","tensors":[
                    ["name":"x","dtype":"f16","shape":[1],"offset":offset,"size":size]]]
            let json = try JSONSerialization.data(withJSONObject:header,options:.sortedKeys)
            var file = Data([0x52,0x4d,0x57,0x31])
            for value in [UInt32(1),UInt32(json.count)] {
                var little = value.littleEndian
                withUnsafeBytes(of:&little) { file.append(contentsOf:$0) }
            }
            file.append(json)
            file.append(Data(repeating:0,count:(16-file.count%16)%16))
            file.append(Data(repeating:0,count:8))
            let url = tempDir.appendingPathComponent("invalid-range.rmw")
            try file.write(to:url)
            XCTAssertThrowsError(try WeightStore(url:url)) {
                XCTAssertEqual($0 as? WeightStoreError,.fileTooSmall)
            }
        }
    }

    func testIndexedReadsKeepTensorBytesAndMissingNameBehavior() throws {
        let url = tempDir.appendingPathComponent("indexed.rmw")
        try RMWTestFixture.write(tensors:[.init(name:"first",shape:[1],values:[1]),
                                         .init(name:"second",shape:[1],values:[2])],to:url)
        let store = try WeightStore(url:url)
        XCTAssertEqual(try store.tensorBytes(named:"second"),Data([0,0x40]))
        XCTAssertEqual(try store.tensorBytes(named:"first"),Data([0,0x3c]))
        XCTAssertThrowsError(try store.tensorBytes(named:"missing")) {
            XCTAssertEqual($0 as? WeightStoreError,.tensorNotFound("missing"))
        }
    }

    func testLoadFromPythonOutput() throws {
        let url = URL(fileURLWithPath: "/tmp/test.rmw")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("/tmp/test.rmw not present; run tools/convert-weights.py first")
        }
        let store = try WeightStore(url: url)
        XCTAssertEqual(store.header.model, "rife-v4.6")
        XCTAssertTrue(store.header.tensors.contains(where: { $0.name == "block0.conv0.0.weight" }))
        let bytes = try store.tensorBytes(named: "block0.conv0.0.weight")
        // PyTorch shape: [192, 7, 3, 3]. After HWIO permute: [3, 3, 7, 192].
        // Total elements: 192 * 7 * 3 * 3 = 12096. fp16 = 2 bytes each → 24192 bytes.
        XCTAssertEqual(bytes.count, 192 * 7 * 3 * 3 * 2)
    }
}
