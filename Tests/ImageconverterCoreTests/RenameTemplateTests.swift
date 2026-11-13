import ImageIO
import XCTest
@testable import ImageconverterCore

final class RenameTemplateTests: XCTestCase {
    private var savedZone: TimeZone!

    override func setUp() {
        super.setUp()
        savedZone = NSTimeZone.default
    }

    override func tearDown() {
        NSTimeZone.default = savedZone
        super.tearDown()
    }

    private func gmtDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "GMT")!
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    private func context(
        name: String = "IMG_1", date: Date? = nil, make: String? = nil, model: String? = nil,
        lens: String? = nil, iso: Int? = nil, counter: Int = 1
    ) -> RenameContext {
        RenameContext(
            name: name, ext: "jpg", format: "JPEG", folder: "Trip", date: date, make: make,
            model: model, lens: lens, iso: iso, width: 800, height: 600, counter: counter)
    }

    private func header(exifDate: String?) -> ImageHeader {
        var exif: [String: Any] = [:]
        if let exifDate { exif[kCGImagePropertyExifDateTimeOriginal as String] = exifDate }
        exif[kCGImagePropertyExifLensModel as String] = "Lens X"
        exif[kCGImagePropertyExifISOSpeedRatings as String] = [400, 800]
        let tiff: [String: Any] = [
            kCGImagePropertyTIFFMake as String: "Apple",
            kCGImagePropertyTIFFModel as String: "iPhone 15 Pro",
        ]
        return ImageHeader(width: 10, height: 10, properties: [
            kCGImagePropertyExifDictionary as String: exif,
            kCGImagePropertyTIFFDictionary as String: tiff,
        ])
    }

    private func make(_ header: ImageHeader?, creation: Date? = nil) -> RenameContext {
        RenameContext.make(
            source: URL(fileURLWithPath: "/tmp/Trip/IMG_1.heic"), header: header,
            outputSize: (800, 600), format: .jpeg, counter: 7, fileCreationDate: creation)
    }

    func testExamplePattern() {
        let ctx = context(date: gmtDate(2024, 6, 1, 23, 30), model: "iPhone 15 Pro", counter: 7)
        XCTAssertEqual(
            RenameTemplate("{date:yyyy-MM-dd}_{camera}_{counter:000}").render(ctx),
            "2024-06-01_iPhone 15 Pro_007")
    }

    func testDayNotShiftedByTimeZone() {
        NSTimeZone.default = TimeZone(secondsFromGMT: 10 * 3600)!
        let ctx = make(header(exifDate: "2024:06:01 23:30:00"))
        XCTAssertEqual(RenameTemplate("{date}").render(ctx), "2024-06-01")
        XCTAssertEqual(RenameTemplate("{time}").render(ctx), "233000")
    }

    func testFallbackToFileDate() {
        NSTimeZone.default = TimeZone(secondsFromGMT: 10 * 3600)!
        // 2024-06-01 23:30 in UTC+10 is 13:30 GMT; the wall clock must be kept.
        let creation = gmtDate(2024, 6, 1, 13, 30)
        XCTAssertEqual(RenameTemplate("{date}").render(make(header(exifDate: nil), creation: creation)), "2024-06-01")
        XCTAssertEqual(RenameTemplate("{date}").render(make(nil, creation: creation)), "2024-06-01")
    }

    func testMalformedExifDate() {
        let creation = gmtDate(2023, 1, 2, 12, 0)
        NSTimeZone.default = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(RenameTemplate("{date}").render(make(header(exifDate: "garbage"), creation: creation)), "2023-01-02")
    }

    func testHostileValuesSanitised() {
        let out = RenameTemplate("{camera}").render(context(model: "../../x:y\u{0}\u{7}\n"))
        XCTAssertFalse(out.contains("/"))
        XCTAssertFalse(out.contains(":"))
        XCTAssertFalse(out.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        XCTAssertFalse(out.isEmpty)
        XCTAssertFalse(out.hasPrefix("."))
        XCTAssertFalse(out.hasPrefix("-") || out.hasPrefix("_") || out.hasPrefix(" "))
        XCTAssertTrue(out.hasSuffix("x-y"))
    }

    func testEmptyTokensCollapseSeparators() {
        XCTAssertEqual(RenameTemplate("{camera}_{name}").render(context()), "IMG_1")
        XCTAssertEqual(RenameTemplate("{name}_{camera}_{counter}").render(context()), "IMG_1_1")
        XCTAssertEqual(RenameTemplate("{name}__{counter}").render(context()), "IMG_1__1")
        XCTAssertEqual(RenameTemplate("{date} - {name}").render(context(date: gmtDate(2024, 6, 1, 1, 1))), "2024-06-01 - IMG_1")
        XCTAssertEqual(RenameTemplate("{date} - {name}").render(context()), "IMG_1")
        XCTAssertEqual(RenameTemplate("{make}{camera}-{name}").render(context()), "IMG_1")
    }

    func testEmptyResultFallsBackToName() {
        XCTAssertEqual(RenameTemplate("{lens}").render(context()), "IMG_1")
    }

    func testUnknownTokenRendersLiterally() {
        let template = RenameTemplate("{foo}_{name}")
        XCTAssertEqual(template.unknownTokens, ["foo"])
        XCTAssertEqual(template.render(context()), "{foo}_IMG_1")
    }

    func testAllTokens() {
        let ctx = context(
            date: gmtDate(2024, 6, 1, 9, 5, 3), make: "Apple", model: "iPhone", lens: "L1", iso: 400, counter: 5)
        func render(_ pattern: String) -> String { RenameTemplate(pattern).render(ctx) }
        XCTAssertEqual(render("{name}"), "IMG_1")
        XCTAssertEqual(render("{ext}"), "jpg")
        XCTAssertEqual(render("{date}"), "2024-06-01")
        XCTAssertEqual(render("{date:yyyyMMdd}"), "20240601")
        XCTAssertEqual(render("{time}"), "090503")
        XCTAssertEqual(render("{time:HH.mm}"), "09.05")
        XCTAssertEqual(render("{camera}"), "iPhone")
        XCTAssertEqual(render("{make}"), "Apple")
        XCTAssertEqual(render("{lens}"), "L1")
        XCTAssertEqual(render("{iso}"), "400")
        XCTAssertEqual(render("{width}"), "800")
        XCTAssertEqual(render("{height}"), "600")
        XCTAssertEqual(render("{format}"), "JPEG")
        XCTAssertEqual(render("{folder}"), "Trip")
        XCTAssertEqual(render("{counter}"), "5")
        XCTAssertEqual(render("{counter:000}"), "005")
        XCTAssertEqual(render("a-{counter:00}-b"), "a-05-b")
    }

    func testMakeReadsHeader() {
        NSTimeZone.default = TimeZone(secondsFromGMT: 0)!
        let ctx = make(header(exifDate: "2024:06:01 23:30:00"))
        XCTAssertEqual(ctx.name, "IMG_1")
        XCTAssertEqual(ctx.folder, "Trip")
        XCTAssertEqual(ctx.ext, "jpg")
        XCTAssertEqual(ctx.make, "Apple")
        XCTAssertEqual(ctx.model, "iPhone 15 Pro")
        XCTAssertEqual(ctx.lens, "Lens X")
        XCTAssertEqual(ctx.iso, 400)
        XCTAssertEqual(ctx.width, 800)
        XCTAssertEqual(ctx.counter, 7)
    }

    func testLengthCapped() {
        let out = RenameTemplate(String(repeating: "a", count: 500)).render(context())
        XCTAssertEqual(out.count, 200)
    }

    func testSingleSeparatorsKept() {
        let ctx = context(date: gmtDate(2024, 6, 1, 1, 1))
        XCTAssertEqual(RenameTemplate("{date}_{name}").render(ctx), "2024-06-01_IMG_1")
    }

    func testBidiAndInvisibleScalarsRemoved() {
        let model = "a\u{202E}b\u{2066}c\u{200F}d\u{FEFF}e\u{2028}f\u{2029}g\u{061C}h\u{2060}i"
        let out = RenameTemplate("{camera}").render(context(model: model))
        XCTAssertEqual(out, "abcdefghi")
    }

    func testJoinersKept() {
        XCTAssertEqual(RenameTemplate("{camera}").render(context(model: "a\u{200D}b\u{200C}c")), "a\u{200D}b\u{200C}c")
    }

    func testInvisibleOnlyValueFallsBack() {
        XCTAssertEqual(RenameTemplate("{camera}").render(context(model: "\u{200B}")), "IMG_1")
        XCTAssertEqual(RenameTemplate("{camera}").render(context(model: "\u{2028}")), "IMG_1")
        XCTAssertEqual(RenameTemplate("{camera}").render(context(model: "\u{200D}")), "IMG_1")
    }

    func testByteLengthCapped() {
        let out = RenameTemplate(String(repeating: "\u{1F600}", count: 200)).render(context())
        XCTAssertLessThanOrEqual(out.utf8.count, 240)
        XCTAssertEqual(out.count, 60)
    }

    func testUnsanitisableNameFallsBackToImage() {
        XCTAssertEqual(RenameTemplate("{lens}").render(context(name: "...")), "image")
    }

    func testTokenExamplesAreConsistentWithKnownTokens() {
        var seen = Set<String>()
        for example in RenameTemplate.tokenExamples {
            XCTAssertEqual(RenameTemplate(example).unknownTokens, [], example)
            let inner = example.dropFirst().dropLast()
            seen.insert(String(inner.split(separator: ":", maxSplits: 1)[0]))
        }
        XCTAssertEqual(seen, RenameTemplate.knownTokens)
    }
}
