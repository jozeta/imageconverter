import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

/// Conditions in the batch: file safety, naming, jobs, cancellation and the estimate.
final class ConditionalBatchSafetyTests: XCTestCase {
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
        XCTAssertEqual(second.report.summary.unchanged, 2)
        XCTAssertEqual(second.report.summary.skipped, 0, "unchanged files aren't counted as skipped by a condition")
        XCTAssertEqual(second.batch.order, [])
    }

    // MARK: Safety and naming

    func testCopyRenameTokensDescribeTheSource() async throws {
        let small = try source("small.JPEG", width: 8, height: 6)
        let resize = PipelineStep(operation: .resize(ResizeOptions(mode: .longestEdge(100), allowEnlarge: true)))
        var conditional = pipeline(ConditionalStep(conditions: [.width(.atLeast, 0)], then: [.step(resize), .copyOriginal]),
                                   output: .png)
        conditional.rename = RenameOptions(isEnabled: true, pattern: "{name}_{width}x{height}_{ext}_{format}")
        let report = await BatchRunner.run(items([small]), pipeline: conditional, mode: .newFolder(out))
        XCTAssertEqual(names(report), ["small_8x6_jpeg_JPEG.JPEG"])
        guard case .ready(let preview) = await PreviewRenderer().render(item: items([small])[0], index: 0,
                                                                        pipeline: conditional)
        else { return XCTFail("preview failed") }
        XCTAssertEqual(preview.outputName, "small_8x6_jpeg_JPEG.JPEG")
    }

    func testSameFolderCopyWithEmptySuffix() async throws {
        let photo = try source("a.jpg")
        let original = try Data(contentsOf: photo)
        let report = await BatchRunner.run(
            items([photo]), pipeline: pipeline(ConditionalStep(conditions: [.width(.atLeast, 0)], then: [.copyOriginal])),
            mode: .sameFolder(suffix: ""), trash: noTrash)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(names(report), ["a_2.jpg"])
        XCTAssertEqual(try Data(contentsOf: photo), original)
        XCTAssertEqual(try Data(contentsOf: report.written[0]), original)
    }

    func testOverwriteWithPerItemFormatTrashesOnceAndSparesInPlaceCopy() async throws {
        let jpeg = try source("a.jpg")
        let png = try source("a.png", type: .png)
        let pngBytes = try Data(contentsOf: png)
        let trashed = LockedLog<URL>()
        let conditional = pipeline(ConditionalStep(conditions: [.format(.format(.jpeg))],
                                                   then: [.output(OutputSettings(format: .png))],
                                                   otherwise: [.copyOriginal]))
        let report = await BatchRunner.run(items([jpeg, png]), pipeline: conditional, mode: .overwrite,
                                           trash: { trashed.append($0) })
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(names(report), ["a_2.png", "a.png"])
        XCTAssertEqual(trashed.values, [jpeg], "only the converted original is trashed, once")
        XCTAssertEqual(try Data(contentsOf: png), pngBytes, "the in-place copy is untouched")
    }

    func testSkippedSourceIsNeverATarget() async throws {
        let first = try source("a.jpg")
        let tall = try source("b.jpg", width: 20, height: 40)
        let tallBytes = try Data(contentsOf: tall)
        var conditional = pipeline(ConditionalStep(conditions: [.orientation(.portrait)], then: [.skip]))
        conditional.rename = RenameOptions(isEnabled: true, pattern: "b")
        let report = await BatchRunner.run(items([first, tall]), pipeline: conditional, mode: .sameFolder(suffix: ""))
        XCTAssertEqual(names(report), ["b_2.jpg"])
        XCTAssertEqual(try Data(contentsOf: tall), tallBytes)
    }

    func testCancelDuringFactReading() async throws {
        let urls = try (0..<12).map { try source("p\($0).png", width: 300, height: 300, alpha: 0.5, type: .png) }
        let conditional = pipeline(ConditionalStep(conditions: [.hasTransparency(true)], then: [.copyOriginal]))
        let resolved = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await BatchRunner.resolveAll(items(urls), pipeline: conditional, maxPixels: ImageLoader.defaultMaxPixels)
        }.value
        XCTAssertNil(resolved)
        let report = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await BatchRunner.run(items(urls), pipeline: conditional, mode: .newFolder(out))
        }.value
        XCTAssertTrue(report.cancelled)
        XCTAssertEqual(report.written, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))

        // Not cancelled: facts come back in input order, read a few at a time.
        let all = await BatchRunner.resolveAll(items(urls), pipeline: conditional, maxPixels: ImageLoader.defaultMaxPixels)
        XCTAssertEqual(all?.count, 12)
        XCTAssertEqual(all?.map(\.disposition), Array(repeating: .copyOriginal, count: 12))
    }

    func testCopyEstimateDoesNotDecode() throws {
        let photo = try source("a.jpg", width: 400, height: 400)
        let conditional = pipeline(ConditionalStep(conditions: [.width(.atLeast, 0)], then: [.copyOriginal]))
        // A pixel limit below the image: a decode would throw `tooLarge`.
        let estimate = try SizeEstimator.render(item: items([photo])[0], pipeline: conditional, maxPixels: 10)
        XCTAssertEqual(estimate.bytes, BatchRunner.fileSize(photo))
        XCTAssertNil(estimate.original)
        XCTAssertNil(estimate.encoded)
        XCTAssertEqual(estimate.note, "Copied unchanged")
    }
    /// Final review I3: the same original listed loose and through its folder is processed once in overwrite mode.
    func testDuplicateItemsRunOnceInOverwriteMode() async throws {
        let file = try source("dup.jpg", width: 40, height: 20)
        let rotate = Pipeline(steps: [PipelineStep(operation: .rotateFlip(RotateFlipOptions(rotation: .cw90)))],
                              output: OutputSettings(format: .jpeg))
        let duplicated = [InputItem(source: file, relativeDirectory: ""),
                          InputItem(source: file, relativeDirectory: root.lastPathComponent)]
        let report = await BatchRunner.run(duplicated, pipeline: rotate, mode: .overwrite, trash: noTrash)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.written, [file])
        XCTAssertEqual(ImageLoader.pixelSize(of: file)?.width, 20, "rotated once, not twice")
        let planned = await BatchRunner.plan(duplicated, pipeline: rotate, mode: .overwrite)
        XCTAssertEqual(planned?.count, 1)
    }

    /// Final review I4: a manual run skips, with a note, a file a job (or any other run here) is processing, and
    /// releases its own files when it ends.
    func testRunSkipsSourcesHeldByAnotherRun() async throws {
        let held = try source("held.jpg")
        let free = try source("free.jpg")
        let (claimed, _) = ActiveSources.shared.claim([InputItem(source: held, relativeDirectory: "").pathKey])
        let report = await BatchRunner.run(items([held, free]), pipeline: Pipeline(), mode: .overwrite, trash: noTrash)
        ActiveSources.shared.release(claimed)
        XCTAssertEqual(report.written, [free])
        XCTAssertEqual(report.skipped.map(\.source), [held])
        XCTAssertEqual(report.skipped.first?.reason, ActiveSources.busyReason)
        XCTAssertEqual(report.order, [held, free])
        XCTAssertFalse(ActiveSources.shared.isHeld(free), "released when the run ends")
        XCTAssertFalse(ActiveSources.shared.isHeld(held))
    }
}
