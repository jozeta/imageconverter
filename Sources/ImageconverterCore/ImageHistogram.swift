import CoreGraphics
import Foundation

/// The preview's histogram: 256 bins per channel and for luminance, measured on a small sRGB copy of the image,
/// plus how much of it is clipped. Pixels with alpha 0 are not counted.
public struct ImageHistogram: Equatable, Sendable {
    public let red: [Int]
    public let green: [Int]
    public let blue: [Int]
    /// Rec. 709 luminance of the sRGB values, rounded.
    public let luminance: [Int]
    /// The pixels counted (the copy's pixels that aren't fully transparent).
    public let counted: Int
    /// Share of counted pixels with any channel at 255 (extended/HDR values above 1.0 count too).
    public let highlightFraction: Double
    /// Share of counted pixels with all three channels at 0.
    public let shadowFraction: Double

    /// Above this share (0.1 %) the preview warns about clipping.
    public static let warnFraction = 0.001

    public var isHighlightClipped: Bool { highlightFraction > Self.warnFraction }
    public var isShadowClipped: Bool { shadowFraction > Self.warnFraction }

    /// Measures `image` on a copy no larger than `maxSide` on its long side.
    public static func compute(_ image: CGImage, maxSide: Int = 1024) -> ImageHistogram {
        guard let pixels = SRGBPixels(image, maxSide: maxSide) else { return .empty }
        let rows = pixels.height
        let chunks = pixels.count > 1_000_000 ? min(ProcessInfo.processInfo.activeProcessorCount, rows) : 1
        var partials = [Partial](repeating: Partial(), count: chunks)
        partials.withUnsafeMutableBufferPointer { results in
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                let start = rows * chunk / chunks, end = rows * (chunk + 1) / chunks
                var partial = Partial()
                for row in start..<end { pixels.forEachPixel(inRow: row) { partial.add($0, $1, $2) } }
                results[chunk] = partial
            }
        }
        var total = Partial()
        for partial in partials { total.merge(partial) }
        let counted = total.counted
        return ImageHistogram(red: total.red, green: total.green, blue: total.blue, luminance: total.luminance,
                              counted: counted,
                              highlightFraction: counted > 0 ? Double(total.highlights) / Double(counted) : 0,
                              shadowFraction: counted > 0 ? Double(total.shadows) / Double(counted) : 0)
    }

    /// The clipped pixels of a ≤ `maxSide` copy: highlights opaque red, shadows opaque blue, the rest transparent.
    /// The view scales it over the image.
    public static func clippingMask(for image: CGImage, maxSide: Int = 2048) -> CGImage? {
        guard let pixels = SRGBPixels(image, maxSide: maxSide),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = pixels.width
        var mask = [UInt8](repeating: 0, count: width * pixels.height * 4)
        mask.withUnsafeMutableBufferPointer { out in
            let base = out.baseAddress!
            DispatchQueue.concurrentPerform(iterations: pixels.height) { row in
                var column = 0
                pixels.forEachPixel(inRow: row, includeTransparent: true) { red, green, blue in
                    defer { column += 1 }
                    let offset = (row * width + column) * 4
                    if red == 255 || green == 255 || blue == 255 {
                        base[offset] = 255; base[offset + 3] = 255
                    } else if red == 0, green == 0, blue == 0 {
                        base[offset + 1] = 80; base[offset + 2] = 255; base[offset + 3] = 255
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(mask) as CFData) else { return nil }
        return CGImage(width: width, height: pixels.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The bin height the chart scales to: the 99.5th percentile of the bins, so one spike doesn't flatten the rest.
    public static func displayPeak(_ bins: [Int]) -> Int {
        guard !bins.isEmpty else { return 1 }
        let sorted = bins.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.995).rounded(.down)))
        return max(sorted[index], 1)
    }

    static let empty = ImageHistogram(red: zeros, green: zeros, blue: zeros, luminance: zeros, counted: 0,
                                      highlightFraction: 0, shadowFraction: 0)
    private static let zeros = [Int](repeating: 0, count: 256)

    /// Counts for some rows, merged at the end.
    private struct Partial {
        var red = ImageHistogram.zeros, green = ImageHistogram.zeros, blue = ImageHistogram.zeros
        var luminance = ImageHistogram.zeros
        var counted = 0, highlights = 0, shadows = 0

        mutating func add(_ redValue: Int, _ greenValue: Int, _ blueValue: Int) {
            red[redValue] += 1; green[greenValue] += 1; blue[blueValue] += 1
            let luma = (0.2126 * Double(redValue) + 0.7152 * Double(greenValue) + 0.0722 * Double(blueValue)).rounded()
            luminance[min(max(Int(luma), 0), 255)] += 1
            counted += 1
            if redValue == 255 || greenValue == 255 || blueValue == 255 {
                highlights += 1
            } else if redValue == 0, greenValue == 0, blueValue == 0 {
                shadows += 1
            }
        }

        mutating func merge(_ other: Partial) {
            for bin in 0..<256 {
                red[bin] += other.red[bin]; green[bin] += other.green[bin]; blue[bin] += other.blue[bin]
                luminance[bin] += other.luminance[bin]
            }
            counted += other.counted; highlights += other.highlights; shadows += other.shadows
        }
    }
}

/// An image drawn into an 8-bit sRGB RGBA buffer no larger than `maxSide`; values above 1.0 clamp to 255.
private struct SRGBPixels: @unchecked Sendable {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    var count: Int { width * height }

    init?(_ image: CGImage, maxSide: Int) {
        let longest = max(image.width, image.height)
        guard longest > 0, maxSide > 0 else { return nil }
        let scale = min(1, Double(maxSide) / Double(longest))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// Calls `body` with each pixel's straight (non-premultiplied) values, left to right. Pixels with alpha 0 are
    /// skipped, or passed as (-1, -1, -1) with `includeTransparent`, so a caller can keep its column count.
    func forEachPixel(inRow row: Int, includeTransparent: Bool = false, _ body: (Int, Int, Int) -> Void) {
        bytes.withUnsafeBufferPointer { buffer in
            var offset = row * width * 4
            for _ in 0..<width {
                let alpha = Int(buffer[offset + 3])
                if alpha == 255 {
                    body(Int(buffer[offset]), Int(buffer[offset + 1]), Int(buffer[offset + 2]))
                } else if alpha > 0 {
                    body(Self.straight(buffer[offset], alpha), Self.straight(buffer[offset + 1], alpha),
                         Self.straight(buffer[offset + 2], alpha))
                } else if includeTransparent {
                    body(-1, -1, -1)
                }
                offset += 4
            }
        }
    }

    private static func straight(_ value: UInt8, _ alpha: Int) -> Int {
        min(255, (Int(value) * 255 + alpha / 2) / alpha)
    }
}
