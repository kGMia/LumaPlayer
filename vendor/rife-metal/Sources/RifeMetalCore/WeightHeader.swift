import Foundation

/// Decoded representation of the JSON header inside a .rmw file.
public struct RifeWeightHeader: Codable, Sendable {
    public struct TensorEntry: Codable, Sendable {
        public let name: String
        public let dtype: String
        public let shape: [Int]
        public let offset: Int
        public let size: Int
    }

    public let model: String
    public let ifblockChannels: [Int]
    public let scaleList: [Int]
    public let inputLayout: String
    public let tensors: [TensorEntry]

    /// Official inference models overwrite (not accumulate) stage masks.
    public var replacesStageMask: Bool {
        model == "rife-v4.26" || model == "rife-v4.25-lite"
    }
    public func validateInferenceArchitecture() throws {
        let channels: [Int], scales: [Int]
        switch model {
        case "rife-v4.26": channels = [192,128,96,64,32]; scales = [16,8,4,2,1]
        case "rife-v4.25-lite": channels = [192,128,96,64,24]; scales = [32,16,8,4,1]
        default: throw WeightStoreError.headerParseFailed("Unsupported inference model: \(model)")
        }
        guard ifblockChannels == channels, scaleList == scales, inputLayout == "NHWC" else {
            throw WeightStoreError.headerParseFailed("Model architecture does not match \(model)")
        }
        var expected: [String: [Int]] = [:]
        for (i, shape) in [[3,3,3,16],[3,3,16,16],[3,3,16,16],[4,4,4,16]].enumerated() {
            expected["encode.cnn\(i).weight"] = shape
            expected["encode.cnn\(i).bias"] = [i == 3 ? 4 : 16]
        }
        for (i,c) in channels.enumerated() {
            let prefix = "block\(i)."
            expected[prefix+"conv0.0.0.weight"] = [3,3,i == 0 ? 15 : 28,c/2]
            expected[prefix+"conv0.0.0.bias"] = [c/2]
            expected[prefix+"conv0.1.0.weight"] = [3,3,c/2,c]
            expected[prefix+"conv0.1.0.bias"] = [c]
            for j in 0..<8 {
                expected[prefix+"convblock.\(j).conv.weight"] = [3,3,c,c]
                expected[prefix+"convblock.\(j).conv.bias"] = [c]
                expected[prefix+"convblock.\(j).beta"] = [1,1,1,c]
            }
            expected[prefix+"lastconv.0.weight"] = [4,4,52,c]
            expected[prefix+"lastconv.0.bias"] = [52]
        }
        guard tensors.count == expected.count, Set(tensors.map(\.name)).count == tensors.count else {
            throw WeightStoreError.headerParseFailed("Duplicate or missing model tensors")
        }
        for tensor in tensors {
            guard let shape = expected[tensor.name], tensor.shape == shape,
                  tensor.dtype == "f16", tensor.size == shape.reduce(2, *) else {
                throw WeightStoreError.headerParseFailed("Invalid tensor schema: \(tensor.name)")
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case model
        case ifblockChannels = "ifblock_channels"
        case scaleList = "scale_list"
        case inputLayout = "input_layout"
        case tensors
    }
}
