import XCTest
@testable import ImageconverterCore

/// Output names are fitted to APFS's limit (255 UTF-16 units of the decomposed name) instead of failing (bugs B3, E4).
final class LongNameTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func source(stem: String) throws -> URL {
        let temp = root.appendingPathComponent("t.png")
        try TestImages.write(TestImages.make(width: 10, height: 10), to: temp, type: .png)
        let url = root.appendingPathComponent(stem + ".png")
        try FileManager.default.moveItem(at: temp, to: url)
        return url
    }

    func testLongSourceNameIsShortened() async throws {
        // 124 two-byte characters and one ASCII one: 249 bytes, so a cut by bytes would split a character.
        let stem = String(repeating: "é", count: 124) + "a"
        XCTAssertEqual(stem.utf8.count, 249)
        let url = try source(stem: stem)
        let report = await BatchRunner.run(InputCollector.collect([url]),
                                           pipeline: Pipeline(output: OutputSettings(format: .png)),
                                           mode: .sameFolder(suffix: "_new"))
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.written.count, 1)
        let name = try XCTUnwrap(report.written.first?.lastPathComponent)
        XCTAssertLessThanOrEqual(OutputPlanner.nameLength(name), 255)
        XCTAssertTrue(name.hasSuffix("_new.png"), name)
        XCTAssertTrue(stem.hasPrefix(String(name.dropLast("_new.png".count))), "cut on a character boundary")
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.written[0].path))
    }

    func testNameThatFitsIsKept() {
        let stem = String(repeating: "a", count: 250)
        let item = InputItem(source: root.appendingPathComponent(stem + ".png"), relativeDirectory: "")
        let out = root.appendingPathComponent("out", isDirectory: true)
        let plans = OutputPlanner.plan([item], format: .jpeg, mode: .newFolder(out), fileExists: { _ in false })
        XCTAssertEqual(plans.first?.destination.lastPathComponent, stem + ".jpg")
    }

    func testSuffixDropsZeroWidthAndBidi() {
        let item = InputItem(source: root.appendingPathComponent("a.png"), relativeDirectory: "")
        let suffix = "_\u{200B}n\u{200F}e\u{202E}w\u{2066}\u{FEFF}"
        let plans = OutputPlanner.plan([item], format: .png, mode: .sameFolder(suffix: suffix),
                                       fileExists: { _ in false })
        XCTAssertEqual(plans.first?.destination.lastPathComponent, "a_new.png")
    }

    /// The `_2` candidate of a name that only just fits is shortened again: valid and not the taken name.
    func testTakenFirstCandidateIsRefitted() {
        let stem = String(repeating: "é", count: 125)  // 250 bytes
        let item = InputItem(source: root.appendingPathComponent(stem + ".png"), relativeDirectory: "")
        let out = root.appendingPathComponent("out", isDirectory: true)
        let first = stem + ".png"
        let plans = OutputPlanner.plan([item], format: .png, mode: .newFolder(out),
                                       fileExists: { $0.lastPathComponent == first })
        let name = try? XCTUnwrap(plans.first?.destination.lastPathComponent)
        XCTAssertNotEqual(name, first)
        XCTAssertLessThanOrEqual(name.map(OutputPlanner.nameLength) ?? 999, 255)
        XCTAssertTrue(name?.hasSuffix("_2.png") ?? false, name ?? "")
        XCTAssertTrue(stem.hasPrefix(String(name?.dropLast("_2.png".count) ?? "")), "cut on a character boundary")
    }

    /// A longer extension (png → heic) shortens a name that fitted with its own extension.
    func testLongerExtensionIsFitted() {
        let stem = String(repeating: "a", count: 251)
        let item = InputItem(source: root.appendingPathComponent(stem + ".png"), relativeDirectory: "")
        let out = root.appendingPathComponent("out", isDirectory: true)
        let plans = OutputPlanner.plan([item], format: .heic, mode: .newFolder(out), fileExists: { _ in false })
        XCTAssertEqual(plans.first?.destination.lastPathComponent, String(repeating: "a", count: 250) + ".heic")
    }

    /// The same-folder suffix is capped at 64 units, and the source name always keeps a character, so the suffix
    /// never leads the name.
    func testSuffixIsCappedAndNeverLeadsTheName() {
        let item = InputItem(source: root.appendingPathComponent("photo.png"), relativeDirectory: "")
        let plans = OutputPlanner.plan([item], format: .png, mode: .sameFolder(suffix: String(repeating: "s", count: 100)),
                                       fileExists: { _ in false })
        XCTAssertEqual(plans.first?.destination.lastPathComponent, "photo" + String(repeating: "s", count: 64) + ".png")
        let naming = OutputNaming(name: "photo", suffix: "." + String(repeating: "s", count: 260), dotExtension: ".png")
        XCTAssertTrue(naming.fileName(1).hasPrefix("p"))
    }

    /// U+01D8 (ǘ) is 2 bytes precomposed but 3 UTF-16 units decomposed, as APFS counts: 83 of them plus `_new.png`
    /// is 174 NFC bytes but 257 units, so the name must be shortened to be written.
    func testCombiningMarksAreCountedDecomposed() async throws {
        let stem = String(repeating: "\u{1D8}", count: 83)
        let url = try source(stem: stem)
        let report = await BatchRunner.run(InputCollector.collect([url]),
                                           pipeline: Pipeline(output: OutputSettings(format: .png)),
                                           mode: .sameFolder(suffix: "_new"))
        XCTAssertEqual(report.failures, [])
        let name = try XCTUnwrap(report.written.first?.lastPathComponent)
        XCTAssertLessThanOrEqual(OutputPlanner.nameLength(name), 255)
        XCTAssertEqual(name, String(repeating: "\u{1D8}", count: 82) + "_new.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.written[0].path))
    }

    /// Names that fit by that count keep their full length: "é" counts 2, an emoji 2 (not 3 or 4 bytes).
    func testNamesThatFitDecomposedAreKept() {
        let out = root.appendingPathComponent("out", isDirectory: true)
        for stem in [String(repeating: "\u{E9}", count: 125), String(repeating: "\u{1F600}", count: 125)] {
            let item = InputItem(source: root.appendingPathComponent(stem + ".png"), relativeDirectory: "")
            let plans = OutputPlanner.plan([item], format: .png, mode: .newFolder(out), fileExists: { _ in false })
            XCTAssertEqual(plans.first?.destination.lastPathComponent, stem + ".png")
        }
    }

    func testSuffixCapCountsDecomposedUnits() {
        // 40 × U+01D8 = 120 units: cut to 21 characters (63 units).
        XCTAssertEqual(OutputPlanner.cappedSuffix(String(repeating: "\u{1D8}", count: 40)),
                       String(repeating: "\u{1D8}", count: 21))
    }
}
