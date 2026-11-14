import CoreGraphics
import Foundation
import ImageIO

/// Hand-built files for header-only checks: PNG headers that declare any size, and JPEGs whose EXIF
/// thumbnail belongs to a different picture.
enum HeaderFixtures {
    /// A PNG whose IHDR declares `width` × `height` (RGBA, 8 bit) with an empty IDAT: ImageIO reads the
    /// size from the header, but there are no pixels behind it.
    static func png(width: UInt32, height: UInt32) -> Data {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let header = bigEndian(width) + bigEndian(height) + [8, 6, 0, 0, 0]
        // zlib stream of zero bytes.
        let idat: [UInt8] = [0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]
        return Data(signature + chunk("IHDR", header) + chunk("IDAT", idat) + chunk("IEND", []))
    }

    /// A little-endian TIFF whose single strip declares `width` × `height` (8-bit grey, or RGBA with `alpha`)
    /// but holds two PackBits bytes. ImageIO reads such headers (its PNG reader refuses implausible ones itself).
    static func tiff(width: Int, height: Int, alpha: Bool = false) -> Data {
        // Tag, field type (3 short, 4 long), value.
        var entries: [[Int]] = [
            [256, 4, width], [257, 4, height], [258, 3, 8], [259, 3, 32_773], [262, 3, alpha ? 2 : 1], [273, 4, 0],
            [277, 3, alpha ? 4 : 1], [278, 4, height], [279, 4, 2],
        ]
        if alpha { entries.append([338, 3, 2]) }
        let dataOffset = 8 + 2 + entries.count * 12 + 4
        var bytes: [UInt8] = [0x49, 0x49] + little16(42) + little32(8) + little16(entries.count)
        for entry in entries {
            let (tag, type) = (entry[0], entry[1])
            let value = tag == 273 ? dataOffset : entry[2]
            bytes += little16(tag) + little16(type) + little32(1) + (type == 3 ? little16(value) + [0, 0] : little32(value))
        }
        // No next IFD; then one PackBits run: 128 zero bytes.
        return Data(bytes + little32(0) + [0x81, 0x00])
    }

    /// A JPEG of `body` that carries the APP segments (EXIF with its embedded thumbnail, XMP) of a JPEG
    /// written from `thumbnailSource` with `properties` and `xmp`: like a cropped photo whose editor kept
    /// the old thumbnail.
    static func jpegWithForeignThumbnail(body: CGImage, thumbnailSource: CGImage, properties: [String: Any],
                                         xmp: CGImageMetadata?) throws -> Data {
        var props = properties
        props[kCGImageDestinationEmbedThumbnail as String] = true
        let donor = try jpeg(thumbnailSource, properties: props, xmp: xmp)
        let target = try jpeg(body, properties: [:], xmp: nil)
        return Data([0xFF, 0xD8] + appSegments(of: donor).segments + appSegments(of: target).rest)
    }

    static func jpeg(_ image: CGImage, properties: [String: Any], xmp: CGImageMetadata?) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if let xmp {
            CGImageDestinationAddImageAndMetadata(dest, image, xmp, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    /// The APPn segments right after SOI, and everything after them.
    private static func appSegments(of data: Data) -> (segments: [UInt8], rest: [UInt8]) {
        let bytes = [UInt8](data)
        var index = 2
        var segments: [UInt8] = []
        while index + 3 < bytes.count, bytes[index] == 0xFF, (0xE0...0xEF).contains(bytes[index + 1]) {
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            segments += bytes[index..<(index + 2 + length)]
            index += 2 + length
        }
        return (segments, Array(bytes[index...]))
    }

    private static func little16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }

    private static func little32(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    private static func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let typeBytes = Array(type.utf8)
        return bigEndian(UInt32(body.count)) + typeBytes + body + bigEndian(crc32(typeBytes + body))
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}
