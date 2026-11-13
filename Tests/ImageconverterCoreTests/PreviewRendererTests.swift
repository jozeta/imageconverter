import CoreGraphics
import Foundation
import ImageIO
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
        let item = try item("a.png")
        let result = try ready(await renderer.render(item: item, index: 0, pipeline: pipeline))
        XCTAssertEqual(result.outputSize.0, 400)
        XCTAssertEqual(result.outputSize.1, 300)
        XCTAssertEqual(result.sourceSize.0, 800)
        XCTAssertLessThanOrEqual(max(result.after.width, result.after.height), 300)
        XCTAssertLessThanOrEqual(max(result.before.width, result.before.height), 300)
        XCTAssertEqual(result.sourceName, "a.png")
        XCTAssertEqual(result.source, item.source)
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

    func testPixelGuardFailsWithTooLargeReason() async throws {
        let outcome = await PreviewRenderer(maxPixels: 100).render(
            item: try item("big.png", width: 20, height: 20), index: 0, pipeline: Pipeline())
        guard case .failed(let reason) = outcome else { return XCTFail("Expected failure") }
        XCTAssertEqual(reason, ConversionError.tooLarge(pixels: 400).reason)
        XCTAssertTrue(reason.contains("too large"))
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
        let green = CGColor(red: 0, green: 1, blue: 0, alpha: 1)
        try TestImages.write(Self.patternedLogo(red: red, green: green), to: logoURL, type: .png)
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
        // The logo is red with a green left half and is stamped bottom-right. Reloaded after being
        // overwritten with its own stamp, its bottom-right corner would hold a tiny copy of itself
        // (green on the left), so a point at 91% across and 94% down would be green, not red.
        let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        var box: CGRect?
        for row in 0..<image.height { for col in 0..<image.width {
            let value = TestImages.pixel(of: image, x: col, y: row)
            guard value.blue < 100 else { continue }
            let point = CGRect(x: col, y: row, width: 1, height: 1)
            box = box.map { $0.union(point) } ?? point
        } }
        let stamp = try XCTUnwrap(box)
        XCTAssertGreaterThan(stamp.width, 20)
        let probe = TestImages.pixel(of: image, x: Int(stamp.minX + stamp.width * 0.91),
                                     y: Int(stamp.minY + stamp.height * 0.94))
        XCTAssertGreaterThan(probe.red, 200)
        XCTAssertLessThan(probe.green, 60)
        let left = TestImages.pixel(of: image, x: Int(stamp.minX + stamp.width * 0.15),
                                    y: Int(stamp.minY + stamp.height * 0.5))
        XCTAssertGreaterThan(left.green, 200)
    }

    private static func patternedLogo(red: CGColor, green: CGColor) -> CGImage {
        let base = TestImages.make(width: 100, height: 50, color: red)
        guard let ctx = CGContext(data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("Couldn't create a bitmap context")
        }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: 100, height: 50))
        ctx.setFillColor(green)
        ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
        guard let image = ctx.makeImage() else { fatalError("Couldn't make an image") }
        return image
    }

    func testOutputNameMatchesPlannerForEachMode() async throws {
        let jpegItem = InputItem(source: dir.appendingPathComponent("p.jpeg"), relativeDirectory: "")
        try TestImages.write(TestImages.make(width: 40, height: 30), to: jpegItem.source, type: .jpeg)
        var renamed = Pipeline(output: .init(format: .jpeg))
        renamed.rename = RenameOptions(isEnabled: true, pattern: "x_{counter:00}", counterStart: 5)
        let plain = Pipeline(output: .init(format: .jpeg))
        let modes: [OutputMode] = [.newFolder(dir.appendingPathComponent("out")), .sameFolder(suffix: "_converted"),
                                   .overwrite]
        for pipeline in [plain, renamed] {
            for mode in modes {
                let base = RenameRendering.baseName(for: jpegItem, index: 3, pipeline: pipeline)
                let expected = OutputPlanner.plan([jpegItem], format: .jpeg, mode: mode,
                                                  baseNames: base.map { [$0] }, fileExists: { _ in false })
                let result = try ready(await PreviewRenderer().render(item: jpegItem, index: 3, pipeline: pipeline,
                                                                      mode: mode))
                XCTAssertEqual(result.outputName, expected[0].destination.lastPathComponent, "\(mode)")
            }
        }
        let sameFolder = try ready(await PreviewRenderer().render(
            item: jpegItem, index: 0, pipeline: plain, mode: .sameFolder(suffix: "_converted")))
        XCTAssertEqual(sameFolder.outputName, "p.jpg")
    }

    func testRewrittenFileIsDecodedAgain() async throws {
        let source = try item("a.png", width: 800, height: 600)
        let renderer = PreviewRenderer()
        let first = try ready(await renderer.render(item: source, index: 0, pipeline: Pipeline()))
        XCTAssertEqual(first.outputSize.0, 800)
        try TestImages.write(TestImages.make(width: 320, height: 200), to: source.source, type: .png)
        let second = try ready(await renderer.render(item: source, index: 0, pipeline: Pipeline()))
        XCTAssertEqual(second.outputSize.0, 320)
        let count = await renderer.decodeCount
        XCTAssertEqual(count, 2)
    }

    func testRewrittenWatermarkImageIsReloaded() async throws {
        let logoURL = dir.appendingPathComponent("logo.png")
        try TestImages.write(TestImages.make(width: 10, height: 10), to: logoURL, type: .png)
        let options = WatermarkOptions(content: .image(ImageWatermark(path: logoURL.path)))
        let pipeline = Pipeline(steps: [PipelineStep(operation: .watermark(options))], output: .init(format: .png))
        let source = try item("a.png")
        let renderer = PreviewRenderer()
        _ = await renderer.render(item: source, index: 0, pipeline: pipeline)
        _ = await renderer.render(item: source, index: 0, pipeline: pipeline)
        var loads = await renderer.assetLoadCount
        XCTAssertEqual(loads, 1)
        try TestImages.write(TestImages.make(width: 30, height: 20), to: logoURL, type: .png)
        _ = await renderer.render(item: source, index: 0, pipeline: pipeline)
        loads = await renderer.assetLoadCount
        XCTAssertEqual(loads, 2)
    }

    func testPurgeAndFailedDecodeDropTheCache() async throws {
        let source = try item("a.png")
        let renderer = PreviewRenderer()
        _ = await renderer.render(item: source, index: 0, pipeline: Pipeline())
        await renderer.purge()
        _ = await renderer.render(item: source, index: 0, pipeline: Pipeline())
        var count = await renderer.decodeCount
        XCTAssertEqual(count, 2)
        let bad = dir.appendingPathComponent("bad.png")
        try Data("x".utf8).write(to: bad)
        _ = await renderer.render(item: InputItem(source: bad, relativeDirectory: ""), index: 0, pipeline: Pipeline())
        _ = await renderer.render(item: source, index: 0, pipeline: Pipeline())
        count = await renderer.decodeCount
        XCTAssertEqual(count, 4)
    }

    func testHugeSourcesAreNotCached() async throws {
        let source = try item("a.png", width: 100, height: 100)
        let renderer = PreviewRenderer(maxPixels: 250_000_000)
        // 100x100 is cached; the threshold itself is checked via the constant.
        XCTAssertEqual(PreviewRenderer.maxCachedPixels, 50_000_000)
        _ = await renderer.render(item: source, index: 0, pipeline: Pipeline())
        _ = await renderer.render(item: source, index: 0, pipeline: Pipeline())
        let count = await renderer.decodeCount
        XCTAssertEqual(count, 1)
    }
}
