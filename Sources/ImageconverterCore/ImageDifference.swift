import Accelerate
import CoreGraphics
import Foundation

/// Compares an image with its re-encoded version, so lossy artifacts become visible and measurable.
public enum ImageDifference {
    public struct Stats: Equatable, Sendable {
        /// Mean absolute error over the R, G and B channels, 0...255.
        public let meanAbsError: Double
        public let maxError: Int
        /// Peak signal-to-noise ratio in dB; infinity for identical images.
        public let psnr: Double
    }

    public enum CompareError: Error, Equatable {
        /// Before and after have different pixel sizes, so there is nothing to compare pixel by pixel.
        case sizeMismatch
        /// A bitmap couldn't be made (out of memory or an unsupported image).
        case renderFailed
    }

    /// The amplified difference of one region and its error figures.
    public struct Comparison: @unchecked Sendable {
        public let image: CGImage
        public let stats: Stats
    }

    /// The difference of `region` (unit coordinates, origin top left) of both images, drawn at most `maxSide`
    /// pixels on the longer side, with error figures over the same pixels. Only the two crops and the result are
    /// kept in memory. Stops with `CancellationError` between strips when the task is cancelled.
    public static func compare(before: CGImage, after: CGImage, region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
                               maxSide: Int = 2048, amplify: Double = 4) throws -> Comparison {
        guard before.width == after.width, before.height == after.height else { throw CompareError.sizeMismatch }
        try Task.checkCancellation()
        guard let left = RegionCrop.draw(before, region: region, maxSide: maxSide) else { throw CompareError.renderFailed }
        try Task.checkCancellation()
        guard let right = RegionCrop.draw(after, region: region, maxSide: maxSide) else { throw CompareError.renderFailed }
        try Task.checkCancellation()
        guard let pair = buffers(left, right) else { throw CompareError.renderFailed }
        var bytes = pair.0
        var factor = Float(max(0, amplify))
        var low: Float = 0
        var high: Float = 255
        var sum = 0.0
        var squares = 0.0
        var maxError: Float = 0
        try forEachStrip(left: &bytes, right: pair.1, cancellable: true) { delta, range, buffer in
            let length = vDSP_Length(delta.count)
            var stripSum: Float = 0
            var stripSquares: Float = 0
            var stripMax: Float = 0
            vDSP_sve(delta, 1, &stripSum, length)
            vDSP_svesq(delta, 1, &stripSquares, length)
            vDSP_maxv(delta, 1, &stripMax, length)
            sum += Double(stripSum)
            squares += Double(stripSquares)
            maxError = max(maxError, stripMax)
            vDSP_vsmul(delta, 1, &factor, &delta, 1, length)
            vDSP_vclip(delta, 1, &low, &high, &delta, 1, length)
            buffer.withUnsafeMutableBufferPointer { vDSP_vfixru8(delta, 1, $0.baseAddress! + range.lowerBound, 1, length) }
        }
        for index in stride(from: 3, to: bytes.count, by: 4) { bytes[index] = 255 }
        guard let image = makeImage(&bytes, width: left.width, height: left.height) else { throw CompareError.renderFailed }
        let samples = Double(left.width * left.height * 3)
        let stats = squares > 0
            ? Stats(meanAbsError: sum / samples, maxError: Int(maxError), psnr: 10 * log10(255 * 255 * samples / squares))
            : Stats(meanAbsError: 0, maxError: 0, psnr: .infinity)
        return Comparison(image: image, stats: stats)
    }

    /// Per-channel absolute difference times `amplify`, clamped, on black. Nil when the sizes differ.
    /// Works in row strips so memory stays at two 8-bit copies plus a small float scratch.
    public static func render(before: CGImage, after: CGImage, amplify: Double = 4) -> CGImage? {
        guard let pair = buffers(before, after) else { return nil }
        var left = pair.0
        let right = pair.1
        var factor = Float(max(0, amplify))
        var low: Float = 0
        var high: Float = 255
        try? forEachStrip(left: &left, right: right) { delta, range, buffer in
            let length = vDSP_Length(delta.count)
            vDSP_vsmul(delta, 1, &factor, &delta, 1, length)
            vDSP_vclip(delta, 1, &low, &high, &delta, 1, length)
            buffer.withUnsafeMutableBufferPointer { vDSP_vfixru8(delta, 1, $0.baseAddress! + range.lowerBound, 1, length) }
        }
        // The alpha lane is not a difference; the result is always opaque.
        for index in stride(from: 3, to: left.count, by: 4) { left[index] = 255 }
        return makeImage(&left, width: before.width, height: before.height)
    }

    /// Error figures over the RGB channels. Nil when the sizes differ, like `render`.
    public static func stats(before: CGImage, after: CGImage) -> Stats? {
        guard let pair = buffers(before, after) else { return nil }
        var left = pair.0
        let right = pair.1
        var sum = 0.0
        var squares = 0.0
        var maxError: Float = 0
        // Both images are opaque after `rgba`, so the alpha lane's difference is 0 and changes nothing.
        try? forEachStrip(left: &left, right: right) { delta, _, _ in
            let length = vDSP_Length(delta.count)
            var stripSum: Float = 0
            var stripSquares: Float = 0
            var stripMax: Float = 0
            vDSP_sve(delta, 1, &stripSum, length)
            vDSP_svesq(delta, 1, &stripSquares, length)
            vDSP_maxv(delta, 1, &stripMax, length)
            sum += Double(stripSum)
            squares += Double(stripSquares)
            maxError = max(maxError, stripMax)
        }
        let samples = Double(before.width * before.height * 3)
        guard squares > 0 else { return Stats(meanAbsError: 0, maxError: 0, psnr: .infinity) }
        return Stats(meanAbsError: sum / samples, maxError: Int(maxError), psnr: 10 * log10(255 * 255 * samples / squares))
    }

    // MARK: Internals

    private static let stripBytes = 1 << 20

    private static func buffers(_ before: CGImage, _ after: CGImage) -> ([UInt8], [UInt8])? {
        guard before.width == after.width, before.height == after.height, before.width > 0, before.height > 0,
              let left = rgba(before), let right = rgba(after) else { return nil }
        return (left, right)
    }

    /// Hands `body` the absolute difference of each strip as floats, the strip's byte range in `left`
    /// and `left` itself, so a caller can write its result back in place. `cancellable` checks for task
    /// cancellation before each strip.
    private static func forEachStrip(
        left: inout [UInt8], right: [UInt8], cancellable: Bool = false,
        _ body: (inout [Float], Range<Int>, inout [UInt8]) -> Void
    ) throws {
        var start = 0
        while start < left.count {
            if cancellable { try Task.checkCancellation() }
            let end = min(left.count, start + stripBytes)
            let length = vDSP_Length(end - start)
            var lhs = [Float](repeating: 0, count: end - start)
            var rhs = lhs
            left.withUnsafeBufferPointer { vDSP_vfltu8($0.baseAddress! + start, 1, &lhs, 1, length) }
            right.withUnsafeBufferPointer { vDSP_vfltu8($0.baseAddress! + start, 1, &rhs, 1, length) }
            vDSP_vsub(rhs, 1, lhs, 1, &lhs, 1, length)
            vDSP_vabs(lhs, 1, &lhs, 1, length)
            body(&lhs, start..<end, &left)
            start = end
        }
    }

    /// 8-bit sRGB, opaque RGBA (transparent pixels are composited on black, so alpha edits show as colour).
    private static func rgba(_ image: CGImage) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? bytes : nil
    }

    private static func makeImage(_ bytes: inout [UInt8], width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}
