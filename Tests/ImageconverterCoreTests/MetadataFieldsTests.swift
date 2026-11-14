import CoreGraphics
import ImageIO
import XCTest
@testable import ImageconverterCore

final class MetadataFieldsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestImages.tempDir().resolvingSymlinksInPath() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func decode(_ json: String) throws -> MetadataOptions {
        try JSONDecoder().decode(MetadataOptions.self, from: Data(json.utf8))
    }

    private func source(_ name: String = "src.jpg", properties: [String: Any] = [:],
                        xmp: [(String, Any)] = []) throws -> URL {
        try MetadataTestSupport.source(root.appendingPathComponent(name), properties: properties, xmp: xmp)
    }

    // MARK: decoding

    func testOldMetadataJSONDecodes() throws {
        let old = try decode(#"{"isEnabled":true,"removeLocation":true,"removeCamera":true,"artist":"A"}"#)
        XCTAssertEqual(old.location, .remove)
        XCTAssertTrue(old.removeCamera)
        XCTAssertEqual(old.artist, "A")
        XCTAssertNil(old.title)
        XCTAssertNil(old.keywords)
        XCTAssertEqual(old.keywordsMode, .add)
        XCTAssertEqual(old.dateTaken, .keep)
        XCTAssertFalse(old.setFileDates)
        XCTAssertEqual(old.custom, [])
        XCTAssertFalse(old.removeAuthor || old.removeThumbnail || old.removeIPTC || old.removeXMP)
        XCTAssertEqual(old.keepWhenRemovingAll, [])
        XCTAssertEqual(try decode(#"{"removeLocation":false}"#).location, .keep)
        // Older files without the key had location removal on by default.
        XCTAssertEqual(try decode("{}").location, .remove)
    }

    func testRoundTripOfEveryNewField() throws {
        var options = MetadataOptions(isEnabled: true, location: .set(latitude: 1.5, longitude: -2, altitude: 30))
        options.title = "T"
        options.keywords = ["a", "b"]
        options.keywordsMode = .replace
        options.dateTaken = .shift(seconds: -90)
        options.setFileDates = true
        options.custom = [MetadataField(namespace: .iptc, key: "Credit", value: "C")]
        options.removeAuthor = true
        options.removeThumbnail = true
        options.removeIPTC = true
        options.removeXMP = true
        options.keepWhenRemovingAll = [.copyright, .dateTaken]
        let data = try JSONEncoder().encode(options)
        XCTAssertEqual(try JSONDecoder().decode(MetadataOptions.self, from: data), options)
        options.dateTaken = .set(Date(timeIntervalSinceReferenceDate: 600_000_000))
        options.location = .remove
        XCTAssertEqual(try JSONDecoder().decode(MetadataOptions.self, from: JSONEncoder().encode(options)), options)
    }

    func testInvalidGPSRejectedOnDecode() throws {
        for bad in [#"{"mode":"set","latitude":91,"longitude":0}"#, #"{"mode":"set","latitude":0,"longitude":-180.5}"#,
                    #"{"mode":"set","latitude":10,"longitude":10,"altitude":1e12}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(LocationEdit.self, from: Data(bad.utf8)), bad)
            // Lenient like the other fields, but the original position must not survive: it becomes `.remove`.
            XCTAssertEqual(try decode(#"{"isEnabled":true,"location":\#(bad)}"#).location, .remove, bad)
        }
        let good = try JSONDecoder().decode(LocationEdit.self,
                                            from: Data(#"{"mode":"set","latitude":-90,"longitude":180}"#.utf8))
        XCTAssertEqual(good, .set(latitude: -90, longitude: 180, altitude: nil))
        XCTAssertFalse(LocationEdit.isValid(latitude: .nan, longitude: 0, altitude: nil))
        let badDate = try decode(#"{"dateTaken":{"mode":"shift","seconds":99999999999},"keywordsMode":"x"}"#)
        XCTAssertEqual(badDate.dateTaken, .keep)
        XCTAssertEqual(badDate.keywordsMode, .add)
    }

    func testUnknownCustomKeyDroppedOnDecode() throws {
        let json = #"""
        {"isEnabled":true,"custom":[
          {"namespace":"iptc","key":"Credit","value":"ok"},
          {"namespace":"iptc","key":"Keywords","value":"not offered"},
          {"namespace":"exif","key":"GPSLatitude","value":"1"},
          {"namespace":"xmp","key":"dc:title","value":"ok\u0007 too"},
          {"namespace":"martian","key":"dc:title","value":"x"},
          {"namespace":"xmp","key":"evil:thing","value":"x"}
        ]}
        """#
        let options = try decode(json)
        XCTAssertEqual(options.custom, [MetadataField(namespace: .iptc, key: "Credit", value: "ok"),
                                        MetadataField(namespace: .xmp, key: "dc:title", value: "ok too")])
        let long = String(repeating: "x", count: 5000)
        XCTAssertEqual(MetadataField(namespace: .exif, key: "Artist", value: long).value.count, 2000)
        XCTAssertTrue(MetadataFields.isWritable(.exif, "BodySerialNumber"))
        XCTAssertFalse(MetadataFields.isWritable(.xmp, "Credit"))
    }

    func testKeywordsDeduplicated() async throws {
        XCTAssertEqual(MetadataFields.normalizedKeywords(["Sun", " sun ", "SUN", "", "Sea\n", "sea"]), ["Sun", "Sea"])
        let many = (0..<100).map { "k\($0)" }
        XCTAssertEqual(MetadataFields.normalizedKeywords(many).count, 64)
        let long = String(repeating: "y", count: 100)
        XCTAssertEqual(MetadataFields.normalizedKeywords([long]).first?.count, 64)

        let url = try source(properties: [kCGImagePropertyIPTCDictionary as String:
                                            [kCGImagePropertyIPTCKeywords as String: ["Beach", "sun"]]])
        var options = MetadataTestSupport.active()
        options.keywords = ["beach", "Sun", "Sea", "sea"]
        options.keywordsMode = .add
        let written = try await MetadataTestSupport.convert(url, options: options, root: root)
        XCTAssertEqual(written.sub(kCGImagePropertyIPTCDictionary)?[kCGImagePropertyIPTCKeywords as String] as? [String],
                       ["Beach", "sun", "Sea"])
        XCTAssertEqual(written.xmpArray("dc:subject"), ["Beach", "sun", "Sea"])
    }

    func testSummaryNamesNewEdits() {
        var options = MetadataOptions(removeLocation: false)
        options.removeAuthor = true
        options.removeXMP = true
        options.title = "T"
        options.dateTaken = .shift(seconds: 60)
        options.custom = [MetadataField(namespace: .iptc, key: "Credit", value: "C")]
        options.setFileDates = true
        XCTAssertEqual(options.summary, "strip author + XMP · set title, shifted date, 1 field, file dates")
        options = MetadataOptions(removeAll: true, location: .set(latitude: 1, longitude: 2, altitude: nil))
        options.keepWhenRemovingAll = [.copyright, .orientation, .dateTaken]
        XCTAssertEqual(options.summary, "strip all except copyright, date · set GPS")
    }

    // MARK: custom fields

    func testCustomIPTCAndXMPFieldsWritten() async throws {
        for format in MetadataTestSupport.richFormats {
            let url = try source("custom-\(format).jpg")
            var options = MetadataTestSupport.active()
            options.custom = [
                MetadataField(namespace: .iptc, key: "Credit", value: "CREDITX"),
                MetadataField(namespace: .iptc, key: "City", value: "CITYX"),
                MetadataField(namespace: .iptc, key: "Byline", value: "BYLINEX"),
                MetadataField(namespace: .xmp, key: "xmpRights:UsageTerms", value: "TERMSX"),
                MetadataField(namespace: .xmp, key: "Iptc4xmpCore:CountryCode", value: "SE"),
                MetadataField(namespace: .exif, key: "LensModel", value: "LENSX"),
                MetadataField(namespace: .exif, key: "Software", value: "SOFTX"),
            ]
            let written = try await MetadataTestSupport.convert(url, options: options, format: format, root: root)
            let iptc = written.sub(kCGImagePropertyIPTCDictionary)
            XCTAssertEqual(iptc?[kCGImagePropertyIPTCCredit as String] as? String, "CREDITX", "\(format)")
            XCTAssertEqual(iptc?[kCGImagePropertyIPTCCity as String] as? String, "CITYX", "\(format)")
            XCTAssertEqual(iptc?[kCGImagePropertyIPTCByline as String] as? [String], ["BYLINEX"], "\(format)")
            XCTAssertEqual(written.xmp("xmpRights:UsageTerms"), "TERMSX", "\(format)")
            XCTAssertEqual(written.xmp("Iptc4xmpCore:CountryCode"), "SE", "\(format)")
            XCTAssertEqual(written.xmp("photoshop:Credit"), "CREDITX", "\(format)")
            XCTAssertEqual(written.sub(kCGImagePropertyExifDictionary)?[kCGImagePropertyExifLensModel as String] as? String,
                           "LENSX", "\(format)")
            XCTAssertEqual(written.sub(kCGImagePropertyTIFFDictionary)?[kCGImagePropertyTIFFSoftware as String] as? String,
                           "SOFTX", "\(format)")
        }
    }

    // MARK: dates

    private let original = "2020:01:02 03:04:05"

    private var datedProps: [String: Any] {
        [kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifDateTimeOriginal as String: original,
                                                   kCGImagePropertyExifDateTimeDigitized as String: original],
         kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFDateTime as String: original]]
    }

    private func dates(_ written: WrittenFile) -> [String?] {
        let exif = written.sub(kCGImagePropertyExifDictionary)
        // With an XMP packet ImageIO keeps the TIFF date as xmp:ModifyDate.
        let modified = written.xmp("xmp:ModifyDate").map {
            String($0.prefix(19)).replacingOccurrences(of: "-", with: ":").replacingOccurrences(of: "T", with: " ")
        }
        return [exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String,
                exif?[kCGImagePropertyExifDateTimeDigitized as String] as? String,
                written.sub(kCGImagePropertyTIFFDictionary)?[kCGImagePropertyTIFFDateTime as String] as? String ?? modified]
    }

    func testDateSetAndShift() async throws {
        var components = DateComponents(year: 2024, month: 6, day: 30, hour: 23, minute: 59, second: 58)
        components.timeZone = .current
        let setDate = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: components))
        for format in MetadataTestSupport.richFormats {
            let (type, ext) = MetadataTestSupport.type(of: format)
            let url = try MetadataTestSupport.source(
                root.appendingPathComponent("dated-\(format).\(ext)"), type: type, properties: datedProps,
                xmp: [("xmp:CreateDate", "2020-01-02T03:04:05"), ("photoshop:DateCreated", "2020-01-02T03:04:05")])
            var options = MetadataTestSupport.active()
            options.dateTaken = .shift(seconds: 3600)
            var written = try await MetadataTestSupport.convert(url, options: options, format: format, root: root)
            XCTAssertEqual(dates(written), Array(repeating: "2020:01:02 04:04:05", count: 3), "\(format)")
            assertIPTCDate(written, "20200102", "040405", "\(format)")
            XCTAssertEqual(written.xmp("xmp:CreateDate")?.prefix(19), "2020-01-02T04:04:05", "\(format)")
            XCTAssertEqual(written.xmp("photoshop:DateCreated")?.prefix(19), "2020-01-02T04:04:05", "\(format)")

            options.dateTaken = .set(setDate)
            written = try await MetadataTestSupport.convert(url, options: options, format: format, root: root)
            XCTAssertEqual(dates(written), Array(repeating: "2024:06:30 23:59:58", count: 3), "\(format)")
            XCTAssertEqual(written.xmp("xmp:CreateDate")?.prefix(19), "2024-06-30T23:59:58", "\(format)")
            XCTAssertEqual(written.xmp("photoshop:DateCreated")?.prefix(19), "2024-06-30T23:59:58", "\(format)")
            assertIPTCDate(written, "20240630", "235958", "\(format)")
        }
    }

    /// HEIC keeps no IPTC date of its own (photoshop:DateCreated holds it); where there is one it must match.
    private func assertIPTCDate(_ written: WrittenFile, _ date: String, _ time: String, _ label: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let iptc = written.sub(kCGImagePropertyIPTCDictionary)
        if let written = iptc?[kCGImagePropertyIPTCDateCreated as String] as? String {
            XCTAssertEqual(written, date, label, file: file, line: line)
        }
        if let written = iptc?[kCGImagePropertyIPTCTimeCreated as String] as? String {
            XCTAssertEqual(written, time, label, file: file, line: line)
        }
    }

    func testShiftWithoutDateLeavesNone() async throws {
        let url = try source()
        var options = MetadataTestSupport.active()
        options.dateTaken = .shift(seconds: 3600)
        let written = try await MetadataTestSupport.convert(url, options: options, root: root)
        XCTAssertEqual(dates(written), [nil, nil, nil])
        XCTAssertNil(written.sub(kCGImagePropertyIPTCDictionary)?[kCGImagePropertyIPTCDateCreated as String])
        XCTAssertNil(written.xmp("xmp:CreateDate"))
    }

    func testFileDatesFollowDateTaken() async throws {
        let url = try source(properties: datedProps)
        var options = MetadataTestSupport.active()
        options.dateTaken = .shift(seconds: 60)
        options.setFileDates = true
        var written = try await MetadataTestSupport.convert(url, options: options, root: root)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let expected = try XCTUnwrap(formatter.date(from: "2020:01:02 03:05:05"))
        var values = try written.url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        XCTAssertEqual(values.creationDate, expected)
        XCTAssertEqual(values.contentModificationDate, expected)

        // No date taken: the output keeps the source's dates.
        let plain = try source("plain.jpg")
        let sourceCreated = Date(timeIntervalSince1970: 1_500_000_000)
        let sourceModified = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.creationDate: sourceCreated, .modificationDate: sourceModified],
                                              ofItemAtPath: plain.path)
        options.dateTaken = .keep
        written = try await MetadataTestSupport.convert(plain, options: options, root: root)
        values = try written.url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        XCTAssertEqual(values.creationDate, sourceCreated)
        XCTAssertEqual(values.contentModificationDate, sourceModified)
    }
}
