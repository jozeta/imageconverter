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
}
