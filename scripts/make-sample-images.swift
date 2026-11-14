// Generates the sample images used by scripts/screenshots.sh: synthetic landscapes and patterns (no photos, no
// copyrighted material), one PNG with transparency and one JPEG with invented camera and GPS metadata.
// Usage: swift scripts/make-sample-images.swift <output folder>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "samples", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

func make(_ width: Int, _ height: Int, _ draw: (CGContext, CGFloat, CGFloat) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx, CGFloat(width), CGFloat(height))
    return ctx.makeImage()!
}

func gradient(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat, _ top: CGColor, _ bottom: CGColor) {
    let g = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: h), end: .zero, options: [])
}

func hills(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat, base: CGFloat, amp: CGFloat, phase: CGFloat, _ c: CGColor) {
    ctx.setFillColor(c)
    ctx.move(to: CGPoint(x: 0, y: 0))
    var x: CGFloat = 0
    while x <= w {
        ctx.addLine(to: CGPoint(x: x, y: base * h + amp * h * (sin(x / w * 5 + phase) * 0.6 + sin(x / w * 11 + phase * 2) * 0.4)))
        x += 4
    }
    ctx.addLine(to: CGPoint(x: w, y: 0))
    ctx.fillPath()
}

func landscape(_ w: Int, _ h: Int, sky: (CGColor, CGColor), sun: CGColor, hill: [CGColor], phase: CGFloat) -> CGImage {
    make(w, h) { ctx, w, h in
        gradient(ctx, w, h, sky.0, sky.1)
        ctx.setFillColor(sun)
        ctx.fillEllipse(in: CGRect(x: w * 0.68, y: h * 0.58, width: h * 0.18, height: h * 0.18))
        for (index, c) in hill.enumerated() {
            hills(ctx, w, h, base: 0.38 - CGFloat(index) * 0.1, amp: 0.1, phase: phase + CGFloat(index), c)
        }
    }
}

func pattern(_ w: Int, _ h: Int) -> CGImage {
    make(w, h) { ctx, w, h in
        gradient(ctx, w, h, color(0.1, 0.12, 0.3), color(0.55, 0.2, 0.5))
        for i in 0..<14 {
            let r = h * (0.12 + CGFloat(i) * 0.05)
            ctx.setStrokeColor(color(1, 0.8 - Double(i) * 0.04, 0.3 + Double(i) * 0.04, 0.55))
            ctx.setLineWidth(h * 0.012)
            ctx.strokeEllipse(in: CGRect(x: w / 2 - r, y: h / 2 - r, width: r * 2, height: r * 2))
        }
    }
}

func transparent(_ w: Int, _ h: Int) -> CGImage {
    make(w, h) { ctx, w, h in
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(color(0.95, 0.45, 0.2, 0.95))
        ctx.fillEllipse(in: CGRect(x: w * 0.1, y: h * 0.1, width: w * 0.55, height: h * 0.8))
        ctx.setFillColor(color(0.2, 0.55, 0.9, 0.8))
        ctx.fillEllipse(in: CGRect(x: w * 0.35, y: h * 0.05, width: w * 0.55, height: h * 0.8))
    }
}

func write(_ image: CGImage, _ name: String, type: UTType, properties: [CFString: Any] = [:]) {
    let url = outDir.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    var props = properties
    if type == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.85 }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    CGImageDestinationFinalize(dest)
}

write(landscape(1800, 1200, sky: (color(0.98, 0.62, 0.35), color(0.99, 0.9, 0.7)), sun: color(1, 0.95, 0.8),
                hill: [color(0.45, 0.3, 0.4), color(0.3, 0.2, 0.35), color(0.18, 0.12, 0.25)], phase: 0.3),
      "sunset.jpg", type: .jpeg)
write(landscape(1800, 1200, sky: (color(0.3, 0.6, 0.9), color(0.8, 0.92, 1)), sun: color(1, 1, 0.85),
                hill: [color(0.5, 0.75, 0.5), color(0.3, 0.6, 0.4), color(0.15, 0.4, 0.3)], phase: 1.7),
      "meadow.jpg", type: .jpeg)
write(landscape(1200, 1800, sky: (color(0.05, 0.08, 0.25), color(0.35, 0.3, 0.6)), sun: color(0.95, 0.95, 1),
                hill: [color(0.12, 0.15, 0.3), color(0.07, 0.09, 0.2)], phase: 2.9),
      "night.jpg", type: .jpeg)
write(pattern(1500, 1000), "rings.jpg", type: .jpeg)
write(transparent(1200, 800), "shapes.png", type: .png)

let located = landscape(1800, 1200, sky: (color(0.55, 0.8, 0.95), color(0.95, 0.97, 1)), sun: color(1, 0.9, 0.5),
                        hill: [color(0.6, 0.6, 0.45), color(0.4, 0.45, 0.35), color(0.25, 0.3, 0.25)], phase: 4.1)
write(located, "located.jpg", type: .jpeg, properties: [
    kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifDateTimeOriginal: "2026:06:14 10:32:05",
        kCGImagePropertyExifBodySerialNumber: "SN-0000-EXAMPLE",
        kCGImagePropertyExifLensModel: "Example 35mm f/2",
    ],
    kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Example Co", kCGImagePropertyTIFFModel: "Sample Camera 1"],
    kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitude: 59.0, kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 18.0, kCGImagePropertyGPSLongitudeRef: "E",
    ],
])
