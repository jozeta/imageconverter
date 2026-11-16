import CoreGraphics
import Foundation

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
    }

    static let maxColors = 256

    static func note(_ reason: String) -> String { "Not written as an indexed PNG: \(reason)" }

    /// The indexed version of `image`, or why it can't be one.
    static func plan(_ image: CGImage) -> Plan {
        guard image.bitsPerComponent == 8, let space = image.colorSpace, space.model == .rgb,
              !CGColorSpaceUsesExtendedRange(space) else {
            return .notIndexed(reason: "the image isn't 8-bit RGB")
        }
        guard isSRGB(space) else {
            return .notIndexed(reason: "its color profile can't be kept in a palette PNG (only sRGB can)")
        }
        guard let pixels = try? PixelBuffer(image, step: StepKind.colorProfile.displayName) else {
            return .notIndexed(reason: "its pixels couldn't be read")
        }
        var indices = [UInt8](repeating: 0, count: pixels.width * pixels.height)
        let found = palette(of: pixels, into: &indices)
        guard case .success(let (table, transparentIndex)) = found else {
            if case .failure(let failure) = found { return .notIndexed(reason: failure.reason) }
            return .notIndexed(reason: "no palette image could be made")
        }
        guard let indexedSpace = CGColorSpace(indexedBaseSpace: pixels.space, last: max(0, table.count / 3 - 1),
                                              colorTable: table),
              let provider = CGDataProvider(data: Data(indices) as CFData),
              let indexed = CGImage(width: pixels.width, height: pixels.height, bitsPerComponent: 8, bitsPerPixel: 8,
                                    bytesPerRow: pixels.width, space: indexedSpace,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false,
                                    intent: .defaultIntent) else {
            return .notIndexed(reason: "no palette image could be made")
        }
        return .indexed(Indexed(image: indexed, table: table, transparentIndex: transparentIndex))
    }

    private struct Failure: Error { let reason: String }

    /// The colour table (RGB triples, in first-seen order) and the transparent entry's index; `indices` gets
    /// each pixel's palette index.
    private static func palette(of pixels: PixelBuffer, into indices: inout [UInt8])
        -> Result<([UInt8], Int?), Failure> {
        var palette: [UInt32: UInt8] = [:]
        var table: [UInt8] = []
        var transparentIndex: Int?
        let transparentKey = UInt32.max
        return pixels.bytes.withUnsafeBufferPointer { bytes in
            var lastKey = UInt32.max - 1
            var lastIndex: UInt8 = 0
            for pixel in 0..<indices.count {
                let start = pixel * 4
                let alpha = bytes[start + 3]
                if alpha != 0, alpha != 255 { return .failure(Failure(reason: "it has semi-transparent pixels")) }
                let key = alpha == 0 ? transparentKey
                    : UInt32(bytes[start]) << 16 | UInt32(bytes[start + 1]) << 8 | UInt32(bytes[start + 2])
                if key == lastKey { indices[pixel] = lastIndex; continue }
                let index: UInt8
                if let known = palette[key] {
                    index = known
                } else {
                    guard palette.count < maxColors else {
                        return .failure(Failure(reason: "it has more than \(maxColors) colors (a later step added some)"))
                    }
                    index = UInt8(palette.count)
                    palette[key] = index
                    if alpha == 0 {
                        transparentIndex = Int(index)
                        table += [0, 0, 0]
                    } else {
                        table += [bytes[start], bytes[start + 1], bytes[start + 2]]
                    }
                }
                (lastKey, lastIndex) = (key, index)
                indices[pixel] = index
            }
            return .success((table, transparentIndex))
        }
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
