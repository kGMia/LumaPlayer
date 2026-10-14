import Foundation
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconDir = root.appendingPathComponent("AppIcon.icon")
let assetsDir = iconDir.appendingPathComponent("Assets")

guard FileManager.default.fileExists(atPath: iconDir.path) else {
    print("AppIcon.icon not found at \(iconDir.path)")
    exit(1)
}

let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(data: nil,
                              width: size,
                              height: size,
                              bitsPerComponent: 8,
                              bytesPerRow: size * 4,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    print("Failed to create CGContext")
    exit(1)
}

// 1. Draw rounded rectangle background squircle
let rect = CGRect(x: 64, y: 64, width: 896, height: 896)
let path = CGPath(roundedRect: rect, cornerWidth: 200, cornerHeight: 200, transform: nil)

context.saveGState()
context.addPath(path)
context.clip()

// Linear gradient:
// display-p3:0.48668,0.70040,1.00000,1.00000 -> display-p3:0.40389,0.24642,0.96923,1.00000
let startColor = CGColor(colorSpace: colorSpace, components: [0.48668, 0.70040, 1.00000, 1.0])!
let endColor = CGColor(colorSpace: colorSpace, components: [0.40389, 0.24642, 0.96923, 1.0])!
let gradient = CGGradient(colorsSpace: colorSpace, colors: [startColor, endColor] as CFArray, locations: [0.0, 1.0])!
context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 960), end: CGPoint(x: 512, y: 64), options: [])

func loadImage(_ name: String) -> CGImage? {
    let url = assetsDir.appendingPathComponent(name)
    guard let nsImage = NSImage(contentsOf: url) else { return nil }
    var rect = CGRect(origin: .zero, size: nsImage.size)
    return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
}

// 2. Draw layers
let center = CGPoint(x: 512, y: 512)

// Layer a3 2.png
if let img = loadImage("a3 2.png") {
    context.saveGState()
    context.setAlpha(0.85)
    let w = CGFloat(img.width)
    let h = CGFloat(img.height)
    let originX = center.x - 221 - w / 2
    let originY = center.y - 138 - h / 2
    context.draw(img, in: CGRect(x: originX, y: originY, width: w, height: h))
    context.restoreGState()
}

// Layer a3.png
if let img = loadImage("a3.png") {
    context.saveGState()
    context.setAlpha(0.9)
    let w = CGFloat(img.width)
    let h = CGFloat(img.height)
    let originX = center.x - 221 - w / 2
    let originY = center.y + 124.8 - h / 2
    context.draw(img, in: CGRect(x: originX, y: originY, width: w, height: h))
    context.restoreGState()
}

// Layer a2.png
if let img = loadImage("a2.png") {
    context.saveGState()
    let w = CGFloat(img.width)
    let h = CGFloat(img.height)
    let originX = center.x + 276 - w / 2
    let originY = center.y - h / 2
    context.draw(img, in: CGRect(x: originX, y: originY, width: w, height: h))
    context.restoreGState()
}

// Layer a1.png (scale: 0.7, translation: 25, 0.35)
if let img = loadImage("a1.png") {
    context.saveGState()
    let w = CGFloat(img.width) * 0.7
    let h = CGFloat(img.height) * 0.7
    let originX = center.x + 25 - w / 2
    let originY = center.y + 0.35 - h / 2
    context.draw(img, in: CGRect(x: originX, y: originY, width: w, height: h))
    context.restoreGState()
}

context.restoreGState()

guard let masterImage = context.makeImage() else {
    print("Failed to create master CGImage")
    exit(1)
}

// 3. Create iconset folder
let iconsetDir = root.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

let resolutions: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, dim) in resolutions {
    guard let thumbContext = CGContext(data: nil,
                                       width: dim,
                                       height: dim,
                                       bitsPerComponent: 8,
                                       bytesPerRow: dim * 4,
                                       space: colorSpace,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
    thumbContext.interpolationQuality = .high
    thumbContext.draw(masterImage, in: CGRect(x: 0, y: 0, width: dim, height: dim))
    guard let thumbImg = thumbContext.makeImage() else { continue }
    let rep = NSBitmapImageRep(cgImage: thumbImg)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    let fileURL = iconsetDir.appendingPathComponent(name)
    try data.write(to: fileURL)
}

// 4. Generate AppIcon.icns
let icnsURL = root.appendingPathComponent("AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsURL.path]
try p.run()
p.waitUntilExit()

if p.terminationStatus == 0 {
    print("Successfully generated AppIcon.icns (\(icnsURL.path))")
} else {
    print("iconutil failed with code \(p.terminationStatus)")
}

// 5. Also populate Assets.xcassets/AppIcon.appiconset
let xcassetsDir = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: xcassetsDir, withIntermediateDirectories: true)

let appIconContents = """
{
  "images" : [
    { "size" : "16x16", "idiom" : "mac", "filename" : "icon_16x16.png", "scale" : "1x" },
    { "size" : "16x16", "idiom" : "mac", "filename" : "icon_16x16@2x.png", "scale" : "2x" },
    { "size" : "32x32", "idiom" : "mac", "filename" : "icon_32x32.png", "scale" : "1x" },
    { "size" : "32x32", "idiom" : "mac", "filename" : "icon_32x32@2x.png", "scale" : "2x" },
    { "size" : "128x128", "idiom" : "mac", "filename" : "icon_128x128.png", "scale" : "1x" },
    { "size" : "128x128", "idiom" : "mac", "filename" : "icon_128x128@2x.png", "scale" : "2x" },
    { "size" : "256x256", "idiom" : "mac", "filename" : "icon_256x256.png", "scale" : "1x" },
    { "size" : "256x256", "idiom" : "mac", "filename" : "icon_256x256@2x.png", "scale" : "2x" },
    { "size" : "512x512", "idiom" : "mac", "filename" : "icon_512x512.png", "scale" : "1x" },
    { "size" : "512x512", "idiom" : "mac", "filename" : "icon_512x512@2x.png", "scale" : "2x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try? appIconContents.write(to: xcassetsDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
for (name, _) in resolutions {
    let src = iconsetDir.appendingPathComponent(name)
    let dst = xcassetsDir.appendingPathComponent(name)
    try? FileManager.default.copyItem(at: src, to: dst)
}
print("Successfully populated Assets.xcassets/AppIcon.appiconset")
