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

    /// Per-channel absolute difference times `amplify`, clamped, on black. Nil when the sizes differ.
    public static func render(before: CGImage, after: CGImage, amplify: Double = 4) -> CGImage? {
        guard var diff = differences(before, after) else { return nil }
        let length = vDSP_Length(diff.values.count)
        var factor = Float(max(0, amplify))
        var low: Float = 0
        var high: Float = 255
        vDSP_vsmul(diff.values, 1, &factor, &diff.values, 1, length)
        vDSP_vclip(diff.values, 1, &low, &high, &diff.values, 1, length)
        var out = [UInt8](repeating: 0, count: diff.values.count)
        vDSP_vfixru8(diff.values, 1, &out, 1, length)
        // The alpha lane is not a difference; the result is always opaque.
        for index in 0..<(diff.width * diff.height) { out[index * 4 + 3] = 255 }
        return makeImage(&out, width: diff.width, height: diff.height)
    }

    /// Error figures over the RGB channels. Mismatched sizes give a maximal error and a 0 dB PSNR.
    public static func stats(before: CGImage, after: CGImage) -> Stats {
        guard let diff = differences(before, after) else {
            return Stats(meanAbsError: 255, maxError: 255, psnr: 0)
        }
        var sum = 0.0
        var squares = 0.0
        var maxError: Float = 0
        for index in 0..<(diff.width * diff.height) {
            for channel in 0..<3 {
                let value = diff.values[index * 4 + channel]
                sum += Double(value)
                squares += Double(value * value)
                maxError = max(maxError, value)
            }
        }
        let samples = Double(diff.width * diff.height * 3)
        guard samples > 0, squares > 0 else { return Stats(meanAbsError: 0, maxError: 0, psnr: .infinity) }
        let mse = squares / samples
        return Stats(meanAbsError: sum / samples, maxError: Int(maxError), psnr: 10 * log10(255 * 255 / mse))
    }

    // MARK: Internals

    private struct Delta {
        var values: [Float]
        let width: Int
        let height: Int
    }

    private static func differences(_ before: CGImage, _ after: CGImage) -> Delta? {
        guard before.width == after.width, before.height == after.height, before.width > 0, before.height > 0,
              let left = rgba(before), let right = rgba(after) else { return nil }
        let count = left.count
        var lhs = [Float](repeating: 0, count: count)
        var rhs = [Float](repeating: 0, count: count)
        vDSP_vfltu8(left, 1, &lhs, 1, vDSP_Length(count))
        vDSP_vfltu8(right, 1, &rhs, 1, vDSP_Length(count))
        var delta = [Float](repeating: 0, count: count)
        vDSP_vsub(rhs, 1, lhs, 1, &delta, 1, vDSP_Length(count))
        vDSP_vabs(delta, 1, &delta, 1, vDSP_Length(count))
        return Delta(values: delta, width: before.width, height: before.height)
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
