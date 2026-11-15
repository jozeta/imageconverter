import XCTest
@testable import ImageconverterCore

/// `JPEGSegments.filtered` on hand-built byte arrays: only the allowlisted segments are kept, APP13 keeps only
/// its IPTC resource, the EXIF thumbnail (IFD1) is cut off, and anything it can't parse gives nil.
final class JPEGSegmentsTests: XCTestCase {
    // MARK: Building blocks

    static func be16(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
    static func be32(_ value: Int) -> [UInt8] { be16(value >> 16) + be16(value & 0xFFFF) }

    static func segment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
        [0xFF, marker] + be16(payload.count + 2) + payload
    }

    static func resource(_ id: Int, _ payload: [UInt8], name: [UInt8] = []) -> [UInt8] {
        // Pascal name padded to an even length (length byte included), data padded to even.
        var block = Array("8BIM".utf8) + be16(id) + [UInt8(name.count)] + name
        if (name.count + 1) % 2 == 1 { block.append(0) }
        block += be32(payload.count) + payload
        if payload.count % 2 == 1 { block.append(0) }
        return block
    }

    static func app13(_ resources: [UInt8]) -> [UInt8] {
        segment(0xED, Array("Photoshop 3.0".utf8) + [0] + resources)
    }

    static let jfif = segment(0xE0, Array("JFIF".utf8) + [0, 1, 1, 0, 0, 1, 0, 1, 0, 0])
    static let dqt = segment(0xDB, [0] + [UInt8](repeating: 1, count: 64))
    static let sof = segment(0xC0, [8] + be16(8) + be16(8) + [1, 1, 0x11, 0])
    static let dht = segment(0xC4, [0] + [UInt8](repeating: 0, count: 15) + [1] + [0])
    /// A scan header and entropy-coded bytes with a stuffed 0xFF00 and a restart marker inside.
    static let scan: [UInt8] = segment(0xDA, [1, 1, 0, 0, 63, 0]) + [0x12, 0xFF, 0x00, 0x34, 0xFF, 0xD0, 0x56]
    static let eoi: [UInt8] = [0xFF, 0xD9]

    static func jpeg(_ metadata: [UInt8], trailer: [UInt8] = []) -> Data {
        Data([0xFF, 0xD8] + metadata + dqt + sof + dht + scan + eoi + trailer)
    }

    private func contains(_ data: Data, _ text: String) -> Bool { data.range(of: Data(text.utf8)) != nil }

    // MARK: Tests

    func testKeepsTheStructureAndScanDataByteIdentical() throws {
        let source = Self.jpeg(Self.jfif)
        XCTAssertEqual(JPEGSegments.filtered(source), source)
    }

    func testAPP13KeepsOnlyTheIPTCResource() throws {
        let iptc: [UInt8] = [0x1C, 2, 80] + Self.be16(6) + Array("BYLINE".utf8)
        let thumbnail = Self.resource(0x040C, Array("THUMBSECRET".utf8))
        let other = Self.resource(0x0BB7, Array("IRBSECRET".utf8), name: Array("n".utf8))
        let source = Self.jpeg(Self.jfif + Self.app13(thumbnail + Self.resource(0x0404, iptc) + other))
        let filtered = try XCTUnwrap(JPEGSegments.filtered(source))
        XCTAssertEqual(filtered, Self.jpeg(Self.jfif + Self.app13(Self.resource(0x0404, iptc))))
        XCTAssertFalse(contains(filtered, "THUMBSECRET"))
        XCTAssertFalse(contains(filtered, "IRBSECRET"))
        XCTAssertTrue(contains(filtered, "BYLINE"))
    }

    func testAPP13WithoutIPTCIsDropped() throws {
        let source = Self.jpeg(Self.jfif + Self.app13(Self.resource(0x040C, Array("THUMBSECRET".utf8))))
        XCTAssertEqual(JPEGSegments.filtered(source), Self.jpeg(Self.jfif))
    }

    func testCommentsUnknownAPPSegmentsAndJFXXAreDropped() throws {
        let source = Self.jpeg(Self.jfif + Self.segment(0xFE, Array("COMSECRET".utf8))
                               + Self.segment(0xEB, Array("JP\0APP11SECRET".utf8))
                               + Self.segment(0xE0, Array("JFXX\0".utf8) + [0x10] + Array("JFXXTHUMB".utf8))
                               + Self.segment(0xE2, Array("MPF\0MPFSECRET".utf8))
                               + Self.segment(0xE1, Array("http://ns.adobe.com/other\0".utf8)))
        XCTAssertEqual(JPEGSegments.filtered(source), Self.jpeg(Self.jfif))
    }

    func testAllowlistedSegmentsAreKept() throws {
        let xmp = Self.segment(0xE1, Array("http://ns.adobe.com/xap/1.0/\0<x:xmpmeta/>".utf8))
        let extended = Self.segment(0xE1, Array("http://ns.adobe.com/xmp/extension/\0EXT".utf8))
        let icc = Self.segment(0xE2, Array("ICC_PROFILE\0".utf8) + [1, 1, 0, 0])
        let adobe = Self.segment(0xEE, Array("Adobe".utf8) + [0, 100, 0, 0, 0, 0, 1])
        let dri = Self.segment(0xDD, Self.be16(4))
        let source = Self.jpeg(Self.jfif + xmp + extended + icc + adobe + dri)
        XCTAssertEqual(JPEGSegments.filtered(source), source)
    }

    func testBytesAfterTheEndOfImageAreDropped() throws {
        let trailer = Self.jpeg([]) + Data("MPFSECONDIMAGE".utf8)
        let source = Self.jpeg(Self.jfif, trailer: [UInt8](trailer))
        XCTAssertEqual(JPEGSegments.filtered(source), Self.jpeg(Self.jfif))
    }

    func testProgressiveScansAndTablesBetweenThemAreKept() throws {
        let second = Self.dht + Self.scan
        let source = Data([0xFF, 0xD8] + Self.jfif + Self.dqt + Self.sof + Self.dht + Self.scan + second + Self.eoi)
        XCTAssertEqual(JPEGSegments.filtered(source), source)
    }

    func testMalformedInputGivesNil() {
        var truncated = [UInt8](Self.jpeg(Self.jfif))
        truncated.removeLast(4)
        XCTAssertNil(JPEGSegments.filtered(Data(truncated)), "no EOI")
        // A segment whose length runs past the end.
        XCTAssertNil(JPEGSegments.filtered(Data([0xFF, 0xD8, 0xFF, 0xE1, 0x40, 0x00, 0x45])))
        XCTAssertNil(JPEGSegments.filtered(Data([0xFF, 0xD8] + Self.jfif + Self.eoi)), "no start of scan")
        XCTAssertNil(JPEGSegments.filtered(Data([0x89, 0x50, 0x4E, 0x47])), "not a JPEG")
        XCTAssertNil(JPEGSegments.filtered(Data([0xFF, 0xD8] + Self.jfif + [0x00, 0x01] + Self.scan + Self.eoi)),
                     "garbage between segments")
        XCTAssertNil(JPEGSegments.filtered(Self.jpeg(Self.app13(Array("8BIM".utf8) + [4, 4, 0, 0, 0, 0, 0x40]))),
                     "truncated resource")
        XCTAssertNil(JPEGSegments.filtered(Self.jpeg(Self.segment(0xF0, [1, 2]))), "reserved marker")
    }

    // MARK: EXIF thumbnail

    /// A big-endian TIFF block: IFD0 (Make, and a pointer to IFD1 when `thumbnail` is given) then IFD1 with
    /// its JPEG thumbnail at the end.
    static func exif(thumbnail: [UInt8]?, thumbnailFirst: Bool = false) -> [UInt8] {
        let make = Array("MAKE\0\0".utf8)
        // IFD0 at 8: 1 entry (Make, ASCII 6 → out of line at 26), next pointer, then the value.
        let ifd0Size = 2 + 12 + 4
        let makeOffset = 8 + ifd0Size
        let ifd1Offset = makeOffset + make.count
        func ifd0(next: Int) -> [UInt8] {
            be16(1) + be16(0x010F) + be16(2) + be32(make.count) + be32(makeOffset) + be32(next)
        }
        var tiff: [UInt8] = [0x4D, 0x4D, 0, 42] + be32(8)
        guard let thumbnail else { return Array("Exif\0\0".utf8) + tiff + ifd0(next: 0) + make }
        let ifd1Size = 2 + 3 * 12 + 4
        let dataOffset = thumbnailFirst ? makeOffset : ifd1Offset + ifd1Size
        let ifd1 = be16(3) + be16(0x0103) + be16(3) + be32(1) + be16(6) + [0, 0]
            + be16(0x0201) + be16(4) + be32(1) + be32(dataOffset)
            + be16(0x0202) + be16(4) + be32(1) + be32(thumbnail.count) + be32(0)
        if thumbnailFirst {
            // The thumbnail sits before IFD1, where the Make value would be: cutting IFD1 off can't remove it.
            tiff += ifd0(next: makeOffset + thumbnail.count) + thumbnail + ifd1
        } else {
            tiff += ifd0(next: ifd1Offset) + make + ifd1 + thumbnail
        }
        return Array("Exif\0\0".utf8) + tiff
    }

    func testTheEXIFThumbnailIsCutOff() throws {
        let thumbnail = [0xFF, 0xD8] + Array("THUMBDATA".utf8) + [0xFF, 0xD9]
        let source = Self.jpeg(Self.jfif + Self.segment(0xE1, Self.exif(thumbnail: thumbnail)))
        let filtered = try XCTUnwrap(JPEGSegments.filtered(source))
        XCTAssertEqual(filtered, Self.jpeg(Self.jfif + Self.segment(0xE1, Self.exif(thumbnail: nil))))
        XCTAssertFalse(contains(filtered, "THUMBDATA"))
        XCTAssertTrue(contains(filtered, "MAKE"))
    }

    func testAThumbnailThatCannotBeCutOffGivesNil() {
        let thumbnail = [0xFF, 0xD8] + Array("THUMBDATA".utf8) + [0xFF, 0xD9]
        let source = Self.jpeg(Self.segment(0xE1, Self.exif(thumbnail: thumbnail, thumbnailFirst: true)))
        XCTAssertNil(JPEGSegments.filtered(source))
    }

    func testAnEXIFBlockWithoutAThumbnailIsUnchanged() throws {
        let source = Self.jpeg(Self.jfif + Self.segment(0xE1, Self.exif(thumbnail: nil)))
        XCTAssertEqual(JPEGSegments.filtered(source), source)
    }
}

extension JPEGSegmentsTests {
    /// ImageIO writes the next resource right after odd-length data, without the pad byte.
    func testUnpaddedResourcesAsImageIOWritesThem() throws {
        let iptc: [UInt8] = [0x1C, 2, 80] + Self.be16(4) + Array("ABCD".utf8)
        let first = Array("8BIM".utf8) + Self.be16(0x0404) + [0, 0] + Self.be32(iptc.count) + iptc
        let digest = Array("8BIM".utf8) + Self.be16(0x0425) + [0, 0] + Self.be32(4) + [1, 2, 3, 4]
        let source = Self.jpeg(Self.app13(first + digest + [0]))
        XCTAssertEqual(JPEGSegments.filtered(source), Self.jpeg(Self.app13(first)))
    }
}

extension JPEGSegmentsTests {
    private static func iptc(_ text: String) -> [UInt8] {
        app13(resource(0x0404, [0x1C, 2, 80] + be16(text.utf8.count) + Array(text.utf8)))
    }

    func testIPTCIsTakenFromTheReference() throws {
        let copy = Self.jpeg(Self.jfif + Self.iptc("OLDBYLINE") + Self.segment(0xFE, Array("C".utf8)))
        let reference = Self.jpeg(Self.jfif + Self.app13(Self.resource(0x0404, Array("NEW".utf8))
                                                         + Self.resource(0x0425, [1, 2, 3, 4])))
        XCTAssertEqual(JPEGSegments.filtered(copy, iptcFrom: reference),
                       Self.jpeg(Self.jfif + Self.app13(Self.resource(0x0404, Array("NEW".utf8)))))
    }

    func testReferenceIPTCIsInsertedAfterTheAPPSegmentsWhenTheCopyHasNone() throws {
        let copy = Self.jpeg(Self.jfif)
        let reference = Self.jpeg(Self.iptc("NEW"))
        XCTAssertEqual(JPEGSegments.filtered(copy, iptcFrom: reference), Self.jpeg(Self.jfif + Self.iptc("NEW")))
    }

    func testCopyIPTCIsDroppedWhenTheReferenceHasNone() throws {
        let copy = Self.jpeg(Self.jfif + Self.iptc("OLDBYLINE"))
        XCTAssertEqual(JPEGSegments.filtered(copy, iptcFrom: Self.jpeg(Self.jfif)), Self.jpeg(Self.jfif))
        XCTAssertNil(JPEGSegments.filtered(copy, iptcFrom: Data([0xFF, 0xD8])), "unreadable reference")
    }
}
