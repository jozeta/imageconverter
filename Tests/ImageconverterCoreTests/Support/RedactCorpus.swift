import CoreGraphics
import CoreText
import Foundation
@testable import ImageconverterCore

/// Generated images with text for the Redact text-detection regression tests: each case knows where its text's ink
/// is, so a test can check that every inked pixel ends up inside a redacted rect.
enum RedactCorpus {
    enum Background {
        case white, black, gray(Double), gradient, photo
    }

    /// One piece of text: drawn centred on `center` (top-left origin, pixels), turned `angle` degrees
    /// counter-clockwise.
    struct Text {
        var string: String
        var font: String
        var size: Double
        var color = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
        var center: CGPoint
        var angle: Double = 0
    }

    struct Case {
        var name: String
        var width: Int
        var height: Int
        var background: Background
        var texts: [Text]
        /// False for text a person would hardly read either: reported, not required.
        var legible = true
    }

    /// The fraction of `text`'s ink pixels (coverage ≥ 25 %) inside one of `rects` (top-left pixel rects).
    static func coverage(of text: Text, in item: Case, rects: [CGRect]) -> Double {
        let ink = inkPixels(of: text, in: item)
        guard !ink.isEmpty else { return 1 }
        let inside = ink.filter { point in rects.contains { $0.contains(point) } }
        return Double(inside.count) / Double(ink.count)
    }

    static func image(_ item: Case) -> CGImage {
        let ctx = context(width: item.width, height: item.height)
        fill(item.background, ctx: ctx, width: item.width, height: item.height)
        for text in item.texts { draw(text, in: ctx, height: item.height, offset: .zero) }
        return ctx.makeImage()!
    }

    // MARK: - Cases

    static let all: [Case] = basics + rotations + fonts + layouts + large

    private static let white = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
    private static func gray(_ value: Double) -> RGBAColor { RGBAColor(red: value, green: value, blue: value, alpha: 1) }

    static let basics: [Case] = [
        Case(name: "plain 48 px", width: 1200, height: 400, background: .white,
             texts: [Text(string: "Invoice number 48213", font: "Helvetica", size: 48, center: CGPoint(x: 600, y: 200))]),
        Case(name: "tiny 8 px", width: 600, height: 200, background: .white,
             texts: [Text(string: "Account 5521 0094", font: "Helvetica", size: 8, center: CGPoint(x: 300, y: 100))],
             legible: false),
        Case(name: "small 10 px", width: 600, height: 200, background: .white,
             texts: [Text(string: "Account 5521 0094", font: "Helvetica", size: 10, center: CGPoint(x: 300, y: 100))]),
        Case(name: "small 12 px", width: 600, height: 200, background: .white,
             texts: [Text(string: "Account 5521 0094", font: "Helvetica", size: 12, center: CGPoint(x: 300, y: 100))]),
        Case(name: "huge 400 px", width: 2400, height: 800, background: .white,
             texts: [Text(string: "SALE", font: "Helvetica-Bold", size: 400, center: CGPoint(x: 1200, y: 400))]),
        Case(name: "light on dark", width: 1200, height: 400, background: .black,
             texts: [Text(string: "Private and confidential", font: "Helvetica", size: 40, color: white,
                          center: CGPoint(x: 600, y: 200))]),
        Case(name: "low contrast 20 %", width: 1200, height: 400, background: .gray(0.6),
             texts: [Text(string: "Membership 77341", font: "Helvetica", size: 40, color: gray(0.4),
                          center: CGPoint(x: 600, y: 200))]),
        Case(name: "low contrast 10 %", width: 1200, height: 400, background: .gray(0.55),
             texts: [Text(string: "Membership 77341", font: "Helvetica", size: 40, color: gray(0.45),
                          center: CGPoint(x: 600, y: 200))], legible: false),
        Case(name: "single number", width: 800, height: 400, background: .white,
             texts: [Text(string: "7", font: "Helvetica", size: 72, center: CGPoint(x: 400, y: 200))]),
        Case(name: "two digits", width: 800, height: 400, background: .white,
             texts: [Text(string: "42", font: "Helvetica", size: 60, center: CGPoint(x: 400, y: 200))]),
        Case(name: "licence plate", width: 1200, height: 600, background: .photo,
             texts: [Text(string: "ABC 123", font: "Helvetica-Bold", size: 90, center: CGPoint(x: 600, y: 300))]),
    ]

    static let rotations: [Case] = [10.0, -10, 30, -30, 90, 180, -90].map { angle in
        Case(name: "rotated \(Int(angle))°", width: 1200, height: 1200, background: .white,
             texts: [Text(string: "Order 99812 Stockholm", font: "Helvetica", size: 48,
                          center: CGPoint(x: 600, y: 600), angle: angle)])
    }

    static let fonts: [Case] = [
        ("Times-Italic", "italic"), ("AvenirNextCondensed-Bold", "condensed"), ("Chalkduster", "decorative chalk"),
        ("MarkerFelt-Wide", "marker"), ("Papyrus", "papyrus"), ("Courier", "typewriter"),
        ("SnellRoundhand", "script"),
    ].map { font, label in
        Case(name: "font \(label)", width: 1200, height: 400, background: .white,
             texts: [Text(string: "Reference 30517", font: font, size: 44, center: CGPoint(x: 600, y: 200))])
    }

    static let layouts: [Case] = [
        Case(name: "paragraph", width: 1400, height: 700, background: .white,
             texts: (0..<6).map { row in
                 Text(string: ["The patient was seen on the 4th of May", "and referred to the clinic in Uppsala",
                               "for further tests. Personal number", "19840512-1234, phone 070 123 45 67,",
                               "email anna.svensson at example dot com.", "Next visit: 2026-12-01 at 09:30."][row],
                      font: "Times-Roman", size: 28, center: CGPoint(x: 700, y: 140 + row * 80))
             }),
        Case(name: "on gradient", width: 1200, height: 600, background: .gradient,
             texts: [Text(string: "Ticket 55-2190", font: "Helvetica-Bold", size: 56, color: white,
                          center: CGPoint(x: 600, y: 300))]),
        Case(name: "on photo noise", width: 1600, height: 1000, background: .photo,
             texts: [Text(string: "Flat 4B, Storgatan 12", font: "Helvetica", size: 44, color: white,
                          center: CGPoint(x: 800, y: 300)),
                     Text(string: "Code 8831", font: "Helvetica-Bold", size: 40, center: CGPoint(x: 800, y: 700))]),
        Case(name: "near the edges", width: 1200, height: 800, background: .white,
             texts: [Text(string: "Top left 1111", font: "Helvetica", size: 32, center: CGPoint(x: 110, y: 14)),
                     Text(string: "Bottom right 2222", font: "Helvetica", size: 32, center: CGPoint(x: 1065, y: 786))]),
    ]

    static let large: [Case] = [
        Case(name: "6000 px, 24 px text", width: 6000, height: 4000, background: .photo,
             texts: [Text(string: "Serial 0042 7781", font: "Helvetica", size: 24, color: white,
                          center: CGPoint(x: 1200, y: 900)),
                     Text(string: "Badge 3310", font: "Helvetica-Bold", size: 24, center: CGPoint(x: 4500, y: 3100))]),
        Case(name: "8000 px, 20 px text", width: 8000, height: 6000, background: .white,
             texts: [Text(string: "Name: Erik Lund", font: "Helvetica", size: 20, center: CGPoint(x: 2000, y: 1500)),
                     Text(string: "Room 214", font: "Helvetica", size: 20, center: CGPoint(x: 6000, y: 4500))]),
        // Lines across the edges between the detection tiles (2048 px, 256 px overlap): no tile holds them whole.
        Case(name: "8000 px, text across tiles", width: 8000, height: 6000, background: .white,
             texts: [Text(string: "Customer 4471 Lindgren", font: "Helvetica", size: 30,
                          center: CGPoint(x: 1920, y: 1000)),
                     Text(string: "Locker 5590 Hall B", font: "Helvetica", size: 30, center: CGPoint(x: 3000, y: 1920),
                          angle: 90)]),
        Case(name: "8000 px, 40 px text", width: 8000, height: 6000, background: .photo,
             texts: [Text(string: "Plate XYZ 987", font: "Helvetica-Bold", size: 40,
                          center: CGPoint(x: 4000, y: 3000))]),
    ]

    // MARK: - Drawing

    private static func context(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    private static func line(_ text: Text, color: CGColor) -> CTLine {
        let font = CTFontCreateWithName(text.font as CFString, text.size, nil)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
        return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text.string as CFString, attributes)!)
    }

    /// Draws `text` into `ctx` (bottom-left origin, image `height` tall), its centre shifted by `offset`.
    private static func draw(_ text: Text, in ctx: CGContext, height: Int, offset: CGPoint, color: CGColor? = nil) {
        let color = color ?? CGColor(srgbRed: text.color.red, green: text.color.green, blue: text.color.blue, alpha: 1)
        let line = line(text, color: color)
        // Image bounds are measured from the context's text position, which the previous line moved on.
        ctx.textPosition = .zero
        let bounds = CTLineGetImageBounds(line, ctx)
        ctx.saveGState()
        ctx.translateBy(x: text.center.x - offset.x, y: CGFloat(height) - text.center.y + offset.y)
        ctx.rotate(by: text.angle * .pi / 180)
        ctx.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// The ink pixels of `text` alone, in image coordinates (top-left origin, pixel centres).
    static func inkPixels(of text: Text, in item: Case) -> [CGPoint] {
        let extent = Int((Double(text.string.count) * text.size + text.size * 2).rounded(.up))
        let side = extent
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data else { return [] }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        // The mask's centre is the text's centre.
        let origin = CGPoint(x: text.center.x - Double(side) / 2, y: text.center.y - Double(side) / 2)
        draw(text, in: ctx, height: side, offset: origin, color: CGColor(gray: 1, alpha: 1))
        let bytes = data.bindMemory(to: UInt8.self, capacity: side * side)
        var points: [CGPoint] = []
        for row in 0..<side {
            for column in 0..<side where bytes[row * side + column] >= 64 {
                let left = Double(column) + origin.x
                let top = Double(row) + origin.y
                guard left >= 0, top >= 0, left < Double(item.width), top < Double(item.height) else { continue }
                points.append(CGPoint(x: left + 0.5, y: top + 0.5))
            }
        }
        return points
    }

    private static func fill(_ background: Background, ctx: CGContext, width: Int, height: Int) {
        let all = CGRect(x: 0, y: 0, width: width, height: height)
        switch background {
        case .white: ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(all)
        case .black: ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(all)
        case .gray(let value): ctx.setFillColor(gray: value, alpha: 1); ctx.fill(all)
        case .gradient:
            let colors = [CGColor(srgbRed: 0.1, green: 0.3, blue: 0.7, alpha: 1),
                          CGColor(srgbRed: 0.8, green: 0.4, blue: 0.2, alpha: 1)] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                      locations: [0, 1])!
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        case .photo:
            // Smooth colour blotches (a small random image scaled up) plus fine grain: busy like a photo.
            ctx.interpolationQuality = .high
            ctx.draw(randomImage(width: 24, height: 16, seed: 7, range: 0.15...0.75), in: all)
            ctx.setAlpha(0.25)
            ctx.draw(randomImage(width: max(1, width / 4), height: max(1, height / 4), seed: 3, range: 0...1), in: all)
            ctx.setAlpha(1)
        }
    }

    private static func randomImage(width: Int, height: Int, seed: UInt64, range: ClosedRange<Double>) -> CGImage {
        let ctx = context(width: width, height: height)
        let bytes = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * height)
        var state = seed
        for row in 0..<height {
            for column in 0..<width {
                for channel in 0..<3 {
                    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    let unit = Double(state >> 40) / Double(1 << 24)
                    let value = range.lowerBound + unit * (range.upperBound - range.lowerBound)
                    bytes[row * ctx.bytesPerRow + column * 4 + channel] = UInt8(value * 255)
                }
                bytes[row * ctx.bytesPerRow + column * 4 + 3] = 255
            }
        }
        return ctx.makeImage()!
    }
}
