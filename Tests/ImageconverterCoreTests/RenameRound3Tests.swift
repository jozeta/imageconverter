import Foundation
import XCTest
@testable import ImageconverterCore

/// Feedback round 3: the counter step, the new rename tokens, `{preset}` and `{labels}` in file names.
final class RenameRound3Tests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var out: URL { root.appendingPathComponent("out", isDirectory: true) }

    private func source(_ name: String, width: Int = 40, height: Int = 20) throws -> URL {
        let url = root.appendingPathComponent(name)
        try TestImages.write(TestImages.make(width: width, height: height), to: url, type: .jpeg)
        return url
    }

    private func gmt(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func context(width: Int = 800, height: Int = 600) -> RenameContext {
        RenameContext(name: "IMG_1", ext: "jpg", format: "JPEG", folder: "Trip", date: nil, make: nil, model: nil,
                      lens: nil, iso: nil, width: width, height: height, counter: 1)
    }

    private func renamed(_ pattern: String, start: Int = 1, step: Int = 1) -> Pipeline {
        var pipeline = Pipeline(output: OutputSettings(format: .jpeg))
        pipeline.rename = RenameOptions(isEnabled: true, pattern: pattern, counterStart: start, counterStep: step)
        return pipeline
    }

    // MARK: Counter step

    func testCounterStepDefaultsToOneAndDecodesLeniently() throws {
        XCTAssertEqual(RenameOptions().counterStep, 1)
        let decode = { (json: String) in try JSONDecoder().decode(RenameOptions.self, from: Data(json.utf8)) }
        XCTAssertEqual(try decode(#"{"isEnabled":true}"#).counterStep, 1, "older files count by one")
        XCTAssertEqual(try decode(#"{"counterStep":0}"#).counterStep, 1, "0 is not a step")
        XCTAssertEqual(try decode(#"{"counterStep":5}"#).counterStep, 5)
        XCTAssertEqual(try decode(#"{"counterStep":-2}"#).counterStep, -2)
        XCTAssertEqual(try decode(#"{"counterStep":9223372036854775807}"#).counterStep,
                       RenameOptions.counterStepRange.upperBound)
        XCTAssertEqual(try decode(#"{"counterStep":"x"}"#).counterStep, 1, "a broken value takes the default")
        XCTAssertEqual(RenameOptions(counterStep: 0).counterStep, 1)
        let options = RenameOptions(isEnabled: true, counterStart: 3, counterStep: 10)
        let back = try JSONDecoder().decode(RenameOptions.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(back, options)
    }

    func testCounterAtIndexStepsAndNeverGoesBelowZero() {
        let counting = RenameOptions(counterStart: 10, counterStep: 5)
        XCTAssertEqual((0..<3).map(counting.counter(at:)), [10, 15, 20])
        let down = RenameOptions(counterStart: 5, counterStep: -3)
        XCTAssertEqual((0..<4).map(down.counter(at:)), [5, 2, 0, 0], "clamped at 0")
        let huge = RenameOptions(counterStart: RenameOptions.counterRange.upperBound,
                                 counterStep: RenameOptions.counterStepRange.upperBound)
        XCTAssertEqual(huge.counter(at: Int.max), Int.max, "saturates instead of trapping")
        var raw = RenameOptions()
        raw.counterStep = 0
        XCTAssertEqual(raw.counter(at: 2), 3, "a 0 set in code still counts by one")
    }

    func testBatchUsesTheStep() async throws {
        let files = try (1...3).map { try source("img\($0).jpg") }
        let report = await BatchRunner.run(InputCollector.collect(files), pipeline: renamed("n{counter:000}", start: 10, step: 10),
                                           mode: .newFolder(out))
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.written.map(\.lastPathComponent), ["n010.jpg", "n020.jpg", "n030.jpg"])
    }

    func testExampleUsesTheStep() {
        let name = RenameExample.render(source: nil, header: nil, created: nil, pipeline: renamed("n{counter}", step: 5),
                                        index: 2)
        XCTAssertEqual(name, "n11.jpg")
    }

    // MARK: New tokens

    func testFileDates() {
        var ctx = context()
        ctx.created = gmt(2024, 3, 9)
        ctx.modified = gmt(2025, 12, 31)
        XCTAssertEqual(RenameTemplate("{created}_{modified:yyyyMMdd}").render(ctx), "2024-03-09_20251231")
        XCTAssertEqual(RenameTemplate("{name}_{modified}").render(context()), "IMG_1", "no date: the separator goes")
        XCTAssertTrue(RenameTemplate("{created}").needsDate)
        XCTAssertTrue(RenameTemplate("{modified}").needsDate)
        XCTAssertFalse(RenameTemplate("{created}").needsHeader)
    }

    func testFileDatesFromTheFileKeepTheLocalWallClock() throws {
        let url = try source("dated.jpg")
        let modified = gmt(2024, 6, 1).addingTimeInterval(1.5 * 3600)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        let item = InputItem(source: url, relativeDirectory: "")
        let name = RenameRendering.baseName(for: item, index: 0, pipeline: renamed("{modified:yyyy-MM-dd_HHmm}"))
        // The name shows the Mac's own clock at that instant.
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        local.dateFormat = "yyyy-MM-dd_HHmm"
        XCTAssertEqual(name, local.string(from: modified))
    }

    func testSizeTokens() {
        XCTAssertEqual(RenameTemplate("{megapixels}").render(context(width: 4032, height: 3024)), "12.2MP")
        XCTAssertEqual(RenameTemplate("{megapixels}").render(context(width: 800, height: 600)), "0.5MP")
        XCTAssertEqual(RenameTemplate("{orientation}").render(context(width: 800, height: 600)), "landscape")
        XCTAssertEqual(RenameTemplate("{orientation}").render(context(width: 600, height: 800)), "portrait")
        XCTAssertEqual(RenameTemplate("{orientation}").render(context(width: 50, height: 50)), "square")
        XCTAssertTrue(RenameTemplate("{orientation}").needsHeader)
        XCTAssertTrue(RenameTemplate("{megapixels}").needsHeader)
    }

    func testSourceExtensionAndPreset() {
        var ctx = RenameContext.make(source: URL(fileURLWithPath: "/tmp/Trip/IMG_1.HEIC"), header: nil,
                                     outputSize: (10, 10), format: .jpeg, counter: 1, fileCreationDate: nil)
        XCTAssertEqual(RenameTemplate("{name}_{srcext}.{ext}").render(ctx), "IMG_1_heic.jpg")
        XCTAssertEqual(RenameTemplate("{preset}_{name}").render(ctx), "IMG_1", "no preset: nothing and no separator")
        ctx.preset = "Web/Small: v2"
        XCTAssertEqual(RenameTemplate("{preset}_{name}").render(ctx), "Web-Small- v2_IMG_1", "sanitised")
        XCTAssertFalse(RenameTemplate("{srcext}{preset}").needsHeader)
    }

    func testRandomAndUUIDAreStablePerFileAndSafe() {
        let make = { (path: String) in
            RenameContext.make(source: URL(fileURLWithPath: path), header: nil, outputSize: (10, 10), format: .jpeg,
                               counter: 1, fileCreationDate: nil)
        }
        let first = RenameTemplate("{random}").render(make("/tmp/a.jpg"))
        XCTAssertEqual(first.count, 8)
        XCTAssertTrue(first.allSatisfy { $0.isLowercase || $0.isNumber }, first)
        XCTAssertEqual(first, RenameTemplate("{random}").render(make("/tmp/a.jpg")), "preview and batch agree")
        XCTAssertNotEqual(first, RenameTemplate("{random}").render(make("/tmp/b.jpg")))
        XCTAssertEqual(RenameTemplate("{random:4}").render(make("/tmp/a.jpg")).count, 4)
        XCTAssertEqual(RenameTemplate("{random:99}").render(make("/tmp/a.jpg")).count, 8, "out of range: the default")
        let uuid = RenameTemplate("{uuid}").render(make("/tmp/a.jpg"))
        XCTAssertNotNil(UUID(uuidString: uuid), uuid)
        XCTAssertNotEqual(uuid, RenameTemplate("{uuid}").render(make("/tmp/b.jpg")))
    }

    func testLabelsInFileNames() {
        var ctx = context()
        ctx.labels = ["dog", "grass/field"]
        XCTAssertEqual(RenameTemplate("{labels:-}_{name}").render(ctx), "dog-grass-field_IMG_1")
        XCTAssertEqual(RenameTemplate("{labels}").render(ctx), "dog, grass-field", "default separator")
        XCTAssertEqual(RenameTemplate("{labels:abc}").render(ctx), "dog, grass-field", "unsafe separator: default")
        ctx.labels = []
        XCTAssertEqual(RenameTemplate("{labels:-}_{name}").render(ctx), "IMG_1")
        XCTAssertTrue(RenameTemplate("x{labels:-}").usesLabels)
        XCTAssertFalse(RenameTemplate("x{name}").usesLabels)
    }

    func testTokenMenuMatchesKnownTokens() {
        var seen = Set<String>()
        for section in RenameTemplate.tokenMenu {
            XCTAssertFalse(section.items.isEmpty, section.title)
            for item in section.items {
                XCTAssertEqual(RenameTemplate(item.token).unknownTokens, [], item.token)
                XCTAssertFalse(item.title.isEmpty)
                let inner = item.token.dropFirst().dropLast()
                seen.insert(String(inner.split(separator: ":", maxSplits: 1)[0]))
            }
        }
        XCTAssertEqual(seen, RenameTemplate.knownTokens, "every token is in the menu")
        XCTAssertEqual(Set(RenameTemplate.tokenExamples), Set(RenameTemplate.tokenMenu.flatMap(\.items).map(\.token)))
    }

    // MARK: Preset name

    func testPresetNameIsNotSavedAndNeverMakesPipelinesUnequal() throws {
        var named = Pipeline()
        named.presetName = "Web"
        XCTAssertEqual(named, Pipeline())
        let data = try JSONEncoder().encode(named)
        XCTAssertFalse((String(bytes: data, encoding: .utf8) ?? "").contains("Web"))
        XCTAssertNil(try JSONDecoder().decode(Pipeline.self, from: data).presetName)
    }

    func testBatchWritesThePresetName() async throws {
        let url = try source("img.jpg")
        var pipeline = renamed("{preset}_{name}")
        pipeline.presetName = "Web"
        let report = await BatchRunner.run(InputCollector.collect([url]), pipeline: pipeline, mode: .newFolder(out))
        XCTAssertEqual(report.written.map(\.lastPathComponent), ["Web_img.jpg"])
    }

    func testJobsAndConditionsKeepThePresetName() {
        let preset = Preset(name: "Archive", pipeline: renamed("{preset}"))
        let job = Job(name: "j", presetID: preset.id, output: .sameFolder(suffix: "_x"))
        XCTAssertEqual(job.resolvedPipeline(presets: [preset])?.presetName, "Archive")
        XCTAssertNil(Job(name: "j", output: .overwrite).resolvedPipeline(presets: [])?.presetName, "the job's own pipeline has no preset")
        var pipeline = renamed("{preset}")
        pipeline.presetName = "Archive"
        XCTAssertEqual(pipeline.resolved(for: ItemFacts(width: 1, height: 1)).pipeline.presetName, "Archive")
    }

    // MARK: Labels in the batch

    func testBatchNamesFilesByLabelsWithoutConditions() async throws {
        let url = try source("a.jpg")
        let cache = ImageAnalysisCache(analyzer: FakeImageAnalyzer(ImageAnalysis(labels: [
            ImageLabel("dog", confidence: 0.9), ImageLabel("grass", confidence: 0.5)])))
        let pipeline = renamed("{labels:-}_{name}")
        XCTAssertTrue(pipeline.needsFacts)
        XCTAssertTrue(pipeline.factNeeds.contains(.labels))
        XCTAssertFalse(renamed("{name}").needsFacts, "no labels: no analysis")
        let plan = await BatchRunner.plan([InputItem(source: url, relativeDirectory: "")], pipeline: pipeline,
                                          mode: .newFolder(out), analysis: cache)
        XCTAssertEqual(plan?.first?.destination?.lastPathComponent, "dog-grass_a.jpg")
    }

    func testConditionRenameAndSubfolderWithLabelArgumentsAskForLabels() {
        let rename = RenameOptions(isEnabled: true, pattern: "{labels:-}")
        XCTAssertTrue(ConditionalAction.rename(rename).usesLabels)
        XCTAssertTrue(ConditionalAction.subfolder("{labels:_}").usesLabels)
        XCTAssertFalse(ConditionalAction.rename(RenameOptions(isEnabled: true, pattern: "{name}")).usesLabels)
    }

    // MARK: Preview default

    /// The app's compare modes, as `CompareMode` spells them (the app target has no tests).
    private enum Mode: String { case sideBySide, split, difference, single }

    func testPreviewDefaultsToSplitAndKeepsASavedMode() throws {
        // A store with nothing saved (no plist is written: values go in the in-memory registration domain).
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "imageconverter-tests-compare-\(UUID().uuidString)"))
        let key = ViewDefaults.compareModeKey
        let registration = UserDefaults.registrationDomain
        defer {
            var domain = defaults.volatileDomain(forName: registration)
            domain[key] = nil
            defaults.setVolatileDomain(domain, forName: registration)
        }
        XCTAssertNil(defaults.object(forKey: key))
        XCTAssertEqual(ViewDefaults.startingCompareMode(in: defaults, as: Mode.self), .split, "a brand-new store")
        defaults.register(defaults: [key: "difference"])
        XCTAssertEqual(ViewDefaults.startingCompareMode(in: defaults, as: Mode.self), .difference, "a saved mode is kept")
        defaults.register(defaults: [key: "sideBySide"])
        XCTAssertEqual(ViewDefaults.startingCompareMode(in: defaults, as: Mode.self), .sideBySide)
        defaults.register(defaults: [key: "bogus"])
        XCTAssertEqual(ViewDefaults.startingCompareMode(in: defaults, as: Mode.self), .split, "unknown: the default")
    }

    func testSplitIsAppliedOnceThenTheUsersChoiceIsKept() {
        final class Store: ViewDefaultsStore {
            var values: [String: Any] = [:]
            func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
            func set(_ value: Any?, forKey key: String) { values[key] = value }
        }
        let store = Store()
        store.set("sideBySide", forKey: ViewDefaults.compareModeKey)   // chosen before this version
        XCTAssertTrue(ViewDefaults.applySplitDefaultOnce(in: store))
        XCTAssertEqual(store.values[ViewDefaults.compareModeKey] as? String, "split")
        XCTAssertEqual(store.values[ViewDefaults.splitDefaultAppliedKey] as? Bool, true)
        store.set("difference", forKey: ViewDefaults.compareModeKey)   // chosen afterwards
        XCTAssertFalse(ViewDefaults.applySplitDefaultOnce(in: store), "only once")
        XCTAssertEqual(store.values[ViewDefaults.compareModeKey] as? String, "difference")
        let fresh = Store()
        XCTAssertTrue(ViewDefaults.applySplitDefaultOnce(in: fresh), "a new install gets Split too")
        XCTAssertEqual(fresh.values[ViewDefaults.compareModeKey] as? String, "split")
    }
}
