import CoreGraphics
import Foundation

/// Structural similarity (SSIM) of two images, for picking the lowest quality that still looks the same.
public enum ImageSimilarity {
    /// Both images are compared as luma at most this many pixels on the long edge.
    static let maxEdge = 1024

    /// Mean SSIM of the luma of `first` and `second` over 8×8 windows (step 4), with the usual constants
    /// (K1 0.01, K2 0.03, range 255). 1 means identical. `second` is scaled to `first`'s comparison size;
    /// transparency is composited on white, as the JPEG encoder does.
    public static func ssim(_ first: CGImage, _ second: CGImage) -> Double {
        let (width, height) = comparisonSize(width: first.width, height: first.height)
        guard let lumaA = luma(first, width: width, height: height),
              let lumaB = luma(second, width: width, height: height) else { return 0 }
        return ssim(lumaA, lumaB, width: width, height: height)
    }

    /// The size an image of `width`×`height` is compared at: scaled down to at most `maxEdge` on the long edge.
    static func comparisonSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let scale = min(1, Double(maxEdge) / Double(max(width, height, 1)))
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// 8-bit luma of `image` drawn at `width`×`height` on white.
    static func luma(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: space,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(rect)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: rect)
            return true
        }
        return drawn ? pixels : nil
    }

    static func ssim(_ lhs: [UInt8], _ rhs: [UInt8], width: Int, height: Int) -> Double {
        let window = min(8, width, height)
        let step = max(1, window / 2)
        let count = Double(window * window)
        let stab1: Double = 0.01 * 255 * 0.01 * 255, stab2: Double = 0.03 * 255 * 0.03 * 255
        var total = 0.0
        var windows = 0
        var top = 0
        while top + window <= height {
            var left = 0
            while left + window <= width {
                var sumA = 0, sumB = 0, sumAA = 0, sumBB = 0, sumAB = 0
                for row in top..<(top + window) {
                    let base = row * width
                    for col in left..<(left + window) {
                        let valueA = Int(lhs[base + col]), valueB = Int(rhs[base + col])
                        sumA += valueA
                        sumB += valueB
                        sumAA += valueA * valueA
                        sumBB += valueB * valueB
                        sumAB += valueA * valueB
                    }
                }
                let meanA = Double(sumA) / count, meanB = Double(sumB) / count
                let varA = Double(sumAA) / count - meanA * meanA
                let varB = Double(sumBB) / count - meanB * meanB
                let cov = Double(sumAB) / count - meanA * meanB
                total += ((2 * meanA * meanB + stab1) * (2 * cov + stab2))
                    / ((meanA * meanA + meanB * meanB + stab1) * (varA + varB + stab2))
                windows += 1
                left += step
            }
            top += step
        }
        return windows > 0 ? total / Double(windows) : 1
    }
}
