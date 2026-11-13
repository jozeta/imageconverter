import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

final class PreviewRendererTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try TestImages.tempDir() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func item(_ name: String, width: Int = 800, height: Int = 600) throws -> InputItem {
        let url = dir.appendingPathComponent(name)
        try TestImages.write(TestImages.make(width: width, height: height), to: url, type: .png)
        return InputItem(source: url, relativeDirectory: "")
    }

    private func ready(_ outcome: PreviewOutcome, file: StaticString = #filePath, line: UInt = #line) throws
        -> PreviewResult {
        guard case .ready(let result) = outcome else {
            XCTFail("Expected ready, got \(outcome)", file: file, line: line)
            throw CocoaError(.fileReadUnknown)
        }
        return result
    }

    func testResizeGivesOutputSizeAndFitsDisplayMax() async throws {
        let pipeline = Pipeline(steps: [PipelineStep(operation: .resize(ResizeOptions(mode: .maxWidth(400))))],
                                output: .init(format: .jpeg))
        let renderer = PreviewRenderer(displayMax: 300)
        let result = try ready(await renderer.render(item: try item("a.png"), index: 0, pipeline: pipeline))
        XCTAssertEqual(result.outputSize.0, 400)
        XCTAssertEqual(result.outputSize.1, 300)
        XCTAssertEqual(result.sourceSize.0, 800)
        XCTAssertLessThanOrEqual(max(result.after.width, result.after.height), 300)
        XCTAssertLessThanOrEqual(max(result.before.width, result.before.height), 300)
        XCTAssertEqual(result.sourceName, "a.png")
        XCTAssertEqual(result.outputName, "a.jpg")
    }

    func testRenamePatternGivesOutputName() async throws {
        var pipeline = Pipeline(output: .init(format: .jpeg))
        pipeline.rename = RenameOptions(isEnabled: true, pattern: "trip_{counter:00}", counterStart: 1)
        let result = try ready(await PreviewRenderer().render(item: try item("a.png"), index: 0, pipeline: pipeline))
        XCTAssertEqual(result.outputName, "trip_01.jpg")
        let second = try ready(await PreviewRenderer().render(item: try item("b.png"), index: 2, pipeline: pipeline))
        XCTAssertEqual(second.outputName, "trip_03.jpg")
    }

    func testMissingWatermarkImageFails() async throws {
        let options = WatermarkOptions(content: .image(ImageWatermark(path: dir.appendingPathComponent("no.png").path)))
        let pipeline = Pipeline(steps: [PipelineStep(operation: .watermark(options))], output: .init(format: .png))
        let outcome = await PreviewRenderer().render(item: try item("a.png"), index: 0, pipeline: pipeline)
        guard case .failed(let reason) = outcome else { return XCTFail("Expected failure") }
        XCTAssertEqual(reason, "Couldn't read the watermark image")
    }

    func testUnreadableSourceFailsWithLoaderReason() async throws {
        let url = dir.appendingPathComponent("bad.png")
        try Data("not an image".utf8).write(to: url)
        let outcome = await PreviewRenderer().render(
            item: InputItem(source: url, relativeDirectory: ""), index: 0, pipeline: Pipeline())
        guard case .failed(let reason) = outcome else { return XCTFail("Expected failure") }
        XCTAssertEqual(reason, ConversionError.unreadable.reason)
    }

    func testSourceIsDecodedOncePerURL() async throws {
        let renderer = PreviewRenderer()
        let first = try item("a.png")
        _ = await renderer.render(item: first, index: 0, pipeline: Pipeline())
        var changed = Pipeline()
        changed.output = .init(format: .png)
        _ = await renderer.render(item: first, index: 0, pipeline: changed)
        var count = await renderer.decodeCount
        XCTAssertEqual(count, 1)
        _ = await renderer.render(item: try item("b.png"), index: 1, pipeline: changed)
        count = await renderer.decodeCount
        XCTAssertEqual(count, 2)
    }

    func testCancellationNeverCrashes() async throws {
        let url = dir.appendingPathComponent("big.png")
        try TestImages.write(TestImages.noise(width: 3000, height: 3000), to: url, type: .png)
        let source = InputItem(source: url, relativeDirectory: "")
        let renderer = PreviewRenderer()
        let task = Task { await renderer.render(item: source, index: 0, pipeline: Pipeline()) }
        task.cancel()
        switch await task.value {
        case .failed(let reason): XCTAssertEqual(reason, "Cancelled")
        case .ready: break
        }
    }

    func testCancelledBeforeStartReturnsCancelled() async throws {
        let source = try item("a.png")
        let renderer = PreviewRenderer()
        let task = Task { () -> PreviewOutcome in
            while !Task.isCancelled { await Task.yield() }
            return await renderer.render(item: source, index: 0, pipeline: Pipeline())
        }
        task.cancel()
        guard case .failed(let reason) = await task.value else { return XCTFail("Expected cancelled") }
        XCTAssertEqual(reason, "Cancelled")
    }

    /// Milestone 4 park: in overwrite mode the watermark logo may itself be an input. The logo is
    /// decoded before any write, so every stamp is the original logo.
    func testOverwriteWithWatermarkFileAmongInputs() async throws {
        let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        let logoURL = dir.appendingPathComponent("logo.png")
        try TestImages.write(TestImages.make(width: 100, height: 50, color: red), to: logoURL, type: .png)
        let other = dir.appendingPathComponent("other.png")
        try TestImages.write(TestImages.make(width: 400, height: 300, color: CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
                             to: other, type: .png)
        let options = WatermarkOptions(content: .image(ImageWatermark(path: logoURL.path)), anchor: .bottomRight,
                                       sizePercent: 20, opacity: 1, marginPercent: 0)
        let pipeline = Pipeline(steps: [PipelineStep(operation: .watermark(options))], output: .init(format: .png))
        let items = [InputItem(source: logoURL, relativeDirectory: ""), InputItem(source: other, relativeDirectory: "")]
        let report = await BatchRunner.run(items, pipeline: pipeline, mode: .overwrite, concurrency: 1,
                                           trash: { url in try FileManager.default.removeItem(at: url) })
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        XCTAssertEqual(report.written.count, 2)
        let data = try Data(contentsOf: other)
        let pixel = try TestImages.pixel(of: data, x: 399, y: 299)
        XCTAssertGreaterThan(pixel.red, 200)
        XCTAssertLessThan(pixel.blue, 60)
    }
}
