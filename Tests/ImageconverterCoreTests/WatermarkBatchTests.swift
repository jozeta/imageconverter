import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

final class WatermarkBatchTests: XCTestCase {
    private var dir: URL!
    private var out: URL!

    override func setUpWithError() throws {
        dir = try TestImages.tempDir()
        out = dir.appendingPathComponent("out")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)
    private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)

    private func logo() throws -> String {
        let url = dir.appendingPathComponent("logo.png")
        try TestImages.write(TestImages.make(width: 100, height: 50, color: red), to: url, type: .png)
        return url.path
    }

    private func pipeline(path: String, enabled: Bool = true) -> Pipeline {
        let options = WatermarkOptions(content: .image(ImageWatermark(path: path)), anchor: .bottomRight,
                                       sizePercent: 20, opacity: 1, marginPercent: 0)
        return Pipeline(steps: [PipelineStep(isEnabled: enabled, operation: .watermark(options))],
                        output: .init(format: .png))
    }

    private func input(_ name: String, width: Int, height: Int, type: UTType = .png,
                       properties: [String: Any] = [:]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try TestImages.write(TestImages.make(width: width, height: height, color: blue), to: url, type: type,
                             properties: properties)
        return url
    }

    private func decode(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// Bounding box of the red pixels (top-left origin, inclusive pixel bounds), or nil.
    private func redBox(_ image: CGImage) -> CGRect? {
        var box: CGRect?
        for row in 0..<image.height {
            for column in 0..<image.width {
                let pixel = TestImages.pixel(of: image, x: column, y: row)
                guard pixel.red > 200, pixel.blue < 60 else { continue }
                let point = CGRect(x: column, y: row, width: 1, height: 1)
                box = box.map { $0.union(point) } ?? point
            }
        }
        return box
    }

    func testBatchStampsEveryImage() async throws {
        let path = try logo()
        let files = [
            try input("a.png", width: 800, height: 600),
            try input("b.png", width: 600, height: 800),
            // 800x600 stored with orientation 6: upright it is 600x800.
            try input("c.jpg", width: 800, height: 600, type: .jpeg,
                      properties: [kCGImagePropertyOrientation as String: 6])
        ]
        let report = await BatchRunner.run(InputCollector.collect(files), pipeline: pipeline(path: path),
                                           mode: .newFolder(out))
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.written.count, 3)

        for url in report.written {
            let image = try decode(url)
            let box = try XCTUnwrap(redBox(image), url.lastPathComponent)
            let expected = Double(min(image.width, image.height)) * 0.2
            XCTAssertEqual(Double(box.width), expected, accuracy: 2, url.lastPathComponent)
            XCTAssertGreaterThan(Int(box.minX), image.width / 2, url.lastPathComponent)
            XCTAssertGreaterThan(Int(box.minY), image.height / 2, url.lastPathComponent)
        }
        let upright = try decode(try XCTUnwrap(report.written.last))
        XCTAssertEqual(upright.height, 800)
    }

    private func assertAllFail(_ pipeline: Pipeline, maxPixels: Int = 250_000_000,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        let files = [try input("x.png", width: 40, height: 30), try input("y.png", width: 40, height: 30)]
        let report = await BatchRunner.run(InputCollector.collect(files), pipeline: pipeline,
                                           mode: .newFolder(out), maxPixels: maxPixels)
        XCTAssertEqual(report.failures.count, 2, file: file, line: line)
        XCTAssertEqual(Set(report.failures.map(\.reason)), ["Couldn't read the watermark image"],
                       file: file, line: line)
        XCTAssertTrue(report.written.isEmpty, file: file, line: line)
    }

    func testMissingWatermarkImageFailsEachFile() async throws {
        try await assertAllFail(pipeline(path: dir.appendingPathComponent("nope.png").path))
    }

    func testCorruptWatermarkImage() async throws {
        let junk = dir.appendingPathComponent("junk.png")
        try Data("not an image".utf8).write(to: junk)
        try await assertAllFail(pipeline(path: junk.path))
    }

    func testOversizedWatermarkImage() async throws {
        // The 100x50 logo (5,000 px) exceeds the limit; the 40x30 inputs (1,200 px) do not.
        try await assertAllFail(pipeline(path: try logo()), maxPixels: 2_000)
    }

    func testDirectoryAsWatermarkPathFails() async throws {
        try await assertAllFail(pipeline(path: dir.path))
    }

    func testDisabledWatermarkStepIgnoresMissingImage() async throws {
        let files = [try input("x.png", width: 40, height: 30)]
        let report = await BatchRunner.run(
            InputCollector.collect(files), pipeline: pipeline(path: "/nonexistent/logo.png", enabled: false),
            mode: .newFolder(out))
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.written.count, 1)
    }

    func testAssetsLoadedOnce() throws {
        let path = try logo()
        var twice = pipeline(path: path)
        twice.steps.append(twice.steps[0])
        twice.steps.append(PipelineStep(isEnabled: false, operation: .watermark(
            WatermarkOptions(content: .image(ImageWatermark(path: "/nonexistent/other.png"))))))
        let assets = WatermarkAssets.load(for: twice, maxPixels: 1_000_000)
        XCTAssertEqual(assets.count, 1)
        XCTAssertNotNil(assets.image(for: path))
        XCTAssertNil(assets.image(for: "/nonexistent/other.png"))
    }

    func testMissingLogoFailsFastWithoutDecodingSources() async throws {
        // Sources that could never decode: the failure reason must still be the watermark's,
        // which proves the source files were not opened first.
        var files: [URL] = []
        for name in ["j1.png", "j2.png"] {
            let url = dir.appendingPathComponent(name)
            try Data("not an image".utf8).write(to: url)
            files.append(url)
        }
        let report = await BatchRunner.run(
            InputCollector.collect(files), pipeline: pipeline(path: dir.appendingPathComponent("nope.png").path),
            mode: .newFolder(out))
        XCTAssertEqual(report.failures.count, 2)
        XCTAssertEqual(Set(report.failures.map(\.reason)), ["Couldn't read the watermark image"])
        XCTAssertTrue(report.written.isEmpty)
    }

    func testHasMissing() throws {
        let path = try logo()
        XCTAssertFalse(WatermarkAssets.load(for: pipeline(path: path), maxPixels: 1_000_000)
            .hasMissing(for: pipeline(path: path)))
        let missing = pipeline(path: "/nonexistent/x.png")
        XCTAssertTrue(WatermarkAssets.load(for: missing, maxPixels: 1_000_000).hasMissing(for: missing))
        let disabled = pipeline(path: "/nonexistent/x.png", enabled: false)
        XCTAssertFalse(WatermarkAssets.load(for: disabled, maxPixels: 1_000_000).hasMissing(for: disabled))
        XCTAssertFalse(WatermarkAssets.empty.hasMissing(for: Pipeline(steps: [], output: .init(format: .png))))
    }

    func testWideLogoIsDownsampledOnLoad() throws {
        let url = dir.appendingPathComponent("wide.png")
        try TestImages.write(TestImages.make(width: 8000, height: 100, color: red), to: url, type: .png)
        let assets = WatermarkAssets.load(for: pipeline(path: url.path), maxPixels: 10_000_000)
        let image = try XCTUnwrap(assets.image(for: url.path))
        XCTAssertLessThanOrEqual(image.width, 4096)
        XCTAssertGreaterThan(image.width, 4000)
    }

    func testCancelledBeforeAssetLoadReturnsCancelledReport() async throws {
        let path = try logo()
        let files = [try input("x.png", width: 40, height: 30)]
        let pipeline = pipeline(path: path)
        let task = Task {
            // Wait until cancelled, so the batch starts with the task already cancelled.
            while !Task.isCancelled { await Task.yield() }
            return await BatchRunner.run(InputCollector.collect(files), pipeline: pipeline, mode: .newFolder(out))
        }
        task.cancel()
        let report = await task.value
        XCTAssertTrue(report.cancelled)
        XCTAssertTrue(report.written.isEmpty)
    }
}
