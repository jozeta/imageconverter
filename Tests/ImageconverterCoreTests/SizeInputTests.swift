import XCTest
@testable import ImageconverterCore

final class SizeInputTests: XCTestCase {
    func testParsesCommaAndPoint() {
        XCTAssertEqual(parseSizeBytes("2,5", unit: .megabytes), 2_500_000)
        XCTAssertEqual(parseSizeBytes("2.5", unit: .megabytes), 2_500_000)
        XCTAssertEqual(parseSizeBytes(" 300 ", unit: .kilobytes), 300_000)
    }

    func testRejectsInvalid() {
        for text in ["0", "-1", "1e30", "abc", "", "inf", "nan"] {
            XCTAssertNil(parseSizeBytes(text, unit: .kilobytes), text)
        }
    }

    func testQualitySuffix() {
        XCTAssertEqual(qualitySuffix(0.74, mode: .smart), " at 74 %")
        XCTAssertEqual(qualitySuffix(0.74, mode: .targetSize(bytes: 5)), " at 74 %")
        XCTAssertEqual(qualitySuffix(0.74, mode: .quality), "")
        XCTAssertEqual(qualitySuffix(nil, mode: .smart), "")
    }
}
