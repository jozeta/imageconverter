import XCTest
@testable import ImageconverterCore

final class ConditionSummaryTests: XCTestCase {
    func testNoConditionSummaryUsesSymbols() {
        var all: [Condition] = [.format(.format(.png)), .format(.type("public.camera-raw-image")),
                                .hasTransparency(true), .hasTransparency(false), .hasGPS(true), .hasGPS(false),
                                .camera(contains: "Canon")]
        all += Orientation.allCases.map { .orientation($0) }
        for comparison in Comparison.allCases {
            all += [.longestEdge(comparison, 10), .width(comparison, 10), .height(comparison, 10),
                    .fileSize(comparison, bytes: 500_000)]
            XCTAssertFalse(comparison.phrase.isEmpty)
        }
        for condition in all {
            XCTAssertNil(condition.summary.rangeOfCharacter(from: CharacterSet(charactersIn: "<>≥≤=")), condition.summary)
        }
        XCTAssertEqual(Condition.fileSize(.lessThan, bytes: 500_000).summary, "file size is less than 500 KB")
    }

    func testNewChecksAndNegationsUseWordsOnly() {
        let day = CalendarDay(year: 2024, month: 3, day: 10)
        var checks: [ConditionCheck] = [
            .name(TextMatch(.startsWith, "IMG")), .name(TextMatch(.matchesRegex, "^a", ignoresCase: false)),
            .fileExtension(["jpg", "png", "heic"]), .folder(contains: "Holiday"),
            .megapixels(.greaterThan, 12), .aspectRatio(.widerThan(1.5)), .aspectRatio(.tallerThan(2)), .aspectRatio(.square),
            .colorSpace(.displayP3), .hasProfile, .dpi(.atLeast, 300), .isRotated, .isAnimated,
        ]
        checks += BitDepth.allCases.map { .bitDepth($0) }
        for field in DateField.allCases {
            checks += [.exists, .before(day), .after(day), .between(day, day), .withinLastDays(30), .inYear(2024),
                       .inMonth(3)].map { .date(field, $0) }
        }
        for operation in MetadataOperation.allCases {
            checks += [.metadata(MetadataTest(.named(.iso), operation, "1600")),
                       .metadata(MetadataTest(.custom(.iptc, "City"), operation, "Oslo"))]
        }
        let symbols = CharacterSet(charactersIn: "<>≥≤=!")
        for check in checks {
            for negated in [false, true] {
                let text = Condition(check, negated: negated).summary
                XCTAssertFalse(text.isEmpty, "\(check)")
                XCTAssertNil(text.rangeOfCharacter(from: symbols), text)
            }
            XCTAssertNotEqual(check.summary(negated: false), check.summary(negated: true), "\(check)")
        }
        XCTAssertEqual(Condition(.name(TextMatch(.startsWith, "IMG")), negated: true).summary, "name does not start with “IMG”")
        XCTAssertEqual(Condition(.date(.taken, .exists), negated: true).summary, "has no date taken")
        XCTAssertEqual(Condition(.date(.created, .withinLastDays(30))).summary, "file created is within the last 30 days")
        XCTAssertEqual(Condition(.date(.taken, .inMonth(3))).summary, "date taken is in March")
        XCTAssertEqual(Condition(.hasProfile, negated: true).summary, "has no color profile")
        XCTAssertEqual(Condition(.metadata(MetadataTest(.named(.focalLength), .atLeast, "50"))).summary,
                       "focal length is at least 50 mm")
        XCTAssertEqual(Condition(.metadata(MetadataTest(.named(.copyright), .missing))).summary, "copyright is missing")
        XCTAssertEqual(Condition(.fileExtension(["jpg", "png", "heic"])).summary, "extension is jpg, png or heic")
        XCTAssertEqual(Condition.fileSize(.lessThan, bytes: 500_000).inverted.summary, "file size is not less than 500 KB")
    }

    func testNewActionSummaries() {
        let step = ConditionalStep(conditions: [.hasGPS(true)],
                                   then: [.subfolder("{date:yyyy}"), .finderTags(["Red", "Work"]), .addKeywords(["a", "b"])],
                                   otherwise: [.preset(PresetLink(id: UUID(), name: "Web")), .stop, .note("Check this one")])
        XCTAssertEqual(step.summary, "if has location → save into “{date:yyyy}”, tag Red, Work, add keywords a, b"
                       + " · else → apply preset “Web”, stop checking conditions, note “Check this one”")
        XCTAssertNil(step.summary.rangeOfCharacter(from: CharacterSet(charactersIn: "<>≥≤=")))
    }
}
