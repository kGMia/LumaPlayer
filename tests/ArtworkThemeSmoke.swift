import SwiftUI

@MainActor func sample(background: NSColor, blocks: [(CGRect, NSColor)]) -> NSImage {
    let context = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 160,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(background.cgColor); context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
    for (rect, color) in blocks { context.setFillColor(color.cgColor); context.fill(rect) }
    return NSImage(cgImage: context.makeImage()!, size: NSSize(width: 40, height: 40))
}
@MainActor func checkTheme() {
    let whiteRed = MediaArtworkTheme.extract(sample(background: .white, blocks: [(CGRect(x: 17, y: 14, width: 6, height: 10), .red)]))!
    precondition(whiteRed.stops[0].hue < 0.08 || whiteRed.stops[0].hue > 0.92)
    precondition(whiteRed.stops[0].saturation > 0.3)
    let dominantBlue = MediaArtworkTheme.extract(sample(background: .white, blocks: [
        (CGRect(x: 0, y: 0, width: 24, height: 40), .blue),
        (CGRect(x: 18, y: 18, width: 4, height: 4), .red)]))!
    precondition(abs(dominantBlue.stops[0].hue - 2.0/3.0) < 0.08)
    let sparse = MediaArtworkTheme.extract(sample(background: .white, blocks: [
        (CGRect(x: 20, y: 20, width: 1, height: 1), .red)]))!
    precondition(sparse.stops[0].saturation == 0)
    let muted = MediaArtworkTheme.extract(sample(background: NSColor(srgbRed: 0.7, green: 0.65, blue: 0.6, alpha: 1), blocks: []))!
    precondition(muted.stops[0].saturation > 0 && muted.stops[0].saturation < 0.2)
    let pinkClothing = MediaArtworkTheme.extract(sample(background: .white, blocks: [
        (CGRect(x: 8, y: 21, width: 25, height: 16), NSColor(srgbRed: 0.08, green: 0.06, blue: 0.09, alpha: 1)),
        (CGRect(x: 14, y: 7, width: 13, height: 12), NSColor(srgbRed: 1, green: 0.77, blue: 0.86, alpha: 1))]))!
    precondition(pinkClothing.stops[0].hue > 0.85 && pinkClothing.stops[0].hue < 0.99)
    precondition(pinkClothing.stops[0].saturation > 0.1)
    let darkHair = MediaArtworkTheme.extract(sample(background: .white, blocks: [
        (CGRect(x: 5, y: 5, width: 30, height: 30), NSColor(srgbRed: 0.06, green: 0.12, blue: 0.25, alpha: 1)),
        (CGRect(x: 16, y: 7, width: 12, height: 10), NSColor(srgbRed: 1, green: 0.77, blue: 0.86, alpha: 1))]))!
    precondition(darkHair.stops[0].hue > 0.85 && darkHair.stops[0].hue < 0.99)
    precondition(pinkClothing.stops.allSatisfy { $0.hue > 0.85 && $0.hue < 0.99 })
    precondition(whiteRed.stops.allSatisfy { min($0.hue, 1 - $0.hue) < 0.08 })
    let red = sample(background: .red, blocks: [])
    let green = sample(background: .green, blocks: [])
    let original = MediaArtworkTheme.resolve(for: "test-same-media-path", image: red)!
    let replacement = MediaArtworkTheme.resolve(for: "test-same-media-path", image: green)!
    precondition(original != replacement)
    precondition(replacement.stops.allSatisfy { abs($0.hue - 1.0/3.0) < 0.08 })
    print("PASS: sampled-only hue stops and replacement artwork cache invalidation")
    print("PASS: pastel pink clothing preferred over black and dark tinted hair")
    print("PASS: small red accent on white, dominant saturated block, isolated-pixel rejection, muted-cover fallback")
}
checkTheme()
