import CoreGraphics
import Foundation

/// 8-bit straight (not premultiplied) RGBA pixels of an image, top row first.
struct PixelBuffer {
    let width: Int
    let height: Int
    let space: CGColorSpace
    let opaque: Bool
    var bytes: [UInt8]

    /// The image drawn at full size, or scaled so its long side is at most `longSide`.
    init(_ image: CGImage, step: String, longSide: Int? = nil) throws {
        var width = image.width
        var height = image.height
        if let longSide, max(width, height) > longSide {
            let scale = Double(longSide) / Double(max(width, height))
            width = max(1, Int((Double(width) * scale).rounded()))
            height = max(1, Int((Double(height) * scale).rounded()))
        }
        guard width >= 1, height >= 1, width <= ImageOps.maxPixels / height else {
            throw ConversionError.processingFailed(step)
        }
        space = Self.workingSpace(for: image)
        opaque = !ImageOps.hasAlpha(image)
        self.width = width
        self.height = height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        let info = opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space, bitmapInfo: info.rawValue) else {
                return false
            }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ConversionError.processingFailed(step) }
        if opaque {
            for index in stride(from: 3, to: bytes.count, by: 4) { bytes[index] = 255 }
        } else {
            unpremultiply()
        }
    }

    /// The image's own RGB space (8-bit can hold it), else sRGB.
    static func workingSpace(for image: CGImage) -> CGColorSpace {
        if let own = image.colorSpace, own.model == .rgb, !CGColorSpaceUsesExtendedRange(own) { return own }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    private mutating func unpremultiply() {
        bytes.withUnsafeMutableBufferPointer { pixels in
            for start in stride(from: 0, to: pixels.count, by: 4) {
                let alpha = Int(pixels[start + 3])
                guard alpha > 0, alpha < 255 else { continue }
                for channel in 0..<3 {
                    pixels[start + channel] = UInt8(min(255, (Int(pixels[start + channel]) * 255 + alpha / 2) / alpha))
                }
            }
        }
    }

    /// The distinct colours of the visible pixels when there are at most `limit`, else nil (stops early).
    func distinctColors(limit: Int) -> Set<UInt32>? {
        var seen = Set<UInt32>(minimumCapacity: limit + 1)
        var last: UInt32 = .max
        let found: Bool = bytes.withUnsafeBufferPointer { pixels in
            for start in stride(from: 0, to: pixels.count, by: 4) where pixels[start + 3] > 0 {
                let key = UInt32(pixels[start]) << 16 | UInt32(pixels[start + 1]) << 8 | UInt32(pixels[start + 2])
                if key == last { continue }
                last = key
                if seen.insert(key).inserted, seen.count > limit { return false }
            }
            return true
        }
        return found ? seen : nil
    }

    /// The visible pixels in 5-bit cells (each with its exact mean colour), in cell order.
    func histogram() -> [WeightedColor] {
        var sums = [WeightedColor](repeating: WeightedColor(red: 0, green: 0, blue: 0, weight: 0), count: 1 << 15)
        bytes.withUnsafeBufferPointer { pixels in
            for start in stride(from: 0, to: pixels.count, by: 4) where pixels[start + 3] > 0 {
                let red = Int(pixels[start])
                let green = Int(pixels[start + 1])
                let blue = Int(pixels[start + 2])
                let cell = (red >> 3) << 10 | (green >> 3) << 5 | blue >> 3
                sums[cell].red += Double(red)
                sums[cell].green += Double(green)
                sums[cell].blue += Double(blue)
                sums[cell].weight += 1
            }
        }
        return sums.compactMap { sum in
            guard sum.weight > 0 else { return nil }
            return WeightedColor(red: sum.red / sum.weight, green: sum.green / sum.weight,
                                 blue: sum.blue / sum.weight, weight: sum.weight)
        }
    }

    /// Every visible pixel becomes its nearest palette colour (rows in parallel).
    mutating func map(_ table: NearestTable) {
        let (width, height) = (self.width, self.height)
        let palette = table.palette
        bytes.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            let bands = min(height, max(1, ProcessInfo.processInfo.activeProcessorCount * 4))
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                for row in height * band / bands..<height * (band + 1) / bands {
                    var pixel = base + row * width * 4
                    for _ in 0..<width {
                        if pixel[3] > 0 {
                            let color = palette[table.index(Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))]
                            pixel[0] = color.red
                            pixel[1] = color.green
                            pixel[2] = color.blue
                        }
                        pixel += 4
                    }
                }
            }
        }
    }

    /// Floyd–Steinberg, serpentine (left to right, then right to left). Transparent pixels neither take nor pass
    /// on error.
    mutating func ditherMap(_ table: NearestTable) {
        let (width, height) = (self.width, self.height)
        let palette = table.palette
        // Error rows, offset by one pixel so columns -1 and `width` exist.
        var current = [Float](repeating: 0, count: (width + 2) * 3)
        var next = current
        bytes.withUnsafeMutableBufferPointer { buffer in
            let pixels = buffer.baseAddress!
            for row in 0..<height {
                let forward = row % 2 == 0
                let ahead = forward ? 3 : -3
                current.withUnsafeMutableBufferPointer { currentBuffer in
                    next.withUnsafeMutableBufferPointer { nextBuffer in
                        let here = currentBuffer.baseAddress!
                        let below = nextBuffer.baseAddress!
                        for index in 0..<nextBuffer.count { below[index] = 0 }
                        for step in 0..<width {
                            let column = forward ? step : width - 1 - step
                            let pixel = pixels + (row * width + column) * 4
                            guard pixel[3] > 0 else { continue }
                            let slot = (column + 1) * 3
                            let red = min(max(Float(pixel[0]) + here[slot], 0), 255)
                            let green = min(max(Float(pixel[1]) + here[slot + 1], 0), 255)
                            let blue = min(max(Float(pixel[2]) + here[slot + 2], 0), 255)
                            let color = palette[table.index(Int(red.rounded()), Int(green.rounded()),
                                                            Int(blue.rounded()))]
                            pixel[0] = color.red
                            pixel[1] = color.green
                            pixel[2] = color.blue
                            Self.spread(red - Float(color.red), at: slot, ahead: ahead, here: here, below: below)
                            Self.spread(green - Float(color.green), at: slot + 1, ahead: ahead, here: here, below: below)
                            Self.spread(blue - Float(color.blue), at: slot + 2, ahead: ahead, here: here, below: below)
                        }
                    }
                }
                swap(&current, &next)
            }
        }
    }

    /// Floyd–Steinberg weights: 7/16 ahead, 3/16 behind below, 5/16 below, 1/16 ahead below.
    @inline(__always)
    private static func spread(_ error: Float, at slot: Int, ahead: Int, here: UnsafeMutablePointer<Float>,
                               below: UnsafeMutablePointer<Float>) {
        here[slot + ahead] += error * (7 / 16)
        below[slot - ahead] += error * (3 / 16)
        below[slot] += error * (5 / 16)
        below[slot + ahead] += error * (1 / 16)
    }

    /// An 8-bit image of the pixels (premultiplied again where alpha is partial).
    func makeImage(like image: CGImage, step: String) throws -> CGImage {
        var pixels = bytes
        if !opaque {
            for start in stride(from: 0, to: pixels.count, by: 4) {
                let alpha = Int(pixels[start + 3])
                guard alpha < 255 else { continue }
                for channel in 0..<3 { pixels[start + channel] = UInt8((Int(pixels[start + channel]) * alpha + 127) / 255) }
            }
        }
        let info = opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let result = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: info.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw ConversionError.processingFailed(step) }
        // An opaque gray image stays gray (its palette is grey); gray with alpha stays RGB so alpha is kept.
        if opaque, image.colorSpace?.model == .monochrome { return try ImageOps.convertColor(result, to: .gray) }
        return result
    }
}
