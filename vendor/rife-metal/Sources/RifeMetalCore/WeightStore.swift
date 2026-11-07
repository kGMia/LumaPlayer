import Foundation
import CryptoKit
import Metal
import MetalPerformanceShadersGraph

public enum WeightStoreError: Error, Equatable {
    case invalidMagic
    case unsupportedVersion(UInt32)
    case headerParseFailed(String)
    case tensorNotFound(String)
    case fileTooSmall
}

public final class WeightStore {
    public let header: RifeWeightHeader
    private let mappedData: Data
    /// Identity comes from validated artifact bytes, never a filename or mtime.
    let compilationDigest: String
    let artifactByteCount: Int
    private struct TensorLocation {
        let entry: RifeWeightHeader.TensorEntry
        let bytes: Range<Int>
    }
    private let locations: [String: TensorLocation]

    public init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= 12 else { throw WeightStoreError.fileTooSmall }

        let magic = data.subdata(in: 0..<4)
        guard magic == Data([0x52, 0x4D, 0x57, 0x31]) else {
            throw WeightStoreError.invalidMagic
        }

        let version = data.readUInt32LE(at: 4)
        guard version == 1 else { throw WeightStoreError.unsupportedVersion(version) }

        let headerLen = Int(data.readUInt32LE(at: 8))
        guard data.count >= 12 + headerLen else { throw WeightStoreError.fileTooSmall }
        let headerData = data.subdata(in: 12..<(12 + headerLen))

        let decoder = JSONDecoder()
        do {
            self.header = try decoder.decode(RifeWeightHeader.self, from: headerData)
        } catch {
            throw WeightStoreError.headerParseFailed(String(describing: error))
        }

        let unpadded = 12 + headerLen
        let padding = (16 - (unpadded % 16)) % 16
        let blobOffset = unpadded + padding
        guard blobOffset <= data.count else { throw WeightStoreError.fileTooSmall }
        var locations: [String: TensorLocation] = [:]
        locations.reserveCapacity(header.tensors.count)
        for entry in header.tensors {
            guard locations[entry.name] == nil else {
                throw WeightStoreError.headerParseFailed("Duplicate tensor name: \(entry.name)")
            }
            // Check using subtraction before addition: malformed offsets/sizes
            // must throw, not overflow or copy bytes beyond the mapped payload.
            guard entry.offset >= 0, entry.size >= 0,
                  entry.offset <= data.count - blobOffset,
                  entry.size <= data.count - blobOffset - entry.offset else {
                throw WeightStoreError.fileTooSmall
            }
            let start = blobOffset + entry.offset
            locations[entry.name] = TensorLocation(entry:entry,bytes:start..<(start+entry.size))
        }
        self.locations = locations
        self.mappedData = data
        self.artifactByteCount = data.count
        self.compilationDigest = SHA256.hash(data:data).map { String(format:"%02x", $0) }.joined()
    }

    /// All names and payload ranges are checked at initialization without copying
    /// tensor contents. Copy bytes only when graph construction actually needs them.
    public func tensorBytes(named name: String) throws -> Data {
        guard let location = locations[name] else {
            throw WeightStoreError.tensorNotFound(name)
        }
        return mappedData.subdata(in:location.bytes)
    }

    /// Wraps the named tensor's bytes as MPSGraphTensorData (fp16, NHWC).
    public func tensorData(named name: String,
                           on device: MTLDevice) throws -> MPSGraphTensorData {
        guard let location = locations[name] else {
            throw WeightStoreError.tensorNotFound(name)
        }
        let bytes = mappedData.subdata(in:location.bytes)
        return MPSGraphTensorData(
            device: MPSGraphDevice(mtlDevice: device),
            data: bytes,
            shape: location.entry.shape.map(NSNumber.init),
            dataType: .float16
        )
    }
}

// MARK: - Helpers

private extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        return self.withUnsafeBytes { buf -> UInt32 in
            buf.load(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }
}
