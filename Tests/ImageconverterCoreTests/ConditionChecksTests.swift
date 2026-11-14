import XCTest
@testable import ImageconverterCore

/// Every check added for Task 10, each with its negation, on facts built in code.
final class ConditionChecksTests: XCTestCase {
    private func facts(_ configure: (inout ItemFacts) -> Void = { _ in }) -> ItemFacts {
        var facts = ItemFacts(width: 4000, height: 3000, make: "Apple", model: "iPhone 15 Pro")
        facts.fileName = "IMG_0042 Holiday"
        facts.fileExtension = "jpg"
        facts.folderPath = "/Users/me/Pictures/Holiday 2024"
        configure(&facts)
        return facts
    }

    /// Asserts the condition matches (or not), and that its negation does the opposite.
    private func check(_ check: ConditionCheck, _ facts: ItemFacts, _ expected: Bool,
                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Condition(check).matches(facts), expected, "\(check)", file: file, line: line)
        XCTAssertEqual(Condition(check, negated: true).matches(facts), !expected, "not \(check)", file: file, line: line)
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        CalendarDay(year: year, month: month, day: day).date!.addingTimeInterval(12 * 3600)
    }

    // MARK: Name and location

    func testNameOperations() {
        let item = facts()
        check(.name(TextMatch(.contains, "holiday")), item, true)
        check(.name(TextMatch(.contains, "holiday", ignoresCase: false)), item, false)
        check(.name(TextMatch(.startsWith, "img_")), item, true)
        check(.name(TextMatch(.startsWith, "Holiday")), item, false)
        check(.name(TextMatch(.endsWith, "DAY")), item, true)
        check(.name(TextMatch(.endsWith, "IMG")), item, false)
        check(.name(TextMatch(.equals, "img_0042 holiday")), item, true)
        check(.name(TextMatch(.equals, "IMG_0042")), item, false)
        check(.name(TextMatch(.matchesRegex, #"^img_\d{4}\b"#)), item, true)
        check(.name(TextMatch(.matchesRegex, #"^img_\d{4}\b"#, ignoresCase: false)), item, false)
        check(.name(TextMatch(.contains, "")), item, false)
    }

    func testInvalidRegexNeverMatchesAndSaysWhy() {
        let broken = TextMatch(.matchesRegex, "([")
        XCTAssertEqual(broken.regexError, "Invalid regular expression")
        XCTAssertFalse(broken.matches("(["))
        XCTAssertNil(TextMatch(.matchesRegex, "^a").regexError)
        XCTAssertNil(TextMatch(.contains, "([").regexError, "plain text is never a pattern")
        // The negation of an invalid pattern matches everything, as "does not match" should.
        XCTAssertTrue(Condition(.name(broken), negated: true).matches(facts()))
    }

    func testExtensionAndFolder() {
        let item = facts()
        check(.fileExtension(["png", "jpeg"]), item, true)
        check(.fileExtension(["JPG"]), item, true)
        check(.fileExtension(["png", "heic"]), item, false)
        check(.fileExtension(["tif"]), facts { $0.fileExtension = "tiff" }, true)
        check(.folder(contains: "holiday 2024"), item, true)
        check(.folder(contains: "Work"), item, false)
        XCTAssertEqual(ConditionCheck.extensions(from: " .JPG, png  heic,jpg "), ["jpg", "png", "heic"])
    }

    // MARK: Dates

    func testDateRules() {
        let now = day(2026, 11, 14)
        let item = facts {
            $0.now = now
            $0.dateTaken = self.day(2024, 3, 10)
            $0.created = self.day(2026, 11, 1)
            $0.modified = now.addingTimeInterval(-3600)
        }
        check(.date(.taken, .exists), item, true)
        check(.date(.taken, .before(CalendarDay(year: 2024, month: 3, day: 11))), item, true)
        check(.date(.taken, .before(CalendarDay(year: 2024, month: 3, day: 10))), item, false)
        check(.date(.taken, .after(CalendarDay(year: 2024, month: 3, day: 9))), item, true)
        check(.date(.taken, .after(CalendarDay(year: 2024, month: 3, day: 10))), item, false)
        check(.date(.taken, .between(CalendarDay(year: 2024, month: 3, day: 10), CalendarDay(year: 2024, month: 3, day: 10))),
              item, true)
        check(.date(.taken, .between(CalendarDay(year: 2024, month: 12, day: 31), CalendarDay(year: 2024, month: 1, day: 1))),
              item, true)
        check(.date(.taken, .between(CalendarDay(year: 2025, month: 1, day: 1), CalendarDay(year: 2025, month: 12, day: 31))),
              item, false)
        check(.date(.taken, .inYear(2024)), item, true)
        check(.date(.taken, .inYear(2025)), item, false)
        check(.date(.taken, .inMonth(3)), item, true)
        check(.date(.taken, .inMonth(4)), item, false)
        check(.date(.created, .withinLastDays(30)), item, true)
        check(.date(.created, .withinLastDays(7)), item, false)
        check(.date(.modified, .withinLastDays(1)), item, true)
        // A date in the future isn't in the last N days.
        check(.date(.modified, .withinLastDays(1)), facts { $0.now = now; $0.modified = now.addingTimeInterval(3600) }, false)
    }

    func testMissingDateTaken() {
        let item = facts { $0.created = Date() }
        check(.date(.taken, .exists), item, false)
        XCTAssertTrue(Condition(.date(.taken, .exists), negated: true).matches(item), "has no date taken")
        check(.date(.taken, .inYear(2024)), item, false)
        check(.date(.taken, .withinLastDays(30)), item, false)
    }

    func testDateValidity() {
        XCTAssertFalse(CalendarDay(year: 2026, month: 2, day: 30).isValid)
        XCTAssertTrue(CalendarDay(year: 2024, month: 2, day: 29).isValid)
        XCTAssertFalse(ConditionCheck.date(.taken, .inMonth(13)).isValid)
        XCTAssertFalse(ConditionCheck.date(.taken, .withinLastDays(0)).isValid)
        XCTAssertFalse(ConditionCheck.date(.taken, .inYear(99)).isValid)
        XCTAssertTrue(ConditionCheck.date(.created, .between(CalendarDay(year: 2020, month: 1, day: 1),
                                                             CalendarDay(year: 2021, month: 1, day: 1))).isValid)
    }

    // MARK: Metadata

    func testMetadataTextFields() {
        let item = facts {
            $0.metadata = [.named(.lens): ["iPhone 15 Pro back camera 6.86mm f/1.78"],
                           .named(.keywords): ["Travel", "Family"],
                           .custom(.iptc, "City"): ["Stockholm"]]
        }
        check(.metadata(MetadataTest(.named(.cameraMake), .equals, "apple")), item, true)
        check(.metadata(MetadataTest(.named(.cameraModel), .contains, "15 pro")), item, true)
        check(.metadata(MetadataTest(.named(.lens), .contains, "6.86mm")), item, true)
        check(.metadata(MetadataTest(.named(.keywords), .equals, "family")), item, true)
        check(.metadata(MetadataTest(.named(.keywords), .equals, "fam")), item, false)
        check(.metadata(MetadataTest(.named(.keywords), .contains, "fam")), item, true)
        check(.metadata(MetadataTest(.named(.copyright), .exists)), item, false)
        check(.metadata(MetadataTest(.named(.copyright), .missing)), item, true)
        check(.metadata(MetadataTest(.custom(.iptc, "City"), .equals, "Stockholm")), item, true)
        check(.metadata(MetadataTest(.custom(.exif, "Artist"), .exists)), item, false)
    }

    func testMetadataNumbers() {
        let item = facts {
            $0.metadata = [.named(.iso): ["1600"], .named(.focalLength): ["50"], .named(.aperture): ["2.8"],
                           .named(.shutterSpeed): ["0.004"]]
        }
        check(.metadata(MetadataTest(.named(.iso), .greaterThan, "800")), item, true)
        check(.metadata(MetadataTest(.named(.iso), .lessThan, "800")), item, false)
        check(.metadata(MetadataTest(.named(.iso), .equals, "1600")), item, true)
        check(.metadata(MetadataTest(.named(.focalLength), .atLeast, "50")), item, true)
        check(.metadata(MetadataTest(.named(.focalLength), .atMost, "35")), item, false)
        check(.metadata(MetadataTest(.named(.aperture), .atMost, "2.8")), item, true)
        check(.metadata(MetadataTest(.named(.shutterSpeed), .equals, "1/250")), item, true)
        check(.metadata(MetadataTest(.named(.shutterSpeed), .greaterThan, "1/125")), item, false)
        // A missing number matches no comparison (and so its negation matches).
        check(.metadata(MetadataTest(.named(.iso), .greaterThan, "1")), facts(), false)
        XCTAssertEqual(MetadataTest.number("1/250"), 0.004)
        XCTAssertNil(MetadataTest.number("fast"))
    }

    func testMetadataValidity() {
        XCTAssertFalse(MetadataTest(.named(.artist), .greaterThan, "3").isValid, "comparisons are for numbers")
        XCTAssertFalse(MetadataTest(.named(.iso), .greaterThan, "lots").isValid)
        XCTAssertFalse(MetadataTest(.named(.artist), .contains, "  ").isValid)
        XCTAssertTrue(MetadataTest(.named(.artist), .missing).isValid)
        XCTAssertFalse(MetadataTest(.custom(.exif, "SecretKey"), .exists).isValid, "only allowlisted keys")
        XCTAssertTrue(MetadataTest(.custom(.xmp, "dc:title"), .exists).isValid)
    }

    // MARK: Image

    func testImageChecks() {
        let item = facts {
            $0.bitsPerComponent = 16
            $0.colorModel = "RGB"
            $0.profileName = "Display P3"
            $0.dpi = 300
            $0.exifOrientation = 6
            $0.frameCount = 3
        }
        check(.megapixels(.greaterThan, 11.9), item, true)
        check(.megapixels(.atLeast, 12.1), item, false)
        check(.aspectRatio(.widerThan(1.3)), item, true)
        check(.aspectRatio(.widerThan(1.4)), item, false)
        check(.aspectRatio(.tallerThan(1)), item, false)
        check(.aspectRatio(.tallerThan(1.3)), facts { $0.width = 3000; $0.height = 4000 }, true)
        check(.aspectRatio(.square), item, false)
        check(.aspectRatio(.square), facts { $0.width = 1000; $0.height = 1009 }, true)
        check(.aspectRatio(.square), facts { $0.width = 1000; $0.height = 1020 }, false)
        check(.bitDepth(.sixteen), item, true)
        check(.bitDepth(.eight), item, false)
        check(.bitDepth(.thirtyTwoFloat), facts { $0.bitsPerComponent = 32; $0.isFloat = true }, true)
        check(.colorSpace(.displayP3), item, true)
        check(.colorSpace(.sRGB), item, false)
        check(.hasProfile, item, true)
        check(.hasProfile, facts(), false)
        check(.dpi(.atLeast, 300), item, true)
        check(.dpi(.greaterThan, 72), facts(), false) // missing DPI counts as 72
        check(.isRotated, item, true)
        check(.isRotated, facts(), false)
        check(.isAnimated, item, true)
        check(.isAnimated, facts(), false)
    }

    func testColorSpaceKinds() {
        XCTAssertEqual(ColorSpaceKind(colorModel: "RGB", profileName: "sRGB IEC61966-2.1"), .sRGB)
        XCTAssertEqual(ColorSpaceKind(colorModel: "RGB", profileName: nil), .sRGB, "untagged RGB is sRGB")
        XCTAssertEqual(ColorSpaceKind(colorModel: "RGB", profileName: "Adobe RGB (1998)"), .adobeRGB)
        XCTAssertEqual(ColorSpaceKind(colorModel: "RGB", profileName: "ProPhoto RGB"), .other)
        XCTAssertEqual(ColorSpaceKind(colorModel: "Gray", profileName: "Generic Gray Gamma 2.2 Profile"), .gray)
        XCTAssertEqual(ColorSpaceKind(colorModel: "CMYK", profileName: nil), .cmyk)
        XCTAssertEqual(ColorSpaceKind(colorModel: "Lab", profileName: nil), .other)
    }

    func testExistingChecksNegate() {
        let item = facts { $0.hasGPS = true }
        check(.longestEdge(.greaterThan, 3999), item, true)
        check(.orientation(.landscape), item, true)
        check(.hasGPS(true), item, true)
        check(.camera(contains: "iphone"), item, true)
    }

    // MARK: Saving

    func testNegationIsSavedAsNotAndOldJSONIsUnchanged() throws {
        let plain = try String(bytes: JSONEncoder().encode(Condition.hasGPS(true)), encoding: .utf8)
        XCTAssertEqual(plain, #"{"hasGPS":{"_0":true}}"#, "as before negation existed")
        let negated = Condition(.name(TextMatch(.startsWith, "IMG")), negated: true)
        let data = try JSONEncoder().encode(negated)
        XCTAssertTrue(try XCTUnwrap(String(bytes: data, encoding: .utf8)).hasPrefix(#"{"not":"#))
        XCTAssertEqual(try JSONDecoder().decode(Condition.self, from: data), negated)
        // A missing "ignoresCase" means "ignore case".
        let old = #"{"name":{"_0":{"operation":"contains","text":"x"}}}"#
        XCTAssertEqual(try JSONDecoder().decode(Condition.self, from: Data(old.utf8)),
                       Condition(.name(TextMatch(.contains, "x"))))
    }

    func testEveryNewCheckRoundTrips() throws {
        let checks: [ConditionCheck] = [
            .name(TextMatch(.matchesRegex, "^a", ignoresCase: false)), .fileExtension(["jpg", "png"]),
            .folder(contains: "x"), .date(.taken, .between(CalendarDay(year: 2020, month: 1, day: 2),
                                                           CalendarDay(year: 2021, month: 3, day: 4))),
            .date(.created, .withinLastDays(5)), .date(.modified, .inMonth(2)), .date(.taken, .exists),
            .metadata(MetadataTest(.custom(.iptc, "City"), .equals, "Oslo")),
            .metadata(MetadataTest(.named(.iso), .atLeast, "100")), .megapixels(.lessThan, 2.5),
            .aspectRatio(.tallerThan(1.25)), .aspectRatio(.square), .bitDepth(.thirtyTwoFloat), .colorSpace(.cmyk),
            .hasProfile, .dpi(.atMost, 96), .isRotated, .isAnimated,
        ]
        let step = ConditionalStep(conditions: checks.prefix(10).map { Condition($0, negated: true) }, then: [.skip])
        let rest = ConditionalStep(conditions: checks.dropFirst(10).map { Condition($0) }, then: [.skip])
        for conditional in [step, rest] {
            let data = try JSONEncoder().encode(conditional)
            XCTAssertEqual(try JSONDecoder().decode(ConditionalStep.self, from: data), conditional)
        }
    }

    func testInvalidNewChecksAreDroppedOnLoad() throws {
        let json = """
        {"conditions": [{"fileExtension": {"_0": []}}, {"name": {"_0": {"operation": "contains", "text": " "}}},
          {"not": {"teleport": {}}}, {"megapixels": {"_0": "greaterThan", "_1": -1}},
          {"metadata": {"_0": {"subject": {"custom": {"_0": "exif", "_1": "Nope"}}, "operation": "exists", "value": ""}}},
          {"not": {"isAnimated": {}}}], "then": [{"skip": {}}]}
        """
        let decoded = try JSONDecoder().decode(ConditionalStep.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.conditions, [Condition(.isAnimated, negated: true)])
    }
}
