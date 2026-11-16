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

    /// The largest pixel count a palette is learnt from when the sample was too sparse (see `palette`).
    static let fullScanLimit = 16_000_000

    public static func apply(_ reduction: ColorReduction, to image: CGImage) throws -> CGImage {
        guard reduction.isEnabled else { return image }
        let step = StepKind.colorProfile.displayName
        let buffer = try PixelBuffer(image, step: step)
        // Transparent pixels need a palette entry of their own in a palette PNG: leave room for it.
        let count = buffer.hasTransparent ? min(reduction.clampedCount, IndexedPNG.maxColors - 1)
                                          : reduction.clampedCount
        if buffer.distinctColors(limit: count) != nil {
            // Already within the limit (or nothing visible): the colours stay exactly as they are.
            return try buffer.makeImage(like: image, step: step)
        }
        let palette = try Self.palette(for: image, buffer: buffer, count: count, step: step)
        // Never index an empty palette; nothing visible to reduce.
        guard !palette.isEmpty else { return try buffer.makeImage(like: image, step: step) }
        let table = NearestTable(palette: palette)
        if reduction.dither {
            buffer.ditherMap(table)
        } else {
            buffer.map(table)
        }
        return try buffer.makeImage(like: image, step: step)
    }

    /// The palette: at most `count` colours (fewer when the image has fewer). Learnt from a ≤ 512 px sample; when
    /// that has fewer colour cells than `count` (a sparse image: a few dots on a wide transparent canvas shrink
    /// away), from the full image instead, every n-th pixel for at most `fullScanLimit` pixels, then every pixel.
    static func palette(for image: CGImage, buffer: PixelBuffer, count: Int, step: String) throws -> [RGB] {
        var entries = try PixelBuffer(image, step: step, longSide: sampleSide).histogram()
        if entries.count < count {
            let pixels = buffer.width * buffer.height
            let every = max(1, (pixels + fullScanLimit - 1) / fullScanLimit)
            entries = buffer.histogram(every: every)
            if entries.count < count, every > 1 { entries = buffer.histogram() }
        }
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

/// The nearest palette entry for every colour, at 6 bits per channel (the cell centre), built in parallel. A cell
/// that holds a palette colour is searched exactly instead (among the entries that can be nearest anywhere in it),
/// so close palette colours never collapse into one and every palette colour maps to itself.
struct NearestTable {
    let palette: [RGB]
    /// The entry index, or `exactFlag | n`: search `candidates[ranges[n]]`.
    let cells: [UInt16]
    private let candidates: [UInt8]
    private let ranges: [Range<Int>]
    private static let exactFlag: UInt16 = 0x8000
    /// The largest weighted distance from a cell's centre to a colour in it: sqrt((2 + 4 + 3) × 2²).
    private static let cellRadius = 6.0

    init(palette: [RGB]) {
        self.palette = palette
        var cells = [UInt16](repeating: 0, count: 1 << 18)
        cells.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: 64) { redCell in
                for greenCell in 0..<64 {
                    for blueCell in 0..<64 {
                        let nearest = Self.nearest(redCell << 2 | 2, greenCell << 2 | 2, blueCell << 2 | 2, in: palette)
                        base[redCell << 12 | greenCell << 6 | blueCell] = UInt16(nearest.index)
                    }
                }
            }
        }
        var candidates: [UInt8] = []
        var ranges: [Range<Int>] = []
        var marked = Set<Int>()
        for color in palette {
            let cell = Self.cell(Int(color.red), Int(color.green), Int(color.blue))
            guard marked.insert(cell).inserted else { continue }
            let (red, green, blue) = ((cell >> 12) << 2 | 2, (cell >> 6 & 63) << 2 | 2, (cell & 63) << 2 | 2)
            let reach = (Double(Self.nearest(red, green, blue, in: palette).distance).squareRoot() + 2 * Self.cellRadius)
            let start = candidates.count
            for (index, entry) in palette.enumerated()
            where Double(ColorReduce.distance(red, green, blue, entry)).squareRoot() <= reach {
                candidates.append(UInt8(index))
            }
            cells[cell] = Self.exactFlag | UInt16(ranges.count)
            ranges.append(start..<candidates.count)
        }
        self.cells = cells
        self.candidates = candidates
        self.ranges = ranges
    }

    private static func nearest(_ red: Int, _ green: Int, _ blue: Int, in palette: [RGB]) -> (index: Int, distance: Int) {
        var nearest = 0
        var best = Int.max
        for (index, color) in palette.enumerated() {
            let distance = ColorReduce.distance(red, green, blue, color)
            if distance < best { best = distance; nearest = index }
        }
        return (nearest, best)
    }

    @inline(__always)
    private static func cell(_ red: Int, _ green: Int, _ blue: Int) -> Int { (red >> 2) << 12 | (green >> 2) << 6 | blue >> 2 }

    @inline(__always)
    func index(_ red: Int, _ green: Int, _ blue: Int) -> Int {
        let value = cells[Self.cell(red, green, blue)]
        guard value & Self.exactFlag != 0 else { return Int(value) }
        var nearest = 0
        var best = Int.max
        for position in ranges[Int(value & ~Self.exactFlag)] {
            let index = Int(candidates[position])
            let distance = ColorReduce.distance(red, green, blue, palette[index])
            if distance < best { best = distance; nearest = index }
        }
        return nearest
    }
}
