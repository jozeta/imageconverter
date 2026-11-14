import ImageIO
import XCTest
@testable import ImageconverterCore

final class NameTransformsTests: XCTestCase {
    private func ctx(name: String = "my photo 01") -> RenameContext {
        RenameContext(name: name, ext: "jpg", format: "JPEG", folder: "Trip", date: nil, make: nil, model: nil,
                      lens: nil, iso: nil, width: 8, height: 6, counter: 1)
    }

    private func render(_ options: RenameOptions, name: String = "my photo 01") -> String {
        options.render(RenameTemplate(options.pattern), ctx(name: name))
    }

    func testCamelCase() {
        XCTAssertEqual(NameTransforms.caseStyle("my photo 01", style: .camel), "myPhoto01")
        XCTAssertEqual(NameTransforms.caseStyle("MY_photo-Two", style: .camel), "myPhotoTwo")
    }

    func testSnakeKebabTitlePascal() {
        XCTAssertEqual(NameTransforms.caseStyle("My Photo 01", style: .snake), "my_photo_01")
        XCTAssertEqual(NameTransforms.caseStyle("myPhoto 01", style: .kebab), "my-photo-01")
        XCTAssertEqual(NameTransforms.caseStyle("my photo 01", style: .pascal), "MyPhoto01")
        XCTAssertEqual(NameTransforms.caseStyle("my PHOTO åre", style: .title), "My Photo Åre")
        XCTAssertEqual(NameTransforms.caseStyle("Åre", style: .lower), "åre")
    }

    func testRemoveSpaces() {
        XCTAssertEqual(NameTransforms.removeSpaces(" my  photo 01 "), "myphoto01")
    }

    func testReplaceSpecialCharactersCollapsesAndTrims() {
        XCTAssertEqual(NameTransforms.specialCharacters("(my) photo!! #1", mode: .replace, replacement: "-"), "my-photo-1")
        XCTAssertEqual(NameTransforms.specialCharacters("a & b", mode: .replace, replacement: "_"), "a_b")
        XCTAssertEqual(NameTransforms.specialCharacters("a & b", mode: .replace, replacement: ""), "ab")
        XCTAssertEqual(NameTransforms.specialCharacters("a b", mode: .replace, replacement: "x"), "a-b")
    }

    func testRemoveSpecialKeepsUnicodeLetters() {
        XCTAssertEqual(NameTransforms.specialCharacters("Åre, räksmörgås! #1.jpg", mode: .remove, replacement: "-"),
                       "Åreräksmörgås1.jpg")
        XCTAssertEqual(NameTransforms.specialCharacters("å é!", mode: .replace, replacement: "-"), "å-é")
    }

    func testPrefixSuffixApplied() {
        let options = RenameOptions(isEnabled: true, pattern: "{name}", prefix: "A_", suffix: "_Z")
        XCTAssertEqual(render(options, name: "x"), "A_x_Z")
    }

    func testOrderFindReplaceBeforeCase() {
        let rule = ReplacementRule(id: UUID(), find: "photo", replace: "Big Photo", useRegex: false)
        // The rule sees the original case; the prefix is added after it; case runs last on everything.
        let options = RenameOptions(isEnabled: true, replacements: [rule], prefix: "My ", caseStyle: .snake)
        XCTAssertEqual(render(options, name: "a photo"), "my_a_big_photo")
        // Spaces go before case: the case boundaries still split "MyaBigPhoto".
        let joined = RenameOptions(isEnabled: true, replacements: [rule], prefix: "My ", removeSpaces: true,
                                   caseStyle: .snake)
        XCTAssertEqual(render(joined, name: "a photo"), "mya_big_photo")
    }

    func testOldRenameJSONDecodes() throws {
        let json = #"{"isEnabled":true,"pattern":"{name}_x","counterStart":3}"#
        let decoded = try JSONDecoder().decode(RenameOptions.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.prefix, "")
        XCTAssertEqual(decoded.specialCharacters, .keep)
        XCTAssertEqual(decoded.replacement, "-")
        XCTAssertEqual(decoded.caseStyle, .keep)
        XCTAssertFalse(decoded.removeSpaces)
        let bad = #"{"replacement":"x","caseStyle":"shout"}"#
        let lenient = try JSONDecoder().decode(RenameOptions.self, from: Data(bad.utf8))
        XCTAssertEqual(lenient.replacement, "-")
        XCTAssertEqual(lenient.caseStyle, .keep)
        let again = try JSONDecoder().decode(RenameOptions.self, from: JSONEncoder().encode(
            RenameOptions(prefix: "p", caseStyle: .kebab)))
        XCTAssertEqual(again.prefix, "p")
        XCTAssertEqual(again.caseStyle, .kebab)
    }

    func testExifTokens() {
        let exif: [String: Any] = [
            kCGImagePropertyExifFocalLength as String: 24.0,
            kCGImagePropertyExifFNumber as String: 2.8,
            kCGImagePropertyExifExposureTime as String: 0.004,
        ]
        let header = ImageHeader(width: 10, height: 10, properties: [kCGImagePropertyExifDictionary as String: exif])
        let context = RenameContext.make(
            source: URL(fileURLWithPath: "/tmp/a.jpg"), header: header, outputSize: (10, 10), format: .jpeg,
            counter: 4, fileCreationDate: nil)
        XCTAssertEqual(RenameTemplate("{focal} {aperture} {shutter}").render(context), "24mm f2.8 1-250s")
        XCTAssertEqual(RenameTemplate("{seq:00}").render(context), "04")
        XCTAssertTrue(RenameTemplate("{shutter}").needsHeader)
    }

    func testDatetimeToken() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "GMT")!
        var context = ctx()
        context.date = cal.date(from: DateComponents(year: 2024, month: 6, day: 1, hour: 9, minute: 5, second: 3))
        XCTAssertEqual(RenameTemplate("{datetime}").render(context), "2024-06-01_090503")
        XCTAssertTrue(RenameTemplate("{datetime}").needsDate)
    }

    private func exposure(focal: Double?, aperture: Double?, time: Double?) -> RenameContext {
        var context = ctx()
        context.focalLength = focal
        context.aperture = aperture
        context.exposureTime = time
        return context
    }

    func testUntrustedExifNumbersRenderNothing() {
        let bad: [Double] = [.infinity, -.infinity, .nan, 1e-300, -5, 0, 1e300]
        for value in bad {
            let context = exposure(focal: value, aperture: value, time: value)
            XCTAssertEqual(RenameTemplate("{focal}{aperture}{shutter}").render(context), "my photo 01", "\(value)")
        }
    }

    func testShutterAndApertureFormats() {
        func shutter(_ time: Double) -> String { RenameTemplate("{shutter}").render(exposure(focal: nil, aperture: nil, time: time)) }
        XCTAssertEqual(shutter(2), "2s")
        XCTAssertEqual(shutter(1.5), "1.5s")
        XCTAssertEqual(shutter(0.8), "0.8s")
        XCTAssertEqual(shutter(0.9999), "1s")
        XCTAssertEqual(shutter(1.0 / 250), "1-250s")
        XCTAssertEqual(RenameTemplate("{aperture}").render(exposure(focal: nil, aperture: 1.78, time: nil)), "f1.8")
        XCTAssertEqual(RenameTemplate("{aperture}").render(exposure(focal: nil, aperture: 8, time: nil)), "f8")
    }

    func testTitleCaseSplitsOnUnderscoreAndDash() {
        XCTAssertEqual(NameTransforms.caseStyle("my_photo-two three", style: .title), "My_Photo-Two Three")
    }

    func testDigitsStayAttached() {
        XCTAssertEqual(NameTransforms.caseStyle("IMG_1234 HDR", style: .camel), "img1234Hdr")
        XCTAssertEqual(NameTransforms.caseStyle("photo2Final", style: .snake), "photo2final")
    }
}
