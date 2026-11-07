import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import VideoToolbox
import UniformTypeIdentifiers
import SPANCoreML

enum ImageBuffers {
    static func make(_ width: Int, _ height: Int, format: OSType = kCVPixelFormatType_32BGRA) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        guard CVPixelBufferCreate(nil, width, height, format, attrs as CFDictionary, &result) == kCVReturnSuccess,
              let result else { throw SPANError("Pixel buffer allocation failed") }
        CVBufferSetAttachment(result, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(result, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(result, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return result
    }

    static func read(_ url: URL) throws -> CVPixelBuffer {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.bitsPerComponent == 8, image.width <= 3840, image.height <= 3840,
              let color = image.colorSpace, color.model == .rgb,
              !CGColorSpaceIsPQBased(color), !CGColorSpaceIsHLGBased(color), !CGColorSpaceUsesExtendedRange(color) else {
            throw SPANError("Benchmark requires RGB8 SDR images; ImageIO converts the source profile to sRGB")
        }
        let pixels = try make(image.width, image.height)
        guard CVPixelBufferLockBaseAddress(pixels, []) == kCVReturnSuccess else { throw SPANError("Pixel lock failed") }
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            throw SPANError("Image decode context failed")
        }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    static func write(_ pixels: CVPixelBuffer, to url: URL) throws {
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image) == noErr,
              let image, let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SPANError("Cannot create diagnostic PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SPANError("Cannot write diagnostic PNG") }
    }

    static func transfer(_ source: CVPixelBuffer, format: OSType) throws -> CVPixelBuffer {
        let result = try make(CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source), format: format)
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) == noErr, let session else {
            throw SPANError("Pixel transfer session failed")
        }
        defer { VTPixelTransferSessionInvalidate(session) }
        guard VTPixelTransferSessionTransferImage(session, from: source, to: result) == noErr else {
            throw SPANError("RGB/NV12 transfer failed")
        }
        return result
    }

    static func error(_ output: CVPixelBuffer, reference: CVPixelBuffer) throws -> [String: Any] {
        let w = CVPixelBufferGetWidth(reference), h = CVPixelBufferGetHeight(reference)
        guard CVPixelBufferGetWidth(output) == w, CVPixelBufferGetHeight(output) == h,
              CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(reference) == kCVPixelFormatType_32BGRA else { throw SPANError("Reference dimensions/format mismatch") }
        guard CVPixelBufferLockBaseAddress(output, .readOnly) == kCVReturnSuccess else { throw SPANError("Output lock failed") }
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        guard CVPixelBufferLockBaseAddress(reference, .readOnly) == kCVReturnSuccess else { throw SPANError("Reference lock failed") }
        defer { CVPixelBufferUnlockBaseAddress(reference, .readOnly) }
        guard let a = CVPixelBufferGetBaseAddress(output)?.assumingMemoryBound(to: UInt8.self),
              let b = CVPixelBufferGetBaseAddress(reference)?.assumingMemoryBound(to: UInt8.self) else { throw SPANError("Missing pixels") }
        let sa = CVPixelBufferGetBytesPerRow(output), sb = CVPixelBufferGetBytesPerRow(reference)
        var square = 0.0, absolute = 0.0
        for y in 0..<h { for x in 0..<w { for c in 0..<3 {
            let difference = Double(a[y*sa+x*4+c]) - Double(b[y*sb+x*4+c])
            square += difference*difference; absolute += abs(difference)
        } } }
        let count = Double(w*h*3), mse = square/count
        return ["psnr_db": mse > 0 ? 10*log10(255*255/mse) : NSNull(), "mae_code_values": absolute/count,
                "mse_code_values": mse, "exact_match": mse == 0, "samples": Int(count)]
    }
}
