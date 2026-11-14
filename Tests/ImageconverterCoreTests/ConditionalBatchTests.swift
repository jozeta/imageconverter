import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

final class ConditionalBatchTests: XCTestCase {
    private var root: URL!
    private let noTrash: Trasher = { _ in XCTFail("nothing may be trashed") }

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var out: URL { root.appendingPathComponent("out", isDirectory: true) }

    @discardableResult
    private func source(_ name: String, width: Int = 40, height: Int = 20, alpha: CGFloat = 1, type: UTType = .jpeg,
                        properties: [String: Any] = [:]) throws -> URL {
        let url = root.appendingPathComponent(name)
        try TestImages.write(TestImages.make(width: width, height: height, alpha: alpha), to: url, type: type,
                             properties: properties)
        return url
    }

    private func items(_ urls: [URL]) -> [InputItem] { urls.map { InputItem(source: $0, relativeDirectory: "") } }

    private func pipeline(_ conditional: ConditionalStep, output: OutputFormat = .jpeg) -> Pipeline {
        Pipeline(steps: [PipelineStep(operation: .condition(conditional))], output: OutputSettings(format: output))
    }

    private func size(of url: URL) -> (Int, Int)? {
        ImageLoader.pixelSize(of: url).map { ($0.width, $0.height) }
    }

    private func names(_ report: BatchReport) -> [String] { report.written.map(\.lastPathComponent) }

    private let gps: [String: Any] = [kCGImagePropertyGPSDictionary as String: [
        kCGImagePropertyGPSLatitude as String: 59.3, kCGImagePropertyGPSLatitudeRef as String: "N",
        kCGImagePropertyGPSLongitude as String: 18.0, kCGImagePropertyGPSLongitudeRef as String: "E"
    ] as [String: Any]]

    // MARK: Johan's examples

    func testLongestEdgeResize() async throws {
        let big = try source("big.jpg", width: 5000, height: 100)
        let small = try source("small.jpg", width: 3000, height: 100)
        let resize = PipelineStep(operation: .resize(ResizeOptions(mode: .longestEdge(2048))))
        let report = await BatchRunner.run(items([big, small]), pipeline: pipeline(ConditionalStep(
            conditions: [.longestEdge(.greaterThan, 4000)], then: [.step(resize)])), mode: .newFolder(out))
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(names(report), ["big.jpg", "small.jpg"])
        XCTAssertEqual(size(of: report.written[0])?.0, 2048)
        XCTAssertEqual(size(of: report.written[1])?.0, 3000)
    }

    func testPNGWithTransparencyKeepsPNG() async throws {
        let clear = try source("clear.png", alpha: 0.4, type: .png)
        let opaque = try source("opaque.png", type: .png)
        let report = await BatchRunner.run(items([clear, opaque]), pipeline: pipeline(ConditionalStep(
            conditions: [.hasTransparency(true)], then: [.output(OutputSettings(format: .png))])), mode: .newFolder(out))
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(names(report), ["clear.png", "opaque.jpg"])
        let header = try XCTUnwrap(ImageLoader.header(of: report.written[0]))
        XCTAssertEqual(header.properties[kCGImagePropertyHasAlpha as String] as? Bool, true)
    }

    func testJPEGToOtherFormat() async throws {
        // WebP isn't writable here; AVIF (or HEIC, then TIFF) stands in for the example's other format.
        let available = OutputFormat.available()
        let other = [OutputFormat.avif, .heic, .tiff].first(where: available.contains) ?? .tiff
        let jpeg = try source("photo.jpg")
        let png = try source("drawing.png", type: .png)
        let report = await BatchRunner.run(items([jpeg, png]), pipeline: pipeline(ConditionalStep(
            conditions: [.format(.format(.jpeg))], then: [.output(OutputSettings(format: other))]), output: .png),
            mode: .newFolder(out))
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(names(report), ["photo.\(other.fileExtensions[0])", "drawing.png"])
        let written = try XCTUnwrap(CGImageSourceCreateWithURL(report.written[0] as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(written) as String?, other.utType.identifier)
    }

    func testHasGPSRemovesLocation() async throws {
        let located = try source("located.jpg", properties: gps)
        let plain = try source("plain.jpg")
        let strip = MetadataOptions(location: .remove)
        let conditional = pipeline(ConditionalStep(conditions: [.hasGPS(true)], then: [.metadata(strip)]))
        let report = await BatchRunner.run(items([located, plain]), pipeline: conditional, mode: .newFolder(out))
        XCTAssertEqual(report.failures, [])
        let data = try Data(contentsOf: report.written[0])
        XCTAssertNil(try TestImages.properties(of: data)[kCGImagePropertyGPSDictionary as String])

        // Control: without the condition the location goes through.
        let control = await BatchRunner.run(items([located]), pipeline: Pipeline(),
                                            mode: .newFolder(root.appendingPathComponent("control")))
        let kept = try Data(contentsOf: try XCTUnwrap(control.written.first))
        XCTAssertNotNil(try TestImages.properties(of: kept)[kCGImagePropertyGPSDictionary as String])
    }

    func testSmallFileCopiedUnchanged() async throws {
        let small = try source("small.JPEG", width: 8, height: 8)
        let big = try source("big.jpg", width: 400, height: 400, properties: gps)
        let limit = try XCTUnwrap(BatchRunner.fileSize(small)) + 1
        XCTAssertGreaterThan(try XCTUnwrap(BatchRunner.fileSize(big)), limit)
        let conditional = pipeline(ConditionalStep(conditions: [.fileSize(.lessThan, bytes: limit)],
                                                   then: [.copyOriginal]), output: .png)
        let original = try Data(contentsOf: small)
        let report = await BatchRunner.run(items([small, big]), pipeline: conditional, mode: .newFolder(out),
                                           trash: noTrash)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(names(report), ["small.JPEG", "big.png"])
        XCTAssertEqual(try Data(contentsOf: report.written[0]), original, "bytes identical")
        XCTAssertEqual(report.entries[0].note, "Copied unchanged")
        XCTAssertEqual(report.entries[0].outputBytes, original.count)

        // Overwrite mode: a copy in place is a no-op success; nothing is replaced or trashed.
        let before = try FileManager.default.attributesOfItem(atPath: small.path)[.modificationDate] as? Date
        let inPlace = await BatchRunner.run(items([small]), pipeline: conditional, mode: .overwrite, trash: noTrash)
        XCTAssertEqual(inPlace.written, [small])
        XCTAssertEqual(try Data(contentsOf: small), original)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: small.path)[.modificationDate] as? Date, before)
    }

    func testSkipWritesNothingAndCountsSkipped() async throws {
        let first = try source("a.jpg", width: 40, height: 20)
        let tall = try source("b.jpg", width: 20, height: 40)
        let last = try source("c.jpg", width: 40, height: 20)
        let log = LockedLog<BatchProgress>()
        let report = await BatchRunner.run(
            items([first, tall, last]),
            pipeline: pipeline(ConditionalStep(conditions: [.orientation(.portrait)], then: [.skip])),
            mode: .newFolder(out), progress: { log.append($0) })
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(names(report), ["a.jpg", "c.jpg"])
        XCTAssertEqual(report.skipped, [BatchSkip(source: tall, inputBytes: BatchRunner.fileSize(tall))])
        XCTAssertEqual(report.order, [first, tall, last])
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("b.jpg").path))
        XCTAssertEqual(log.values.map(\.completed).max(), 3)
        XCTAssertEqual(log.values.last?.total, 3)

        let processing = ProcessingReport(batch: report, total: 3, outputMode: "newFolder")
        XCTAssertEqual(processing.summary.succeeded, 2)
        XCTAssertEqual(processing.summary.skipped, 1)
        XCTAssertEqual(processing.summary.failed, 0)
        XCTAssertEqual(processing.summary.cancelled, 0)
        XCTAssertEqual(processing.entries.map(\.status), [.succeeded, .skipped, .succeeded])
        XCTAssertEqual(processing.entries[1].note, "Skipped by a condition")
    }

    func testCounterSkipsSkippedItems() async throws {
        let first = try source("a.jpg")
        let tall = try source("b.jpg", width: 20, height: 40)
        let last = try source("c.jpg")
        var conditional = pipeline(ConditionalStep(conditions: [.orientation(.portrait)], then: [.skip]))
        conditional.rename = RenameOptions(isEnabled: true, pattern: "img_{counter}")
        let report = await BatchRunner.run(items([first, tall, last]), pipeline: conditional, mode: .newFolder(out))
        XCTAssertEqual(names(report), ["img_1.jpg", "img_2.jpg"])
    }

    func testRenameOverrideAppliesPerItem() async throws {
        let first = try source("a.jpg")
        let tall = try source("b.jpg", width: 20, height: 40)
        let conditional = pipeline(ConditionalStep(conditions: [.orientation(.portrait)],
                                                   then: [.rename(RenameOptions(pattern: "portrait_{name}"))]))
        let report = await BatchRunner.run(items([first, tall]), pipeline: conditional, mode: .newFolder(out))
        XCTAssertEqual(names(report), ["a.jpg", "portrait_b.jpg"])
    }

    // MARK: Preview and estimate

    func testPreviewAndEstimateUseResolvedPipeline() async throws {
        let big = try source("big.jpg", width: 600, height: 300)
        let tall = try source("tall.jpg", width: 20, height: 40)
        let resize = PipelineStep(operation: .resize(ResizeOptions(mode: .longestEdge(100))))
        var conditional = pipeline(ConditionalStep(
            conditions: [.orientation(.landscape)],
            then: [.step(resize), .output(OutputSettings(format: .png))], otherwise: [.skip]))
        let renderer = PreviewRenderer()

        guard case .ready(let preview) = await renderer.render(item: items([big])[0], index: 0, pipeline: conditional)
        else { return XCTFail("preview failed") }
        XCTAssertEqual(preview.outputSize.0, 100)
        XCTAssertEqual(preview.outputName, "big.png")
        XCTAssertEqual(preview.disposition, .process)

        guard case .ready(let skipped) = await renderer.render(item: items([tall])[0], index: 1, pipeline: conditional)
        else { return XCTFail("preview failed") }
        XCTAssertEqual(skipped.disposition, .skip)
        XCTAssertEqual(skipped.statusNote, "Skipped by a condition")
        XCTAssertEqual(skipped.outputSize.0, 20)

        let estimate = try SizeEstimator.render(item: items([big])[0], pipeline: conditional)
        XCTAssertEqual(estimate.encoded.width, 100)
        XCTAssertNotNil(estimate.note, "PNG estimate is unoptimised, so the format override reached it")
        XCTAssertThrowsError(try SizeEstimator.render(item: items([tall])[0], pipeline: conditional)) {
            XCTAssertEqual($0 as? ConversionError, .skippedByCondition)
        }
        XCTAssertTrue(try QualityLadder.render(item: items([tall])[0], pipeline: conditional).isEmpty)

        conditional.steps[0].operation = .condition(ConditionalStep(conditions: [.orientation(.portrait)],
                                                                    then: [.copyOriginal]))
        let copied = try SizeEstimator.render(item: items([tall])[0], pipeline: conditional)
        XCTAssertEqual(copied.bytes, BatchRunner.fileSize(tall))
        XCTAssertEqual(copied.note, "Copied unchanged")
        guard case .ready(let copyPreview) = await renderer.render(item: items([tall])[0], index: 0,
                                                                   pipeline: conditional)
        else { return XCTFail("preview failed") }
        XCTAssertEqual(copyPreview.statusNote, "Copied unchanged")
        XCTAssertEqual(copyPreview.outputName, "tall.jpg")
    }

    // MARK: Jobs

    func testJobRecordsSkippedAndCopiedAsProcessed() async throws {
        let input = root.appendingPathComponent("Drop", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try TestImages.write(TestImages.make(width: 20, height: 40), to: input.appendingPathComponent("tall.jpg"),
                             type: .jpeg)
        try TestImages.write(TestImages.make(width: 40, height: 20), to: input.appendingPathComponent("wide.jpg"),
                             type: .jpeg)
        let store = JobStore(directory: root.appendingPathComponent("jobs", isDirectory: true))
        let conditional = pipeline(ConditionalStep(conditions: [.orientation(.portrait)], then: [.skip],
                                                   otherwise: [.copyOriginal]))
        let job = Job(name: "Sort", pipeline: conditional, inputs: [input], output: .newFolder(out), trigger: .watch)
        let first = await JobRunner.run(job, store: store, trash: noTrash, now: { Date().addingTimeInterval(10) })
        XCTAssertEqual(first.batch.written.count, 1)
        XCTAssertEqual(first.batch.skipped.count, 1)
        XCTAssertEqual(first.report.summary.skipped, 1)
        let second = await JobRunner.run(job, store: store, trash: noTrash, now: { Date().addingTimeInterval(10) })
        XCTAssertEqual(second.unchanged, 2, "skipped and copied files aren't evaluated again")
        XCTAssertEqual(second.batch.order, [])
    }
}
