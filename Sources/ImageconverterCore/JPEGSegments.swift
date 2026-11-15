import Foundation

/// The marker segments a lossless metadata copy of a JPEG may keep (`LosslessMetadata`). ImageIO's copy replaces
/// the EXIF, XMP and IPTC it knows about but passes other segments through (a Photoshop preview in APP13, the
/// EXIF thumbnail, comments, vendor APPn blocks, MPF images after the end), so the written bytes are rebuilt from
/// an allowlist:
/// - APP0 `JFIF` (not `JFXX`, which holds a thumbnail), APP1 `Exif` with its thumbnail (IFD1) cut off, APP1 XMP
///   and extended XMP, APP2 `ICC_PROFILE`, APP14 `Adobe` (colour transform), APP13 `Photoshop 3.0` reduced to
///   its IPTC-NAA resource (0x0404), dropped when nothing is left;
/// - the structural markers: DQT, DHT, DAC, DRI, DNL, SOFn and SOS with its entropy-coded data copied as is
///   (restart markers included), so the scan data stays byte-identical;
/// - nothing after the first end-of-image marker.
/// COM and every other APPn are dropped. Anything it can't parse (a truncated segment, an unknown marker, no
/// start of scan or end of image, an EXIF thumbnail that can't be cut off cleanly) gives nil, and the caller
/// re-encodes instead.
///
/// With `iptcFrom`, the copy's APP13 segments are replaced by those of `reference` (the re-encode of the same
/// metadata, filtered the same way): ImageIO's copy keeps a source's IPTC block as it was when it has no digest
/// (0x0425) and doesn't derive IPTC dates from EXIF, while its re-encode does both. IPTC holds no pixel
/// dimensions, so the tiny reference's block is the one the re-encode would write.
enum JPEGSegments {
    static func filtered(_ data: Data, iptcFrom reference: Data? = nil) -> Data? {
        var iptc: IPTCSource = .own
        if let reference {
            guard let segments = filtered(reference).map(app13Segments) else { return nil }
            iptc = .pending(segments)
        }
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var out: [UInt8] = [0xFF, 0xD8]
        out.reserveCapacity(bytes.count)
        var index = 2
        var scanned = false
        while let segment = segment(in: bytes, at: index) {
            if segment.marker == 0xD9 { return scanned ? Data(out + [0xFF, 0xD9]) : nil }
            index = segment.end
            if iptc.place(before: segment.marker, into: &out) { continue }
            guard append(segment, of: bytes, to: &out) else { return nil }
            if segment.marker == 0xDA {
                scanned = true
                guard let scanEnd = entropyEnd(bytes, from: index) else { return nil }
                out += bytes[index..<scanEnd]
                index = scanEnd
            }
        }
        return nil
    }

    private struct Segment {
        let marker: UInt8
        let start: Int
        let end: Int
    }

    /// Appends `segment` as its disposition says; false when it is invalid.
    private static func append(_ segment: Segment, of bytes: [UInt8], to out: inout [UInt8]) -> Bool {
        let payload = Array(bytes[(segment.start + 4)..<segment.end])
        switch disposition(marker: segment.marker, payload: payload) {
        case .invalid: return false
        case .drop: return true
        case .keep: out += bytes[segment.start..<segment.end]
        case .replace(let newPayload):
            let length = newPayload.count + 2
            guard length <= 0xFFFF else { return false }
            out += [0xFF, segment.marker, UInt8(length >> 8), UInt8(length & 0xFF)] + newPayload
        }
        return true
    }

    /// The marker segment at `index` (after any fill bytes): its marker, where it starts and ends. The end of image
    /// has no length. Nil when there is no valid marker or the length runs past the data.
    private static func segment(in bytes: [UInt8], at start: Int) -> Segment? {
        var index = start
        guard index < bytes.count, bytes[index] == 0xFF else { return nil }
        while index + 1 < bytes.count, bytes[index + 1] == 0xFF { index += 1 }
        guard index + 1 < bytes.count else { return nil }
        let marker = bytes[index + 1]
        if marker == 0xD9 { return Segment(marker: marker, start: index, end: index + 2) }
        guard index + 4 <= bytes.count else { return nil }
        let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
        guard length >= 2, index + 2 + length <= bytes.count else { return nil }
        return Segment(marker: marker, start: index, end: index + 2 + length)
    }

    /// Where the APP13 (IPTC) segments come from: the copy's own (filtered), or the reference's, written once
    /// where the copy's first APP13 was or after the APP segments, with every APP13 of the copy dropped.
    private enum IPTCSource {
        case own
        case pending([UInt8])
        case placed

        /// Handles the reference's segments before a segment with `marker`; true when that segment is dropped.
        mutating func place(before marker: UInt8, into out: inout [UInt8]) -> Bool {
            if case .own = self { return false }
            let isAPP13 = marker == 0xED
            if case .pending(let segments) = self, isAPP13 || !(0xE0...0xEF ~= marker || marker == 0xFE) {
                out += segments
                self = .placed
            }
            return isAPP13
        }
    }

    /// The APP13 segments of a filtered JPEG (all before its first scan).
    private static func app13Segments(_ data: Data) -> [UInt8] {
        let bytes = [UInt8](data)
        var segments: [UInt8] = []
        var index = 2
        while index + 4 <= bytes.count, bytes[index] == 0xFF, bytes[index + 1] != 0xDA {
            let end = index + 2 + (Int(bytes[index + 2]) << 8 | Int(bytes[index + 3]))
            if bytes[index + 1] == 0xED { segments += bytes[index..<min(end, bytes.count)] }
            index = end
        }
        return segments
    }

    private enum Disposition {
        case keep, drop, invalid
        case replace([UInt8])
    }

    private static let xmpPrefix = Array("http://ns.adobe.com/xap/1.0/\0".utf8)
    private static let extendedXMPPrefix = Array("http://ns.adobe.com/xmp/extension/\0".utf8)
    private static let exifPrefix = Array("Exif\0\0".utf8)
    private static let photoshopPrefix = Array("Photoshop 3.0\0".utf8)

    /// The APPn segments kept as they are, by the prefix of their payload.
    private static let keptAPP: [UInt8: [[UInt8]]] = [
        0xE0: [Array("JFIF\0".utf8)], 0xE1: [xmpPrefix, extendedXMPPrefix], 0xE2: [Array("ICC_PROFILE\0".utf8)],
        0xEE: [Array("Adobe".utf8)],
    ]

    /// DHT, DAC, the frame headers (not the reserved JPG 0xC8), DQT, DNL, DRI, SOS.
    private static let structural: Set<UInt8> = Set(Array(0xC0...0xC7) + Array(0xC9...0xCF) + Array(0xDA...0xDD))

    private static func disposition(marker: UInt8, payload: [UInt8]) -> Disposition {
        if marker == 0xE1, payload.starts(with: exifPrefix) {
            guard let tiff = withoutThumbnail(Array(payload[exifPrefix.count...])) else { return .invalid }
            return .replace(exifPrefix + tiff)
        }
        if marker == 0xED, payload.starts(with: photoshopPrefix) {
            guard let resources = iptcResources(Array(payload[photoshopPrefix.count...])) else { return .invalid }
            return resources.isEmpty ? .drop : .replace(photoshopPrefix + resources)
        }
        if (0xE0...0xEF).contains(marker) || marker == 0xFE {
            return keptAPP[marker]?.contains(where: { payload.starts(with: $0) }) == true ? .keep : .drop
        }
        return structural.contains(marker) ? .keep : .invalid
    }

    /// Where the entropy-coded data starting at `start` ends: at the first marker that isn't a stuffed 0xFF00 or
    /// a restart marker. Nil when the data runs to the end of the file.
    private static func entropyEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        while index + 1 < bytes.count {
            if bytes[index] == 0xFF {
                let next = bytes[index + 1]
                if next == 0x00 || (0xD0...0xD7).contains(next) {
                    index += 2
                    continue
                }
                return index
            }
            index += 1
        }
        return nil
    }

    // MARK: Photoshop image resources

    /// The IPTC-NAA resources (0x0404) of an APP13 Photoshop block, as they were; the rest is dropped. Nil when
    /// a resource runs past the block.
    private static func iptcResources(_ block: [UInt8]) -> [UInt8]? {
        var kept: [UInt8] = []
        var index = 0
        while index < block.count {
            // Zero padding at the end of the block.
            if block[index...].allSatisfy({ $0 == 0 }) { break }
            guard index + 7 <= block.count else { return nil }
            let start = index
            let resourceID = Int(block[index + 4]) << 8 | Int(block[index + 5])
            let nameLength = Int(block[index + 6])
            var cursor = index + 6 + nameLength + 1
            if (nameLength + 1) % 2 == 1 { cursor += 1 }
            guard cursor + 4 <= block.count else { return nil }
            let size = block[cursor..<(cursor + 4)].reduce(0) { $0 << 8 | Int($1) }
            cursor += 4
            guard cursor + size <= block.count else { return nil }
            index = cursor + size
            // Odd data is padded to an even length, though ImageIO writes the next resource right after it.
            if size % 2 == 1, index < block.count, block[index] == 0, !block[index...].starts(with: "8BIM".utf8) {
                index += 1
            }
            if block[start..<(start + 4)].elementsEqual("8BIM".utf8), resourceID == 0x0404 {
                kept += block[start..<index]
            }
        }
        return kept
    }

    // MARK: EXIF thumbnail

    private static let exifIFDTag = 0x8769
    private static let gpsIFDTag = 0x8825
    private static let interopIFDTag = 0xA005
    private static let subIFDsTag = 0x014A

    /// The EXIF TIFF block with IFD1 (the thumbnail) cut off: IFD0's next pointer set to 0 and the block
    /// truncated where IFD1 starts. Only when everything IFD0, EXIF, GPS and interoperability IFDs point at lies
    /// before IFD1 and the thumbnail data after it. Unchanged without IFD1; nil otherwise.
    static func withoutThumbnail(_ tiff: [UInt8]) -> [UInt8]? {
        guard let reader = TIFFReader(Data(tiff)), let ifd0 = reader.read(4, 4), let count0 = reader.read(ifd0, 2)
        else { return nil }
        let nextField = ifd0 + 2 + count0 * 12
        guard let ifd1 = reader.read(nextField, 4) else { return nil }
        if ifd1 == 0 { return tiff }
        guard ifd1 >= 8, ifd1 < tiff.count else { return nil }
        var visited: Set<Int> = []
        guard ifdFits(ifd0, before: ifd1, reader: reader, visited: &visited),
              thumbnailFollows(ifd1, reader: reader) else { return nil }
        var cut = Array(tiff[..<ifd1])
        for offset in nextField..<(nextField + 4) { cut[offset] = 0 }
        return cut
    }

    /// Bytes per value of each TIFF field type.
    private static func typeSize(_ type: Int) -> Int? {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9, 11, 13: return 4
        case 5, 10, 12: return 8
        default: return nil
        }
    }

    /// Whether the IFD at `offset`, its out-of-line values and the EXIF/GPS/interoperability IFDs it points to
    /// all end before `limit`.
    private static func ifdFits(_ offset: Int, before limit: Int, reader: TIFFReader, visited: inout Set<Int>)
        -> Bool {
        guard offset >= 8, visited.insert(offset).inserted, visited.count <= 8,
              let count = reader.read(offset, 2), count <= 1000, offset + 2 + count * 12 + 4 <= limit else {
            return false
        }
        for entry in 0..<count {
            let base = offset + 2 + entry * 12
            guard let tag = reader.read(base, 2), let type = reader.read(base + 2, 2),
                  let valueCount = reader.read(base + 4, 4), let unit = typeSize(type), tag != subIFDsTag else {
                return false
            }
            let size = unit * valueCount
            if size > 4 {
                guard let valueOffset = reader.read(base + 8, 4), valueOffset >= 8, valueOffset + size <= limit
                else { return false }
            }
            if [exifIFDTag, gpsIFDTag, interopIFDTag].contains(tag) {
                guard let pointer = reader.entryValue(at: base),
                      ifdFits(pointer, before: limit, reader: reader, visited: &visited) else { return false }
            }
        }
        return true
    }

    /// Whether IFD1's thumbnail data (JPEG or strips) lies at or after IFD1, so cutting there removes it.
    private static func thumbnailFollows(_ ifd1: Int, reader: TIFFReader) -> Bool {
        guard let count = reader.read(ifd1, 2), count <= 1000 else { return false }
        for entry in 0..<count {
            let base = ifd1 + 2 + entry * 12
            guard let tag = reader.read(base, 2) else { return false }
            guard tag == 0x0201 || tag == 0x0111 else { continue }
            guard reader.read(base + 4, 4) == 1, let pointer = reader.entryValue(at: base), pointer >= ifd1 else {
                return false
            }
        }
        return true
    }
}
