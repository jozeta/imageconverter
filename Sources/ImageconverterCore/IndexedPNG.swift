import CoreGraphics
import Foundation

/// A small open-addressing map from a colour key to its palette index (at most 256 keys).
struct PaletteLookup {
    private var keys = [UInt32](repeating: .max, count: 1024)
    private var values = [UInt16](repeating: 0, count: 1024)

    private func slot(_ key: UInt32) -> Int { Int((key &* 2_654_435_761) >> 22) }

    func index(of key: UInt32) -> Int? {
        var slot = slot(key)
        while keys[slot] != .max {
            if keys[slot] == key { return Int(values[slot]) }
            slot = (slot + 1) & 1023
        }
        return nil
    }

    mutating func insert(_ key: UInt32, index: Int) {
        var slot = slot(key)
        while keys[slot] != .max { slot = (slot + 1) & 1023 }
        keys[slot] = key
        values[slot] = UInt16(index)
    }
}

/// Writes a palette (indexed) PNG when an image has at most 256 colours and only fully opaque or fully
/// transparent pixels. ImageIO writes an indexed PNG for an image in an indexed colour space, but can't carry
/// alpha in one, so transparency is added afterwards as a `tRNS` chunk for the one transparent palette entry.
/// Only sRGB images: ImageIO writes no colour profile for a palette PNG, which readers take as sRGB.
enum IndexedPNG {
    /// An image in an indexed colour space, its colour table, and the palette index of transparent pixels.
    struct Indexed {
        let image: CGImage
        let table: [UInt8]
        let transparentIndex: Int?
    }

    enum Plan {
        case indexed(Indexed)
        /// Written as a normal PNG; the reason is said in the report.
        case notIndexed(reason: String)
        /// Written as a normal PNG without a note (a gray image: already one byte per pixel).
        case plain
    }

    static let maxColors = 256
    static let changedAfterReduce = "a step after Reduce colours changed the pixels"
    /// An extra output's own size change blends neighbouring palette colours into new ones.
    static let resizedByOutput = "this output's size change added colours"

    static func note(_ reason: String) -> String { "Not written as an indexed PNG: \(reason)" }

    /// The indexed version of `image`, or why it can't be one. Only the Color step's own result is indexed
    /// (`ReducedImages`), from the memory it already holds: the image is never decoded again.
    static func plan(_ image: CGImage) -> Plan {
        if image.colorSpace?.model == .monochrome { return .plain }
        guard let entry = ReducedImages.entry(for: image) else { return .notIndexed(reason: changedAfterReduce) }
        if entry.hasPartial { return .notIndexed(reason: "it has semi-transparent pixels") }
        guard let space = image.colorSpace, isSRGB(space) else {
            return .notIndexed(reason: "its colour profile can't be kept in a palette PNG (only sRGB can)")
        }
        let pixelCount = image.width * image.height
        let indices = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount)
        guard let (table, transparentIndex) = palette(of: entry.pixels, count: pixelCount, into: indices) else {
            indices.deallocate()
            return .notIndexed(reason: "it has more than \(maxColors) colours")
        }
        guard let provider = CGDataProvider(dataInfo: nil, data: indices, size: pixelCount, releaseData: { _, data, _ in
            data.deallocate()
        }) else {
            indices.deallocate()
            return .notIndexed(reason: "no palette image could be made")
        }
        guard let indexedSpace = CGColorSpace(indexedBaseSpace: space, last: max(0, table.count / 3 - 1),
                                              colorTable: table),
              let indexed = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 8,
                                    bytesPerRow: image.width, space: indexedSpace,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false,
                                    intent: .defaultIntent) else {
            return .notIndexed(reason: "no palette image could be made")
        }
        return .indexed(Indexed(image: indexed, table: table, transparentIndex: transparentIndex))
    }

    /// The colour table (RGB triples, in first-seen order) and the transparent entry's index, filling each pixel's
    /// palette index into `indices`; nil when there are more than `maxColors` entries. `pixels` is 8-bit RGBA with
    /// alpha 0 or 255.
    private static func palette(of pixels: UnsafePointer<UInt8>, count: Int,
                                into indices: UnsafeMutablePointer<UInt8>) -> ([UInt8], Int?)? {
        var lookup = PaletteLookup()
        var table: [UInt8] = []
        var transparentIndex: Int?
        var lastKey = UInt32.max
        var lastIndex: UInt8 = 0
        for pixel in 0..<count {
            let start = pixel * 4
            // Transparent pixels share one key outside the 24-bit colours.
            let key = pixels[start + 3] == 0 ? 1 << 24
                : UInt32(pixels[start]) << 16 | UInt32(pixels[start + 1]) << 8 | UInt32(pixels[start + 2])
            if key == lastKey { indices[pixel] = lastIndex; continue }
            let index: Int
            if let known = lookup.index(of: key) {
                index = known
            } else {
                guard table.count / 3 < maxColors else { return nil }
                index = table.count / 3
                lookup.insert(key, index: index)
                if key == 1 << 24 {
                    transparentIndex = index
                    table += [0, 0, 0]
                } else {
                    table += [pixels[start], pixels[start + 1], pixels[start + 2]]
                }
            }
            (lastKey, lastIndex) = (key, UInt8(index))
            indices[pixel] = UInt8(index)
        }
        return (table, transparentIndex)
    }

    static func isSRGB(_ space: CGColorSpace) -> Bool {
        guard let name = space.name as String? else { return false }
        return name == CGColorSpace.sRGB as String || name == "kCGColorSpaceDeviceRGB"
    }

    /// Checks that `png` is a palette PNG with exactly `table` as its palette (ImageIO keeps it as given) and adds
    /// a `tRNS` chunk making `transparentIndex` fully transparent. Nil when the file isn't as expected.
    static func finished(_ png: Data, table: [UInt8], transparentIndex: Int?) -> Data? {
        let bytes = [UInt8](png)
        guard bytes.count > 8, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 else { return nil }
        var offset = 8
        while offset + 12 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8
                | Int(bytes[offset + 3])
            let type = String(bytes: bytes[offset + 4..<offset + 8], encoding: .ascii) ?? ""
            let end = offset + 12 + length
            guard end <= bytes.count, type != "tRNS", type != "IDAT" else { return nil }
            if type == "PLTE" {
                guard Array(bytes[offset + 8..<end - 4]) == table else { return nil }
                guard let transparentIndex else { return png }
                let alphas = [UInt8](repeating: 255, count: transparentIndex) + [0]
                return Data(Array(bytes[..<end]) + chunk("tRNS", alphas) + Array(bytes[end...]))
            }
            offset = end
        }
        return nil
    }

    /// A PNG chunk: length, type, data, CRC-32 of type and data.
    static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let body = Array(type.utf8) + data
        let length = UInt32(data.count)
        let crc = crc32(body)
        return [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
            + body + [UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)]
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
