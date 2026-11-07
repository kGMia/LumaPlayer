// SPDX-License-Identifier: GPL-3.0-or-later
// Real decoder check against a generated red/green/blue three-chapter MKV.
// Does not open any window or read user media.
import Foundation
import CryptoKit
import CoreGraphics

@main struct TimelinePreviewDecodeSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure("Pass the generated MKV path") }
        let path = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.path
        var hashes = Set<String>()
        var times: [FFmpegPreviewDecoder.TimelineEncoding: [Double]] = [.bmp: [], .png: []]
        for target in [0.5, 2.5, 4.5] {
            var reference: Data?
            // Reverse codec order between repeats to reduce warm filesystem bias.
            for round in 0..<4 {
                let codecs: [FFmpegPreviewDecoder.TimelineEncoding] = round.isMultiple(of: 2) ? [.png, .bmp] : [.bmp, .png]
                for codec in codecs {
                    let start = ProcessInfo.processInfo.systemUptime
                    guard let result = await FFmpegPreviewDecoder(timelineEncoding: codec).decode(path: path, seconds: target) else {
                        throw Failure("No \(codec) image at \(target)")
                    }
                    let pixels = try rgba(result.image) // Include ImageIO's deferred decode.
                    let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                    if round > 0 { times[codec, default: []].append(ms) }
                    guard abs(result.seconds - target) < 0.1 else { throw Failure("Unexpected PTS \(result.seconds) at \(target)") }
                    guard result.image.width == 320, result.image.height == 180 else { throw Failure("Unexpected dimensions") }
                    if let reference, pixels != reference { throw Failure("BMP/PNG pixels or orientation differ at \(target)") }
                    reference = pixels
                }
            }
            hashes.insert(SHA256.hash(data: reference!).map { String(format: "%02x", $0) }.joined())
            print("PASS: target=\(target), BMP/PNG RGBA pixels and PTS match")
        }
        guard hashes.count == 3 else { throw Failure("Different chapter requests returned the same frame") }
        guard !TimelineThumbnail.isNear(0, target: 30), !TimelineThumbnail.isNear(.nan, target: 1),
              TimelineThumbnail.isNear(30.5, target: 30) else { throw Failure("Timestamp validation failed") }
        let canceled = FFmpegPreviewDecoder()
        canceled.cancel()
        guard await canceled.decode(path: path, seconds: 2.5) == nil else { throw Failure("Canceled decoder returned an image") }
        for codec in [FFmpegPreviewDecoder.TimelineEncoding.png, .bmp] {
            let values = times[codec]!.sorted(), mean = values.reduce(0,+)/Double(values.count)
            print(String(format: "%@ end-to-end preview: n=%d mean=%.3f ms median=%.3f ms", codec.rawValue, values.count, mean, values[values.count/2]))
        }
        print("Timing includes process startup, video seek/decode and ImageIO rendering; generated fixture only, not GUI hover latency.")
        print("PASS: three chapter positions yield distinct images and matching PTS; stale timestamps and cancellation rejected")
    }
    static func rgba(_ image: CGImage) throws -> Data {
        var bytes = Data(count: image.width * image.height * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw Failure("Cannot render image") }
        return bytes
    }
    struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
