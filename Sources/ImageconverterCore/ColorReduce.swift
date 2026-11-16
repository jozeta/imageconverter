import CoreGraphics
import Foundation

/// The Color step's Reduce colors: at most N colours, from a palette found on a ≤ 512 px sample (median cut,
/// refined by weighted k-means) and mapped onto the full image, optionally Floyd–Steinberg dithered
/// (serpentine). Deterministic: the same image and settings always give the same pixels.
///
/// Works on 8-bit straight RGBA in the image's RGB colour space (sRGB for others); the result is 8-bit.
/// Alpha is kept as it is: fully transparent pixels stay transparent and never count toward the palette.
public enum ColorReduce {
    static let sampleSide = 512
    static let kMeansRounds = 8

    public static func apply(_ reduction: ColorReduction, to image: CGImage) throws -> CGImage {
        guard reduction.isEnabled else { return image }
        let step = StepKind.colorProfile.displayName
        let count = reduction.clampedCount
        var buffer = try PixelBuffer(image, step: step)
        if buffer.distinctColors(limit: count) != nil {
            // Already within the limit: the colours stay exactly as they are.
            return try buffer.makeImage(like: image, step: step)
        }
        let palette = try Self.palette(for: image, count: count, step: step)
        let table = NearestTable(palette: palette)
        if reduction.dither {
            buffer.ditherMap(table)
        } else {
            buffer.map(table)
        }
        return try buffer.makeImage(like: image, step: step)
    }

    /// The palette for `image`: at most `count` colours (fewer when the sample has fewer).
    static func palette(for image: CGImage, count: Int, step: String) throws -> [RGB] {
        let sample = try PixelBuffer(image, step: step, longSide: sampleSide)
        let entries = sample.histogram()
        guard entries.count > count else { return entries.map(\.color) }
        var palette = MedianCut.boxes(entries, count: count).map { MedianCut.mean(of: $0) }
        for _ in 0..<kMeansRounds {
            palette = KMeans.refine(palette, entries: entries)
        }
        // Deduplicated in order, so equal colours never take two slots.
        var seen = Set<RGB>()
        return palette.filter { seen.insert($0).inserted }
    }

    /// How far apart two colours look: weighted squared RGB distance (green counts most).
    @inline(__always)
    static func distance(_ red: Int, _ green: Int, _ blue: Int, _ color: RGB) -> Int {
        let dRed = red - Int(color.red)
        let dGreen = green - Int(color.green)
        let dBlue = blue - Int(color.blue)
        return 2 * dRed * dRed + 4 * dGreen * dGreen + 3 * dBlue * dBlue
    }
}

/// An 8-bit colour.
struct RGB: Hashable, Comparable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    var key: UInt32 { UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue) }

    static func < (lhs: RGB, rhs: RGB) -> Bool { lhs.key < rhs.key }
}

/// One histogram cell of the sample: its mean colour and how many pixels it holds.
struct WeightedColor {
    var red: Double
    var green: Double
    var blue: Double
    var weight: Double

    var color: RGB {
        RGB(red: UInt8(red.rounded()), green: UInt8(green.rounded()), blue: UInt8(blue.rounded()))
    }

    func channel(_ index: Int) -> Double { index == 0 ? red : index == 1 ? green : blue }
}

enum MedianCut {
    /// Splits the colours into at most `count` boxes: the box with the largest weighted spread is split at the
    /// weighted median of its widest channel, until there are `count` boxes or none can be split.
    static func boxes(_ entries: [WeightedColor], count: Int) -> [[WeightedColor]] {
        var boxes = [entries]
        var splits = [split(entries)]
        while boxes.count < count {
            var best: Int?
            for (index, candidate) in splits.enumerated() {
                guard let candidate else { continue }
                if best == nil || candidate.score > splits[best!]!.score { best = index }
            }
            guard let index = best, let plan = splits[index] else { break }
            let sorted = boxes[index].enumerated().sorted {
                let left = $0.element.channel(plan.channel)
                let right = $1.element.channel(plan.channel)
                return left != right ? left < right : $0.offset < $1.offset
            }.map(\.element)
            let total = sorted.reduce(0) { $0 + $1.weight }
            var running = 0.0
            var cut = 1
            for (position, entry) in sorted.enumerated() {
                running += entry.weight
                if running >= total / 2 { cut = min(max(position + 1, 1), sorted.count - 1); break }
            }
            boxes[index] = Array(sorted[..<cut])
            splits[index] = split(boxes[index])
            boxes.append(Array(sorted[cut...]))
            splits.append(split(boxes[boxes.count - 1]))
        }
        return boxes
    }

    /// The channel to split `box` on and how much splitting it is worth; nil when it can't be split.
    private static func split(_ box: [WeightedColor]) -> (channel: Int, score: Double)? {
        guard box.count > 1 else { return nil }
        var low = [Double](repeating: .infinity, count: 3)
        var high = [Double](repeating: -.infinity, count: 3)
        var weight = 0.0
        for entry in box {
            for channel in 0..<3 {
                low[channel] = min(low[channel], entry.channel(channel))
                high[channel] = max(high[channel], entry.channel(channel))
            }
            weight += entry.weight
        }
        // Green counts most, as in the distance.
        let spreads = (0..<3).map { (high[$0] - low[$0]) * [2.0, 4.0, 3.0][$0].squareRoot() }
        guard let channel = spreads.indices.max(by: { spreads[$0] < spreads[$1] }), spreads[channel] > 0 else {
            return nil
        }
        return (channel, spreads[channel] * weight.squareRoot())
    }

    static func mean(of box: [WeightedColor]) -> RGB {
        var sum = WeightedColor(red: 0, green: 0, blue: 0, weight: 0)
        for entry in box {
            sum.red += entry.red * entry.weight
            sum.green += entry.green * entry.weight
            sum.blue += entry.blue * entry.weight
            sum.weight += entry.weight
        }
        guard sum.weight > 0 else { return RGB(red: 0, green: 0, blue: 0) }
        return WeightedColor(red: sum.red / sum.weight, green: sum.green / sum.weight, blue: sum.blue / sum.weight,
                             weight: 1).color
    }
}

enum KMeans {
    /// One round: each colour joins its nearest palette entry, each entry moves to its members' weighted mean
    /// (an entry with no members stays where it is).
    static func refine(_ palette: [RGB], entries: [WeightedColor]) -> [RGB] {
        var sums = [WeightedColor](repeating: WeightedColor(red: 0, green: 0, blue: 0, weight: 0),
                                   count: palette.count)
        for entry in entries {
            let red = Int(entry.red.rounded())
            let green = Int(entry.green.rounded())
            let blue = Int(entry.blue.rounded())
            var nearest = 0
            var best = Int.max
            for (index, color) in palette.enumerated() {
                let distance = ColorReduce.distance(red, green, blue, color)
                if distance < best { best = distance; nearest = index }
            }
            sums[nearest].red += entry.red * entry.weight
            sums[nearest].green += entry.green * entry.weight
            sums[nearest].blue += entry.blue * entry.weight
            sums[nearest].weight += entry.weight
        }
        return zip(palette, sums).map { color, sum in
            guard sum.weight > 0 else { return color }
            return WeightedColor(red: sum.red / sum.weight, green: sum.green / sum.weight,
                                 blue: sum.blue / sum.weight, weight: 1).color
        }
    }
}

/// The nearest palette entry for every colour, at 6 bits per channel (cell centres), built in parallel.
struct NearestTable {
    let palette: [RGB]
    let cells: [UInt8]

    init(palette: [RGB]) {
        self.palette = palette
        var cells = [UInt8](repeating: 0, count: 1 << 18)
        cells.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: 64) { redCell in
                let red = redCell << 2 | 2
                for greenCell in 0..<64 {
                    let green = greenCell << 2 | 2
                    for blueCell in 0..<64 {
                        let blue = blueCell << 2 | 2
                        var nearest = 0
                        var best = Int.max
                        for (index, color) in palette.enumerated() {
                            let distance = ColorReduce.distance(red, green, blue, color)
                            if distance < best { best = distance; nearest = index }
                        }
                        base[redCell << 12 | greenCell << 6 | blueCell] = UInt8(nearest)
                    }
                }
            }
        }
        self.cells = cells
    }

    @inline(__always)
    func index(_ red: Int, _ green: Int, _ blue: Int) -> Int {
        Int(cells[(red >> 2) << 12 | (green >> 2) << 6 | blue >> 2])
    }
}
