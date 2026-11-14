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
///
/// Scans inward from each side in strips (8-bit sRGB, at most `stripPixels` at a time) and stops at the first
/// content row or column, so a large image needs no full copy and mostly only its border is read. Every pixel
/// that is read is read at full resolution: a downsampled pre-pass could average a thin line of content
/// into the background and trim it away.
public enum Trim {
    /// Pixels rendered per strip (16 MB at 4 bytes each).
    static let stripPixels = 4_000_000

    public static func apply(_ options: TrimOptions, to image: CGImage) throws -> CGImage {
        let width = image.width
        let height = image.height
        guard width >= 1, height >= 1 else { return image }
        let step = StepKind.trim.displayName
        let scanner = Scanner(image: image, test: try BorderTest(options, firstPixel: { try Scanner.firstPixel(of: image) }))

        // Rows from the top, then from the bottom; nothing found means the whole image is border.
        guard let top = try scanner.firstContentRow(in: 0..<height, fromEnd: false) else { return image }
        guard let bottom = try scanner.firstContentRow(in: top..<height, fromEnd: true) else {
            throw ConversionError.processingFailed(step)
        }
        // Columns only within the content rows.
        let band = top...bottom
        guard let left = try scanner.firstContentColumn(in: 0..<width, rows: band, fromEnd: false),
              let right = try scanner.firstContentColumn(in: left..<width, rows: band, fromEnd: true) else {
            throw ConversionError.processingFailed(step)
        }

        let pad = max(0, options.padding)
        // Clamped before adding, so a huge padding can't overflow.
        let minX = left - min(pad, left)
        let minY = top - min(pad, top)
        let maxX = right + min(pad, width - 1 - right)
        let maxY = bottom + min(pad, height - 1 - bottom)
        let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        if rect.width == CGFloat(width), rect.height == CGFloat(height) { return image }
        guard let trimmed = image.cropping(to: rect) else { throw ConversionError.processingFailed(step) }
        return trimmed
    }

    /// Whether a premultiplied 8-bit sRGB pixel (RGBA bytes) belongs to the border.
    struct BorderTest {
        let limit: Int
        /// nil: transparent mode (alpha at or below `limit`).
        let target: [Int]?

        init(_ options: TrimOptions, firstPixel: () throws -> [Int]) throws {
            limit = Int((TrimOptions.clampedTolerance(options.tolerance) / 100 * 255).rounded())
            switch options.mode {
            case .transparent:
                target = nil
            case .edgeColor:
                target = try firstPixel()
            case .color(let color):
                // Premultiplied, like the scanned pixels.
                let clamp: (Double) -> Double = { $0.isFinite ? min(1, max(0, $0)) : 0 }
                let alpha = clamp(color.alpha)
                target = [color.red, color.green, color.blue].map { Int((clamp($0) * alpha * 255).rounded()) }
                    + [Int((alpha * 255).rounded())]
            }
        }

        @inline(__always)
        func isBorder(_ pixel: UnsafePointer<UInt8>) -> Bool {
            guard let target else { return Int(pixel[3]) <= limit }
            return abs(Int(pixel[0]) - target[0]) <= limit && abs(Int(pixel[1]) - target[1]) <= limit
                && abs(Int(pixel[2]) - target[2]) <= limit && abs(Int(pixel[3]) - target[3]) <= limit
        }
    }

    /// Renders parts of the image (top-left origin) and finds the first content row or column.
    struct Scanner {
        let image: CGImage
        let test: BorderTest

        static func firstPixel(of image: CGImage) throws -> [Int] {
            try render(image, CGRect(x: 0, y: 0, width: 1, height: 1)) { bytes, _ in (0..<4).map { Int(bytes[$0]) } }
        }

        /// The first row in `rows` (from the start, or from the end) holding a content pixel.
        func firstContentRow(in rows: Range<Int>, fromEnd: Bool) throws -> Int? {
            let width = image.width
            let stripRows = max(1, Trim.stripPixels / width)
            for strip in strips(rows, size: stripRows, fromEnd: fromEnd) {
                let rect = CGRect(x: 0, y: strip.lowerBound, width: width, height: strip.count)
                let found: Int? = try Self.render(image, rect) { bytes, rowBytes in
                    let order = fromEnd ? Array((0..<strip.count).reversed()) : Array(0..<strip.count)
                    for row in order {
                        let line = bytes + row * rowBytes
                        for col in 0..<width where !test.isBorder(line + col * 4) { return strip.lowerBound + row }
                    }
                    return nil
                }
                if let found { return found }
            }
            return nil
        }

        /// The first column in `columns` (from the start, or from the end) with a content pixel in `rows`.
        func firstContentColumn(in columns: Range<Int>, rows: ClosedRange<Int>, fromEnd: Bool) throws -> Int? {
            let stripColumns = max(1, Trim.stripPixels / rows.count)
            for strip in strips(columns, size: stripColumns, fromEnd: fromEnd) {
                let rect = CGRect(x: strip.lowerBound, y: rows.lowerBound, width: strip.count, height: rows.count)
                let found: Int? = try Self.render(image, rect) { bytes, rowBytes in
                    let order = fromEnd ? Array((0..<strip.count).reversed()) : Array(0..<strip.count)
                    for col in order {
                        for row in 0..<rows.count where !test.isBorder(bytes + row * rowBytes + col * 4) {
                            return strip.lowerBound + col
                        }
                    }
                    return nil
                }
                if let found { return found }
            }
            return nil
        }

        /// `range` cut into pieces of at most `size`, in scanning order.
        private func strips(_ range: Range<Int>, size: Int, fromEnd: Bool) -> [Range<Int>] {
            let starts = Array(stride(from: range.lowerBound, to: range.upperBound, by: size))
            let pieces = starts.map { $0..<min($0 + size, range.upperBound) }
            return fromEnd ? pieces.reversed() : pieces
        }

        /// Renders the `rect` part of `image` as premultiplied 8-bit sRGB and passes its bytes to `body`.
        private static func render<T>(_ image: CGImage, _ rect: CGRect,
                                      _ body: (UnsafePointer<UInt8>, Int) -> T) throws -> T {
            let width = Int(rect.width)
            let height = Int(rect.height)
            guard let part = image.cropping(to: rect),
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let base = ctx.data else {
                throw ConversionError.processingFailed(StepKind.trim.displayName)
            }
            ctx.setBlendMode(.copy)
            ctx.draw(part, in: CGRect(x: 0, y: 0, width: width, height: height))
            // Bitmap memory starts at the top row, matching `cropping(to:)`'s top-left origin.
            return body(UnsafePointer(base.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * height)),
                        ctx.bytesPerRow)
        }
    }
}
