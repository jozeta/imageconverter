import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

final class FileStepsBatchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func source(_ name: String, width: Int = 40, height: Int = 20, type: UTType = .jpeg,
                        properties: [String: Any] = [:]) throws -> URL {
        let url = root.appendingPathComponent(name)
        try TestImages.write(TestImages.make(width: width, height: height), to: url, type: type, properties: properties)
        return url
    }

    private func contains(_ data: Data, _ secret: String) -> Bool {
        data.range(of: Data(secret.utf8)) != nil
    }

    private var out: URL { root.appendingPathComponent("out", isDirectory: true) }

    private func names(_ report: BatchReport) -> [String] { report.written.map { $0.lastPathComponent } }

    // MARK: metadata

    private var locationProps: [String: Any] {
        [kCGImagePropertyGPSDictionary as String: [
            kCGImagePropertyGPSLatitude as String: 59.3, kCGImagePropertyGPSLatitudeRef as String: "N",
            kCGImagePropertyGPSLongitude as String: 18.0, kCGImagePropertyGPSLongitudeRef as String: "E",
            kCGImagePropertyGPSMapDatum as String: "SECRETPLACE-42"
        ] as [String: Any],
         kCGImagePropertyIPTCDictionary as String: [kCGImagePropertyIPTCCity as String: "SECRETCITY"]]
    }

    private func assertNoLocationLeak(options: MetadataOptions, format: OutputFormat, file: StaticString = #filePath,
                                      line: UInt = #line) async throws {
        let url = try source("loc.jpg", properties: locationProps)
        let original = try Data(contentsOf: url)
        XCTAssertTrue(contains(original, "SECRETPLACE-42"), "source must hold the secret", file: file, line: line)
        XCTAssertTrue(contains(original, "SECRETCITY"), "source must hold the secret", file: file, line: line)

        var pipeline = Pipeline(output: .init(format: format))
        pipeline.metadata = options
        let report = await BatchRunner.run(InputCollector.collect([url]), pipeline: pipeline, mode: .newFolder(out))
        XCTAssertEqual(report.failures, [], file: file, line: line)
        let written = try XCTUnwrap(report.written.first, file: file, line: line)
        let data = try Data(contentsOf: written)
        XCTAssertNil(try TestImages.properties(of: data)[kCGImagePropertyGPSDictionary as String], file: file, line: line)
        XCTAssertFalse(contains(data, "SECRETPLACE-42"), file: file, line: line)
        XCTAssertFalse(contains(data, "SECRETCITY"), file: file, line: line)
    }

    func testGPSNeverLeaks() async throws {
        try await assertNoLocationLeak(options: MetadataOptions(isEnabled: true, removeLocation: true), format: .jpeg)
        try? FileManager.default.removeItem(at: out)
        try await assertNoLocationLeak(options: MetadataOptions(isEnabled: true, removeAll: true), format: .heic)
    }

    func testCameraNeverLeaks() async throws {
        let props: [String: Any] = [kCGImagePropertyTIFFDictionary as String: [
            kCGImagePropertyTIFFModel as String: "SECRETCAM", kCGImagePropertyTIFFMake as String: "SECRETMAKE"
        ]]
        let url = try source("cam.jpg", properties: props)
        XCTAssertTrue(contains(try Data(contentsOf: url), "SECRETCAM"))
        var pipeline = Pipeline(output: .init(format: .jpeg))
        pipeline.metadata = MetadataOptions(isEnabled: true, removeLocation: false, removeCamera: true)
        let report = await BatchRunner.run(InputCollector.collect([url]), pipeline: pipeline, mode: .newFolder(out))
        XCTAssertEqual(report.failures, [])
        let data = try Data(contentsOf: try XCTUnwrap(report.written.first))
        XCTAssertFalse(contains(data, "SECRETCAM"))
        XCTAssertFalse(contains(data, "SECRETMAKE"))
    }

    // MARK: rename

    private func renamePipeline(_ pattern: String, start: Int = 1, steps: [PipelineStep] = []) -> Pipeline {
        var pipeline = Pipeline(steps: steps, output: .init(format: .jpeg))
        pipeline.rename = RenameOptions(isEnabled: true, pattern: pattern, counterStart: start)
        return pipeline
    }

    func testRenameWithCounter() async throws {
        let files = try (1...3).map { try source("img\($0).jpg") }
        let report = await BatchRunner.run(InputCollector.collect(files), pipeline: renamePipeline("trip_{counter:00}"),
                                           mode: .newFolder(out))
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(names(report), ["trip_01.jpg", "trip_02.jpg", "trip_03.jpg"])
    }

    func testRenameCollisions() async throws {
        let files = try (1...4).map { try source("img\($0).jpg") }
        let report = await BatchRunner.run(InputCollector.collect(files), pipeline: renamePipeline("same"),
                                           mode: .newFolder(out))
        XCTAssertEqual(names(report), ["same.jpg", "same_2.jpg", "same_3.jpg", "same_4.jpg"])
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: out.path)
        XCTAssertEqual(onDisk.count, 4)
    }

    func testWidthTokenMatchesOutput() async throws {
        let url = try source("big.jpg", width: 400, height: 200)
        let step = PipelineStep(operation: .resize(ResizeOptions(mode: .maxWidth(100))))
        let report = await BatchRunner.run(InputCollector.collect([url]),
                                           pipeline: renamePipeline("{width}x{height}", steps: [step]),
                                           mode: .newFolder(out))
        XCTAssertEqual(names(report), ["100x50.jpg"])
        let header = try XCTUnwrap(ImageLoader.header(of: try XCTUnwrap(report.written.first)))
        XCTAssertEqual(header.width, 100)
        XCTAssertEqual(header.height, 50)
    }

    func testSameFolderWithRenameHasNoSuffix() async throws {
        let url = try source("a.jpg")
        let report = await BatchRunner.run(InputCollector.collect([url]), pipeline: renamePipeline("renamed"),
                                           mode: .sameFolder(suffix: "_converted"))
        XCTAssertEqual(report.written, [root.appendingPathComponent("renamed.jpg")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testOverwriteRenameTrashesOriginal() async throws {
        let url = try source("a.jpg")
        let trashed = LockedLog<URL>()
        let trash: Trasher = { trashed.append($0) }
        let report = await BatchRunner.run(InputCollector.collect([url]), pipeline: renamePipeline("renamed"),
                                           mode: .overwrite, trash: trash)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.written, [root.appendingPathComponent("renamed.jpg")])
        XCTAssertEqual(trashed.values, [url])
    }

    func testPlannerIgnoresMismatchedBaseNames() {
        let items = [InputItem(source: root.appendingPathComponent("a.png"), relativeDirectory: "")]
        let plans = OutputPlanner.plan(items, format: .jpeg, mode: .newFolder(out), baseNames: ["x", "y"],
                                       fileExists: { _ in false })
        XCTAssertEqual(plans.map { $0.destination.lastPathComponent }, ["a.jpg"])
    }

    func testOutputSizeFollowsEnabledSteps() {
        var disabled = PipelineStep(operation: .rotateFlip(RotateFlipOptions(rotation: .cw90)))
        disabled.isEnabled = false
        let pipe = Pipeline(steps: [PipelineStep(operation: .resize(ResizeOptions(mode: .maxWidth(100)))), disabled])
        let size = pipe.outputSize(sourceWidth: 400, sourceHeight: 200)
        XCTAssertEqual(size.width, 100)
        XCTAssertEqual(size.height, 50)
    }
}
