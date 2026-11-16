import CoreGraphics
import Foundation

/// 8-bit straight (not premultiplied) RGBA pixels of an image, top row first, in memory it owns until
/// `makeImage` hands it to the image it makes (no copy).
final class PixelBuffer {
    let width: Int
    let height: Int
    let space: CGColorSpace
    let opaque: Bool
    /// Some pixel is fully transparent / partly transparent (always false when `opaque`).
    private(set) var hasTransparent = false
    private(set) var hasPartial = false
    let pixels: UnsafeMutablePointer<UInt8>
    var count: Int { width * height * 4 }
    private var handedOff = false

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
        let space = Self.workingSpace(for: image)
        let opaque = !ImageOps.hasAlpha(image)
        let info = opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
        pixels.initialize(repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: pixels, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space, bitmapInfo: info.rawValue) else {
            pixels.deallocate()
            throw ConversionError.processingFailed(step)
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        (self.width, self.height, self.space, self.opaque, self.pixels) = (width, height, space, opaque, pixels)
        if opaque {
            for index in stride(from: 3, to: count, by: 4) { pixels[index] = 255 }
        } else {
            unpremultiply()
        }
    }

    deinit {
        if !handedOff { pixels.deallocate() }
    }

    /// A copy of the bytes (tests).
    var bytes: [UInt8] { Array(UnsafeBufferPointer(start: pixels, count: count)) }

    /// The image's own RGB space (8-bit can hold it), else sRGB.
    static func workingSpace(for image: CGImage) -> CGColorSpace {
        if let own = image.colorSpace, own.model == .rgb, !CGColorSpaceUsesExtendedRange(own) { return own }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    private func unpremultiply() {
        for start in stride(from: 0, to: count, by: 4) {
            let alpha = Int(pixels[start + 3])
            if alpha == 255 { continue }
            if alpha == 0 { hasTransparent = true; continue }
            hasPartial = true
            for channel in 0..<3 {
                pixels[start + channel] = UInt8(min(255, (Int(pixels[start + channel]) * 255 + alpha / 2) / alpha))
            }
        }
    }

    /// The distinct colours of the visible pixels when there are at most `limit`, else nil (stops early).
    func distinctColors(limit: Int) -> Set<UInt32>? {
        var seen = Set<UInt32>(minimumCapacity: limit + 1)
        var last: UInt32 = .max
        for start in stride(from: 0, to: count, by: 4) where pixels[start + 3] > 0 {
            let key = UInt32(pixels[start]) << 16 | UInt32(pixels[start + 1]) << 8 | UInt32(pixels[start + 2])
            if key == last { continue }
            last = key
            if seen.insert(key).inserted, seen.count > limit { return nil }
        }
        return seen
    }

    /// The visible pixels in 5-bit cells (each with its exact mean colour), in cell order; every `every`-th pixel.
    func histogram(every: Int = 1) -> [WeightedColor] {
        var sums = [WeightedColor](repeating: WeightedColor(red: 0, green: 0, blue: 0, weight: 0), count: 1 << 15)
        for start in stride(from: 0, to: count, by: 4 * max(1, every)) where pixels[start + 3] > 0 {
            let red = Int(pixels[start])
            let green = Int(pixels[start + 1])
            let blue = Int(pixels[start + 2])
            let cell = (red >> 3) << 10 | (green >> 3) << 5 | blue >> 3
            sums[cell].red += Double(red)
            sums[cell].green += Double(green)
            sums[cell].blue += Double(blue)
            sums[cell].weight += 1
        }
        return sums.compactMap { sum in
            guard sum.weight > 0 else { return nil }
            return WeightedColor(red: sum.red / sum.weight, green: sum.green / sum.weight,
                                 blue: sum.blue / sum.weight, weight: sum.weight)
        }
    }

    /// Every visible pixel becomes its nearest palette colour (rows in parallel).
    func map(_ table: NearestTable) {
        let (width, height, base) = (self.width, self.height, self.pixels)
        let palette = table.palette
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

    /// Floyd–Steinberg, serpentine (left to right, then right to left). Transparent pixels neither take nor pass
    /// on error.
    func ditherMap(_ table: NearestTable) {
        let palette = table.palette
        // Error rows, offset by one pixel so columns -1 and `width` exist.
        let rowLength = (width + 2) * 3
        let here = UnsafeMutablePointer<Float>.allocate(capacity: rowLength)
        let below = UnsafeMutablePointer<Float>.allocate(capacity: rowLength)
        defer { here.deallocate(); below.deallocate() }
        here.initialize(repeating: 0, count: rowLength)
        below.initialize(repeating: 0, count: rowLength)
        var (current, next) = (here, below)
        for row in 0..<height {
            let forward = row % 2 == 0
            let ahead = forward ? 3 : -3
            next.update(repeating: 0, count: rowLength)
            for step in 0..<width {
                let column = forward ? step : width - 1 - step
                let pixel = pixels + (row * width + column) * 4
                guard pixel[3] > 0 else { continue }
                let slot = (column + 1) * 3
                let red = min(max(Float(pixel[0]) + current[slot], 0), 255)
                let green = min(max(Float(pixel[1]) + current[slot + 1], 0), 255)
                let blue = min(max(Float(pixel[2]) + current[slot + 2], 0), 255)
                let color = palette[table.index(Int(red.rounded()), Int(green.rounded()), Int(blue.rounded()))]
                pixel[0] = color.red
                pixel[1] = color.green
                pixel[2] = color.blue
                Self.spread(red - Float(color.red), at: slot, ahead: ahead, here: current, below: next)
                Self.spread(green - Float(color.green), at: slot + 1, ahead: ahead, here: current, below: next)
                Self.spread(blue - Float(color.blue), at: slot + 2, ahead: ahead, here: current, below: next)
            }
            swap(&current, &next)
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

    /// An 8-bit image of the pixels, premultiplied in place where alpha is partial; the memory moves to the image
    /// (the buffer can't be used afterwards). The result is registered with `ReducedImages` so a palette PNG can be
    /// written from it without decoding it again.
    func makeImage(like image: CGImage, step: String) throws -> CGImage {
        precondition(!handedOff, "PixelBuffer used after makeImage")
        if hasPartial {
            for start in stride(from: 0, to: count, by: 4) {
                let alpha = Int(pixels[start + 3])
                guard alpha > 0, alpha < 255 else { continue }
                for channel in 0..<3 { pixels[start + channel] = UInt8((Int(pixels[start + channel]) * alpha + 127) / 255) }
            }
        }
        let info = opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
        guard let provider = CGDataProvider(dataInfo: nil, data: pixels, size: count, releaseData: { _, data, _ in
            data.deallocate()
        }) else { throw ConversionError.processingFailed(step) }
        handedOff = true
        guard let result = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: info.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw ConversionError.processingFailed(step) }
        // An opaque gray image stays gray (its palette is grey); gray with alpha stays RGB so alpha is kept.
        if opaque, image.colorSpace?.model == .monochrome { return try ImageOps.convertColor(result, to: .gray) }
        ReducedImages.register(result, pixels: UnsafePointer(pixels), hasPartial: hasPartial)
        return result
    }
}

/// Images the Color step's Reduce colours made, with their pixel memory, so `IndexedPNG` can index them without
/// decoding them again. Entries hold the image weakly: one that is gone (or replaced by a later step's result)
/// is never found.
enum ReducedImages {
    struct Entry {
        weak var image: CGImage?
        /// Owned by the image's data provider; valid while the image lives.
        let pixels: UnsafePointer<UInt8>
        let hasPartial: Bool
    }

    private static let lock = NSLock()
    private static var entries: [ObjectIdentifier: Entry] = [:]

    static func register(_ image: CGImage, pixels: UnsafePointer<UInt8>, hasPartial: Bool) {
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { $0.value.image != nil }
        entries[ObjectIdentifier(image)] = Entry(image: image, pixels: pixels, hasPartial: hasPartial)
    }

    /// The entry for exactly this image (8-bit RGBA, `width * 4` bytes per row, alpha 0/255 unless `hasPartial`).
    static func entry(for image: CGImage) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[ObjectIdentifier(image)], entry.image === image else { return nil }
        return entry
    }
}
