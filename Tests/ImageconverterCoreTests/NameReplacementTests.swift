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
        pipeline.rename = RenameOptions(isEnabled: true, pattern: "{name}", replacements: [ReplacementRule(find: "0001", replace: "a/b:c")])
        let text = RenameExample.render(source: nil, header: nil, created: nil, pipeline: pipeline)
        XCTAssertEqual(text, "IMG_a-b-c.jpg")
        XCTAssertFalse(text.contains("/"))
    }

    func testDecodesOldRenameOptions() throws {
        let json = #"{"isEnabled":true,"pattern":"{name}","counterStart":5}"#
        let options = try JSONDecoder().decode(RenameOptions.self, from: Data(json.utf8))
        XCTAssertTrue(options.replacements.isEmpty)
        XCTAssertEqual(options.counterStart, 5)
    }

    private func render(_ rules: [ReplacementRule]) -> String {
        var pipeline = Pipeline(steps: [], output: .init(format: .jpeg))
        pipeline.rename = RenameOptions(isEnabled: true, pattern: "a-b", replacements: rules)
        return RenameExample.render(source: nil, header: nil, created: nil, pipeline: pipeline)
    }

    func testRulesApplyInOrder() {
        let rules = [ReplacementRule(find: "-", replace: "_"), ReplacementRule(find: "_", replace: ".")]
        XCTAssertEqual(RenameOptions(replacements: rules).replacing(in: "a-b"), "a.b")
        XCTAssertEqual(render(rules), "a.b.jpg")
    }

    func testInvalidRuleSkippedOthersApply() {
        let rules = [ReplacementRule(find: "(", replace: "x", useRegex: true), ReplacementRule(find: "-", replace: "+"),
                     ReplacementRule(find: "", replace: "zzz")]
        XCTAssertEqual(RenameOptions(replacements: rules).replacing(in: "a-b"), "a+b")
    }

    func testOldSingleFieldsMigrateToOneRule() throws {
        let json = #"{"isEnabled":true,"findText":"IMG","replaceText":"pic","useRegex":true}"#
        let options = try JSONDecoder().decode(RenameOptions.self, from: Data(json.utf8))
        XCTAssertEqual(options.replacements.count, 1)
        XCTAssertEqual(options.replacements[0].find, "IMG")
        XCTAssertEqual(options.replacements[0].replace, "pic")
        XCTAssertTrue(options.replacements[0].useRegex)
    }

    func testEmptyOldFieldsGiveNoRules() throws {
        let json = #"{"isEnabled":true,"findText":"","replaceText":"x"}"#
        let options = try JSONDecoder().decode(RenameOptions.self, from: Data(json.utf8))
        XCTAssertTrue(options.replacements.isEmpty)
    }

    func testMax20Rules() throws {
        let rules = (0..<25).map { ReplacementRule(find: "f\($0)") }
        let data = try JSONEncoder().encode(RenameOptions(replacements: rules))
        let decoded = try JSONDecoder().decode(RenameOptions.self, from: data)
        XCTAssertEqual(decoded.replacements.count, 20)
        XCTAssertEqual(decoded.replacements.last?.find, "f19")
    }

    func testEncodeHasNoOldKeys() throws {
        let data = try JSONEncoder().encode(RenameOptions(replacements: [ReplacementRule(find: "a")]))
        let text = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        XCTAssertFalse(text.contains("findText"))
        XCTAssertFalse(text.contains("replaceText"))
        XCTAssertTrue(text.contains("replacements"))
    }

    func testSummaryCountsRules() {
        let rules = [ReplacementRule(find: "a"), ReplacementRule(find: "b"), ReplacementRule(find: "c")]
        XCTAssertEqual(RenameOptions(replacements: rules).summary, "{name} · 3 replacements")
        XCTAssertEqual(RenameOptions(replacements: [rules[0]]).summary, "{name}")
    }

    func testLegacyDecodeIsStable() throws {
        let json = Data(#"{"isEnabled":true,"findText":"IMG","replaceText":"pic"}"#.utf8)
        let first = try JSONDecoder().decode(RenameOptions.self, from: json)
        let second = try JSONDecoder().decode(RenameOptions.self, from: json)
        XCTAssertEqual(first, second)
        let noID = Data(#"{"replacements":[{"find":"a"}]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(RenameOptions.self, from: noID),
                       try JSONDecoder().decode(RenameOptions.self, from: noID))
    }
}
