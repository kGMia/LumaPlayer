// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreGraphics

@main struct NativePreviewSmoke {
    static func raster(_ image: CGImage) -> Data {
        var data = Data(count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }
    static func main() async {
        let path = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.path
        let reader = IIVELocalVideoPreview()
        var nativeTimes: [Double] = [], childTimes: [Double] = []
        for target in [0.5, 4.5, 2.5, 4.5, 0.5] {
            let started = ProcessInfo.processInfo.systemUptime
            guard let native = reader.readPath(path, seconds: target) else { fatalError("Native preview missing at \(target)") }
            let pixels = raster(native.image)
            nativeTimes.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
            let childStart = ProcessInfo.processInfo.systemUptime
            guard let fallback = await FFmpegPreviewDecoder().decode(path: path, seconds: target) else { fatalError("Fallback missing") }
            let expected = raster(fallback.image)
            childTimes.append((ProcessInfo.processInfo.systemUptime - childStart) * 1000)
            precondition(abs(native.seconds - target) < 0.1 && abs(native.seconds - fallback.seconds) < 0.001)
            precondition(native.image.width == fallback.image.width && native.image.height == fallback.image.height)
            precondition(pixels == expected, "Native/BMP color or orientation mismatch")
        }
        reader.close()
        precondition(reader.readPath(path, seconds: 2.5) != nil, "Idle close must allow reopen")
        reader.cancel()
        precondition(reader.readPath(path, seconds: 0.5) == nil)
        let invalid = IIVELocalVideoPreview()
        precondition(invalid.readPath(path, seconds: .nan) == nil)
        precondition(invalid.readPath("https://example.invalid/test.mkv", seconds: 1) == nil)
        precondition(invalid.readPath("/dev/null", seconds: 1) == nil)
        print("PASS: forward/backward reuse, native/BMP pixels/PTS, idle reopen, cancellation, local-only validation")
        print("Native ms: \(nativeTimes); BMP subprocess ms: \(childTimes). Generated fixture only; no GUI.")
    }
}
