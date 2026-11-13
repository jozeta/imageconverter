import CoreGraphics
import Foundation

/// What counts as the border that Trim removes.
public enum TrimMode: Codable, Equatable, Sendable {
    /// Pixels at or below the alpha threshold.
    case transparent
    /// Pixels close to this colour.
    case color(RGBAColor)
    /// Pixels close to the colour of the top-left pixel.
    case edgeColor
}

public struct TrimOptions: Codable, Equatable, Sendable {
    public var mode: TrimMode
    /// 0...100: % difference allowed per channel (the alpha threshold for `.transparent`).
    public var tolerance: Double
    /// Pixels of border kept around the content (never more than the image has).
    public var padding: Int

    public static let toleranceRange: ClosedRange<Double> = 0...100

    public init(mode: TrimMode = .transparent, tolerance: Double = 10, padding: Int = 0) {
        self.mode = mode
        self.tolerance = tolerance
        self.padding = padding
    }

    private enum CodingKeys: String, CodingKey { case mode, tolerance, padding }

    /// Lenient: missing keys take their defaults, out-of-range values are clamped.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(mode: (try? container.decodeIfPresent(TrimMode.self, forKey: .mode)) ?? .transparent,
                  tolerance: Self.clampedTolerance(try container.decodeIfPresent(Double.self, forKey: .tolerance) ?? 10),
                  padding: max(0, try container.decodeIfPresent(Int.self, forKey: .padding) ?? 0))
    }

    /// The tolerance limited to 0...100; non-finite values become the default.
    public static func clampedTolerance(_ value: Double) -> Double {
        value.isFinite ? min(max(value, toleranceRange.lowerBound), toleranceRange.upperBound) : 10
    }
}

/// Removes a uniform (or transparent) border.
public enum Trim {
    public static func apply(_ options: TrimOptions, to image: CGImage) throws -> CGImage {
        let width = image.width
        let height = image.height
        // Scanned as 8-bit sRGB: plenty to tell content from border, and half the memory of a 16-bit copy.
        guard width >= 1, height >= 1, width <= ImageOps.maxPixels / height,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let base = ctx.data else {
            throw ConversionError.processingFailed(StepKind.trim.displayName)
        }
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let rowBytes = ctx.bytesPerRow
        let bytes = base.bindMemory(to: UInt8.self, capacity: rowBytes * height)
        let isBorder = matcher(options, firstPixel: (0..<4).map { Int(bytes[$0]) })

        // Bitmap memory starts at the top row, matching `cropping(to:)`'s top-left origin.
        var minX = width, minY = height, maxX = -1, maxY = -1
        for row in 0..<height {
            let line = bytes + row * rowBytes
            for col in 0..<width {
                let pixel = line + col * 4
                if !isBorder(pixel) {
                    minX = min(minX, col)
                    maxX = max(maxX, col)
                    minY = min(minY, row)
                    maxY = max(maxY, row)
                }
            }
        }
        // Nothing but border: leave the image as it is rather than produce nothing.
        guard maxX >= 0 else { return image }
        let pad = max(0, options.padding)
        // Clamped before adding, so a huge padding can't overflow.
        let left = minX - min(pad, minX)
        let top = minY - min(pad, minY)
        let right = maxX + min(pad, width - 1 - maxX)
        let bottom = maxY + min(pad, height - 1 - maxY)
        let rect = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        if rect.width == CGFloat(width), rect.height == CGFloat(height) { return image }
        guard let trimmed = image.cropping(to: rect) else {
            throw ConversionError.processingFailed(StepKind.trim.displayName)
        }
        return trimmed
    }

    private typealias Matcher = (UnsafeMutablePointer<UInt8>) -> Bool

    /// Whether a premultiplied 8-bit sRGB pixel (RGBA bytes) belongs to the border.
    private static func matcher(_ options: TrimOptions, firstPixel: [Int]) -> Matcher {
        let limit = Int((TrimOptions.clampedTolerance(options.tolerance) / 100 * 255).rounded())
        let target: [Int]
        switch options.mode {
        case .transparent:
            return { Int($0[3]) <= limit }
        case .edgeColor:
            target = firstPixel
        case .color(let color):
            // Premultiplied, like the scanned pixels.
            let clamp: (Double) -> Double = { $0.isFinite ? min(1, max(0, $0)) : 0 }
            let alpha = clamp(color.alpha)
            target = [color.red, color.green, color.blue].map { Int((clamp($0) * alpha * 255).rounded()) }
                + [Int((alpha * 255).rounded())]
        }
        return { pixel in
            abs(Int(pixel[0]) - target[0]) <= limit && abs(Int(pixel[1]) - target[1]) <= limit
                && abs(Int(pixel[2]) - target[2]) <= limit && abs(Int(pixel[3]) - target[3]) <= limit
        }
    }
}
