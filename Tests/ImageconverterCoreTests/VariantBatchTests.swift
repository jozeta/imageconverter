import ImageIO
import XCTest
@testable import ImageconverterCore

/// Extra outputs in the batch: names, sizes, modes, collisions, conditions, failures and the report.
final class VariantBatchTests: XCTestCase {
    private var root: URL!
    private var out: URL!

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
        out = root.appendingPathComponent("out", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func source(_ name: String, width: Int = 800, height: Int = 400, in folder: URL? = nil) throws -> URL {
        let directory = folder ?? root!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try TestImages.write(TestImages.noise(width: width, height: height), to: url, type: .jpeg)
        return url
    }

    private func items(_ urls: [URL]) -> [InputItem] { urls.map { InputItem(source: $0, relativeDirectory: "") } }

    private func size(_ url: URL) -> (Int, Int)? { ImageLoader.pixelSize(of: url).map { ($0.width, $0.height) } }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private var threeVariants: [OutputVariant] {
        [
            OutputVariant(name: "Thumbnail", settings: OutputSettings(format: .jpeg, quality: 0.6),
                          resize: .longestEdge(200), nameSuffix: "_thumb"),
            OutputVariant(name: "Half", settings: OutputSettings(format: .png), resize: .percent(50), nameSuffix: "_half"),
            OutputVariant(name: "Tall", settings: OutputSettings(format: .heic), resize: .maxHeight(100),
                          nameSuffix: "-tall", subfolder: "small"),
        ]
    }

    private func pipeline(_ variants: [OutputVariant], format: OutputFormat = .jpeg) -> Pipeline {
        Pipeline(output: OutputSettings(format: format), extraOutputs: variants)
    }

    /// Trashes for real and records each file.
    private func recordingTrash() -> (Trasher, LockedLog<URL>) {
        let log = LockedLog<URL>()
        return ({ url in
            log.append(url)
            try FileManager.default.removeItem(at: url)
        }, log)
    }

    // MARK: Names and sizes

    func testThreeVariantsAreWrittenWithTheirNamesAndSizes() async throws {
        let photo = try source("photo.jpg")
        let report = await BatchRunner.run(items([photo]), pipeline: pipeline(threeVariants), mode: .newFolder(out))
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.written.map { $0.path.replacingOccurrences(of: out.path + "/", with: "") },
                       ["photo.jpg", "photo_thumb.jpg", "photo_half.png", "small/photo-tall.heic"])
        XCTAssertEqual(size(report.written[0])?.0, 800)
        XCTAssertEqual(size(report.written[1]).map { [$0.0, $0.1] }, [200, 100])
        XCTAssertEqual(size(report.written[2]).map { [$0.0, $0.1] }, [400, 200])
        XCTAssertEqual(size(report.written[3]).map { [$0.0, $0.1] }, [200, 100])
        XCTAssertEqual(report.entries.map(\.variant), [nil, "Thumbnail", "Half", "Tall"])
        for (entry, url) in zip(report.entries, report.written) {
            XCTAssertEqual(entry.destination, url)
            XCTAssertEqual(entry.outputBytes, BatchRunner.fileSize(url))
        }
        XCTAssertEqual(report.convertedCount, 1)
    }

    func testVariantsAfterThePipelinesOwnStepsAndShrinkOnly() async throws {
        let photo = try source("photo.jpg", width: 300, height: 150)
        var pipeline = pipeline([
            OutputVariant(name: "Big", resize: .longestEdge(1000), nameSuffix: "_big"),
            OutputVariant(name: "Double", resize: .percent(200), nameSuffix: "_x2"),
        ])
        pipeline.steps = [PipelineStep(operation: .resize(ResizeOptions(mode: .longestEdge(100))))]
        let report = await BatchRunner.run(items([photo]), pipeline: pipeline, mode: .newFolder(out))
        XCTAssertEqual(report.written.map(size).map { $0?.0 }, [100, 100, 200])
    }

    func testRenameAppliesToTheBaseName() async throws {
        let photo = try source("IMG_1.jpg")
        var pipeline = pipeline([threeVariants[0]])
        pipeline.rename = RenameOptions(isEnabled: true, pattern: "holiday-{counter}")
        let report = await BatchRunner.run(items([photo]), pipeline: pipeline, mode: .newFolder(out))
        XCTAssertEqual(report.written.map(\.lastPathComponent), ["holiday-1.jpg", "holiday-1_thumb.jpg"])
    }

    // MARK: Output modes

    func testSameFolderWritesExtrasNextToTheSource() async throws {
        let photo = try source("a.jpg")
        let report = await BatchRunner.run(items([photo]), pipeline: pipeline([threeVariants[0]]),
                                           mode: .sameFolder(suffix: "_new"))
        XCTAssertEqual(report.written.map(\.lastPathComponent), ["a_new.jpg", "a_thumb.jpg"])
        XCTAssertTrue(exists(photo))
    }

    func testOverwriteInPlaceReplacesTheOriginalOnceAndTrashesNothing() async throws {
        let photo = try source("a.jpg")
        let other = root.appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: other)
        let (trash, trashed) = recordingTrash()
        let report = await BatchRunner.run(items([photo]), pipeline: pipeline(threeVariants), mode: .overwrite,
                                           trash: trash)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(trashed.values, [])
        XCTAssertEqual(report.written.map { $0.path.replacingOccurrences(of: root.path + "/", with: "") },
                       ["a.jpg", "a_thumb.jpg", "a_half.png", "small/a-tall.heic"])
        XCTAssertTrue(exists(photo))
        XCTAssertTrue(exists(other))
    }

    func testOverwriteWithANewFormatTrashesTheOriginalOnceAfterTheExtras() async throws {
        let photo = try source("a.jpg")
        let (recording, trashed) = recordingTrash()
        // When the original goes to the Trash, the main output and the extra output are already saved.
        let thumb = root.appendingPathComponent("a_thumb.jpg"), primary = root.appendingPathComponent("a.png")
        let savedFirst = LockedLog<Bool>()
        let trash: Trasher = { url in
            savedFirst.append(FileManager.default.fileExists(atPath: thumb.path)
                              && FileManager.default.fileExists(atPath: primary.path))
            try recording(url)
        }
        let report = await BatchRunner.run(items([photo]), pipeline: pipeline([threeVariants[0]], format: .png),
                                           mode: .overwrite, trash: trash)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(trashed.values, [photo])
        XCTAssertEqual(savedFirst.values, [true])
        XCTAssertEqual(report.written.map(\.lastPathComponent), ["a.png", "a_thumb.jpg"])
        XCTAssertTrue(report.written.allSatisfy(exists))
        XCTAssertFalse(exists(photo))
    }

    func testTrashFailureKeepsEveryOutputWithAWarning() async throws {
        let photo = try source("a.jpg")
        let report = await BatchRunner.run(items([photo]), pipeline: pipeline([threeVariants[0]], format: .png),
                                           mode: .overwrite, trash: { _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.written.map(\.lastPathComponent), ["a.png", "a_thumb.jpg"])
        XCTAssertTrue(report.entries[0].note?.hasPrefix(FileCommitter.trashFailurePrefix) == true)
        XCTAssertTrue(exists(photo))
    }

    // MARK: Collisions

    func testExistingFilesAndOtherSourcesAreNeverReplaced() async throws {
        let photo = try source("a.jpg")
        // A file already there, and another source that has the extra output's name.
        let existing = root.appendingPathComponent("a_half.png")
        try Data("keep".utf8).write(to: existing)
        let namesake = try source("a_thumb.jpg")
        let report = await BatchRunner.run(items([photo, namesake]), pipeline: pipeline(Array(threeVariants.prefix(2))),
                                           mode: .sameFolder(suffix: "_new"))
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.written.map(\.lastPathComponent),
                       ["a_new.jpg", "a_thumb_2.jpg", "a_half_2.png", "a_thumb_new.jpg", "a_thumb_thumb.jpg",
                        "a_thumb_half.png"])
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8))
    }

    func testTwoSourcesWithTheSameNameGetNumberedExtras() async throws {
        let first = try source("a.jpg", in: root.appendingPathComponent("one"))
        let second = try source("a.jpg", in: root.appendingPathComponent("two"))
        let report = await BatchRunner.run(items([first, second]), pipeline: pipeline([threeVariants[0]]),
                                           mode: .newFolder(out))
        XCTAssertEqual(report.written.map(\.lastPathComponent), ["a.jpg", "a_thumb.jpg", "a_2.jpg", "a_thumb_2.jpg"])
    }

    func testDryRunListsEveryVariant() async throws {
        let photo = try source("a.jpg")
        let planned = await BatchRunner.plan(items([photo]), pipeline: pipeline(threeVariants), mode: .newFolder(out))
        XCTAssertEqual(planned?.first?.variants.map(\.destination.lastPathComponent),
                       ["a_thumb.jpg", "a_half.png", "a-tall.heic"])
        XCTAssertFalse(exists(out))
    }

    // MARK: Conditions

    func testSkipExtraOutputsActionWritesOnlyThePrimary() async throws {
        let wide = try source("wide.jpg", width: 900, height: 100)
        let small = try source("small.jpg", width: 300, height: 100)
        var pipeline = pipeline([threeVariants[0]])
        pipeline.steps = [PipelineStep(operation: .condition(ConditionalStep(
            conditions: [.longestEdge(.lessThan, 500)], then: [.skipExtraOutputs])))]
        let report = await BatchRunner.run(items([wide, small]), pipeline: pipeline, mode: .newFolder(out))
        XCTAssertEqual(report.written.map(\.lastPathComponent), ["wide.jpg", "wide_thumb.jpg", "small.jpg"])
        XCTAssertEqual(report.convertedCount, 2)
    }

    func testOutputOverrideReplacesOnlyThePrimary() async throws {
        let photo = try source("a.jpg")
        var pipeline = pipeline([threeVariants[0]])
        pipeline.steps = [PipelineStep(operation: .condition(ConditionalStep(
            conditions: [.longestEdge(.greaterThan, 1)], then: [.output(OutputSettings(format: .png))])))]
        let report = await BatchRunner.run(items([photo]), pipeline: pipeline, mode: .newFolder(out))
        XCTAssertEqual(report.written.map(\.lastPathComponent), ["a.png", "a_thumb.jpg"])
    }

    func testACopiedOriginalHasNoExtras() async throws {
        let photo = try source("a.jpg")
        var pipeline = pipeline([threeVariants[0]])
        pipeline.steps = [PipelineStep(operation: .condition(ConditionalStep(
            conditions: [.longestEdge(.greaterThan, 1)], then: [.copyOriginal])))]
        let report = await BatchRunner.run(items([photo]), pipeline: pipeline, mode: .newFolder(out))
        XCTAssertEqual(report.written.map(\.lastPathComponent), ["a.jpg"])
    }

    func testSkipExtraOutputsSummary() {
        XCTAssertEqual(ConditionalAction.skipExtraOutputs.summary, "skip extra outputs")
        XCTAssertTrue(ConditionalAction.skipExtraOutputs.isValid)
    }

    // MARK: Failures

    func testAFailingPrimaryWritesNoExtras() async throws {
        let photo = try source("a.jpg")
        var pipeline = pipeline([threeVariants[0]])
        pipeline.output.compression = .maxSize(bytes: 1)
        let report = await BatchRunner.run(items([photo]), pipeline: pipeline, mode: .newFolder(out))
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.written, [])
        XCTAssertFalse(exists(out.appendingPathComponent("a_thumb.jpg")))
    }

    func testAFailingExtraIsANoteAndTheOthersCarryOn() async throws {
        let photo = try source("a.jpg")
        var broken = threeVariants[0]
        broken.name = "Tiny"
        broken.nameSuffix = "_tiny"
        broken.settings.compression = .maxSize(bytes: 1)
        let report = await BatchRunner.run(items([photo]), pipeline: pipeline([broken, threeVariants[1]]),
                                           mode: .newFolder(out))
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.written.map(\.lastPathComponent), ["a.jpg", "a_half.png"])
        XCTAssertTrue(report.entries[0].note?.contains("Extra output “Tiny” failed") == true, "\(report.entries[0].note ?? "")")
    }

    func testInvalidVariantsBuiltInCodeAreLeftOutWithANote() async throws {
        let photo = try source("a.jpg")
        let report = await BatchRunner.run(items([photo]), pipeline: pipeline([threeVariants[0], threeVariants[0]]),
                                           mode: .newFolder(out))
        XCTAssertEqual(report.written.map(\.lastPathComponent), ["a.jpg", "a_thumb.jpg"])
        XCTAssertTrue(report.entries[0].note?.contains("left out") == true)
    }

    // MARK: Report and estimate

    func testReportGroupsExtrasUnderTheirSource() async throws {
        let first = try source("a.jpg")
        let second = try source("b.jpg")
        let batch = await BatchRunner.run(items([first, second]), pipeline: pipeline([threeVariants[0]]),
                                          mode: .newFolder(out))
        let report = ProcessingReport(batch: batch, total: 2, outputMode: "newFolder")
        XCTAssertEqual(report.entries.map { ($0.destination as NSString?)?.lastPathComponent },
                       ["a.jpg", "a_thumb.jpg", "b.jpg", "b_thumb.jpg"])
        XCTAssertEqual(report.summary.succeeded, 2)
        XCTAssertEqual(report.entries.map(\.name), ["a.jpg", "a.jpg + Thumbnail", "b.jpg", "b.jpg + Thumbnail"])
        XCTAssertEqual(report.summary.inputBytes, (BatchRunner.fileSize(first) ?? 0) + (BatchRunner.fileSize(second) ?? 0))
        XCTAssertEqual(report.summary.outputBytes, batch.entries.reduce(0) { $0 + $1.outputBytes })
        let csv = ReportExporter.csv(report)
        XCTAssertTrue(csv.contains(#","Thumbnail""#), csv)
    }

    func testEstimateMatchesTheBatchPerVariant() async throws {
        let photo = try source("a.jpg")
        let variants = [threeVariants[0], threeVariants[2]]
        let preview = try SizeEstimator.render(item: items([photo])[0], pipeline: pipeline(variants))
        let report = await BatchRunner.run(items([photo]), pipeline: pipeline(variants), mode: .newFolder(out))
        XCTAssertEqual(preview.bytes, report.entries[0].outputBytes)
        XCTAssertEqual(preview.variants.map(\.bytes), report.entries.dropFirst().map(\.outputBytes))
        XCTAssertEqual(preview.variants.map(\.name), ["Thumbnail", "Tall"])
        let line = SizeEstimator.variantLine(primary: preview.bytes, variants: preview.variants) ?? ""
        XCTAssertTrue(line.hasPrefix("Primary "), line)
        XCTAssertTrue(line.contains(" · Thumbnail "), line)
    }

    func testPeakPixelsCountTheResizedCopies() {
        let plain = pipeline([])
        let withVariant = pipeline([OutputVariant(resize: .percent(200), nameSuffix: "_x2")])
        let base = plain.peakPixelsWithVariants(sourceWidth: 1000, sourceHeight: 1000)
        XCTAssertEqual(base, plain.peakPixels(sourceWidth: 1000, sourceHeight: 1000))
        XCTAssertGreaterThanOrEqual(withVariant.peakPixelsWithVariants(sourceWidth: 1000, sourceHeight: 1000),
                                    1_000_000 + 4_000_000)
    }

    func testPreviewListsTheExtraOutputs() async throws {
        let photo = try source("a.jpg")
        let outcome = await PreviewRenderer().render(item: items([photo])[0], index: 0, pipeline: pipeline(threeVariants),
                                                     mode: .newFolder(out))
        guard case .ready(let result) = outcome else { return XCTFail("no preview") }
        XCTAssertEqual(result.outputName, "a.jpg")
        XCTAssertEqual(result.extraOutputNames, ["Thumbnail: a_thumb.jpg", "Half: a_half.png", "Tall: small/a-tall.heic"])
    }

    // MARK: Lossless copies

    func testAMetadataOnlyVariantInTheSourceFormatIsCopiedLosslessly() async throws {
        let photo = try source("a.jpg")
        var pipeline = pipeline([OutputVariant(name: "Clean", settings: OutputSettings(format: .jpeg), resize: nil,
                                               nameSuffix: "_clean")])
        pipeline.metadata = MetadataOptions(isEnabled: true, removeLocation: true)
        let report = await BatchRunner.run(items([photo]), pipeline: pipeline, mode: .newFolder(out))
        XCTAssertEqual(report.entries.map(\.note), [LosslessMetadata.pixelsUntouchedNote,
                                                    LosslessMetadata.pixelsUntouchedNote])
    }
}
