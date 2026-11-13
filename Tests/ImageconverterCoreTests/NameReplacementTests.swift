import XCTest
@testable import ImageconverterCore

final class NameReplacementTests: XCTestCase {
    func testPlainReplacesAll() {
        XCTAssertEqual(NameReplacement.apply("a-b-c", find: "-", replace: "_", regex: false), "a_b_c")
    }

    func testEmptyFindIsNoop() {
        XCTAssertEqual(NameReplacement.apply("a-b", find: "", replace: "x", regex: false), "a-b")
        XCTAssertEqual(NameReplacement.apply("a-b", find: "", replace: "x", regex: true), "a-b")
    }

    func testRegexGroups() {
        XCTAssertEqual(
            NameReplacement.apply("IMG_1234", find: #"IMG_(\d+)"#, replace: "photo-$1", regex: true), "photo-1234")
    }

    func testInvalidRegexIsNoop() {
        XCTAssertEqual(NameReplacement.apply("a(b", find: "(", replace: "x", regex: true), "a(b")
        XCTAssertNotNil(NameReplacement.regexError("("))
        XCTAssertNil(NameReplacement.regexError("a+"))
    }

    func testEmptyMatchRegexDoesNotHang() {
        XCTAssertEqual(NameReplacement.apply("ab", find: "x*", replace: "-", regex: true), "-a-b-")
    }

    func testReplacementCannotAddSlash() {
        var pipeline = Pipeline(steps: [], output: .init(format: .jpeg))
        pipeline.rename = RenameOptions(isEnabled: true, pattern: "{name}", findText: "0001", replaceText: "a/b:c")
        let text = RenameExample.render(source: nil, header: nil, created: nil, pipeline: pipeline)
        XCTAssertEqual(text, "IMG_a-b-c.jpg")
        XCTAssertFalse(text.contains("/"))
    }

    func testDecodesOldRenameOptions() throws {
        let json = #"{"isEnabled":true,"pattern":"{name}","counterStart":5}"#
        let options = try JSONDecoder().decode(RenameOptions.self, from: Data(json.utf8))
        XCTAssertEqual(options.findText, "")
        XCTAssertEqual(options.replaceText, "")
        XCTAssertFalse(options.useRegex)
        XCTAssertEqual(options.counterStart, 5)
    }
}
