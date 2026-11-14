import CoreGraphics
import XCTest
@testable import ImageconverterCore

final class SVGRasterizerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try TestImages.tempDir()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String, name: String = "mark.svg") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func svg(_ body: String, width: Int = 40, height: Int = 20) -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" \
        width="\(width)" height="\(height)" viewBox="0 0 \(width) \(height)">\(body)</svg>
        """
    }

    private func rasterizeOrSkip(_ url: URL) throws -> CGImage {
        do {
            return try SVGRasterizer.rasterize(url: url)
        } catch ConversionError.watermarkSVGUnsupported {
            throw XCTSkip("NSImage can't render SVG on this macOS")
        }
    }

    private func assertUnsafe(_ body: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = try write(svg(body))
        XCTAssertThrowsError(try SVGRasterizer.rasterize(url: url), body, file: file, line: line) {
            XCTAssertEqual($0 as? ConversionError, .watermarkSVGUnsafe, body, file: file, line: line)
        }
    }

    func testSVGRasterizes() throws {
        let url = try write(svg(##"<rect x="0" y="0" width="40" height="20" fill="#ff0000"/>"##))
        let image = try rasterizeOrSkip(url)
        XCTAssertEqual(image.width, SVGRasterizer.maxLongSide)
        XCTAssertEqual(image.height, SVGRasterizer.maxLongSide / 2)
        let pixel = TestImages.pixel(of: image, x: image.width / 2, y: image.height / 2)
        XCTAssertGreaterThan(pixel.red, 250)
        XCTAssertLessThan(pixel.green, 5)
        XCTAssertGreaterThan(pixel.alpha, 250)
    }

    func testSVGKeepsTransparencyAndOrientation() throws {
        // Red top half only: the bottom stays transparent, so the image isn't flipped.
        let url = try write(svg(#"<rect x="0" y="0" width="40" height="10" fill="red"/>"#))
        let image = try rasterizeOrSkip(url)
        XCTAssertGreaterThan(TestImages.pixel(of: image, x: 10, y: 10).red, 250)
        XCTAssertLessThan(TestImages.pixel(of: image, x: 10, y: image.height - 10).alpha, 5)
    }

    func testSVGWithExternalHrefRejected() throws {
        try assertUnsafe(#"<image xlink:href="http://example.com/a.png" width="10" height="10"/>"#)
        try assertUnsafe(#"<image href = 'HTTPS://example.com/a.png'/>"#)
        try assertUnsafe(#"<use href="other.svg#x"/>"#)
        try assertUnsafe(#"<use href="//example.com/x.svg#x"/>"#)
        try assertUnsafe(#"<image href="file:///etc/passwd"/>"#)
        try assertUnsafe(#"<image href="&#104;ttp://example.com/a.png"/>"#)
        try assertUnsafe(#"<rect fill="url(http://example.com/p.svg#g)" width="5" height="5"/>"#)
        try assertUnsafe(#"<style>@import "http://example.com/a.css";</style>"#)
        try assertUnsafe(#"<script>alert(1)</script>"#)
        try assertUnsafe(#"<SCRIPT >alert(1)</SCRIPT>"#)
        try assertUnsafe(#"<foreignObject width="10" height="10"><p>x</p></foreignObject>"#)
        try assertUnsafe(#"<a href="javascript:alert(1)"><rect width="5" height="5"/></a>"#)
        // Entities could spell a link that the scan wouldn't see (or expand without end).
        let entity = #"<!DOCTYPE svg [<!ENTITY h "http">]>"# + svg(#"<image href="&h;://example.com/a.png"/>"#)
        let url = try write(entity)
        XCTAssertThrowsError(try SVGRasterizer.rasterize(url: url)) {
            XCTAssertEqual($0 as? ConversionError, .watermarkSVGUnsafe)
        }
        XCTAssertEqual(ConversionError.watermarkSVGUnsafe.reason,
                       "This SVG can't be used (it loads external content or runs scripts)")
    }

    func testLocalReferencesAllowed() throws {
        let body = #"<defs><linearGradient id="g"><stop offset="0" stop-color="red"/></linearGradient></defs>"#
            + ##"<rect width="40" height="20" fill="url(#g)"/><use href="#g"/>"##
        _ = try rasterizeOrSkip(try write(svg(body)))
    }

    func testSVGOver1MBRejected() throws {
        let padding = "<!--" + String(repeating: "x", count: SVGRasterizer.maxFileSize) + "-->"
        let url = try write(svg(#"<rect width="40" height="20" fill="red"/>"# + padding))
        XCTAssertThrowsError(try SVGRasterizer.rasterize(url: url)) {
            XCTAssertEqual($0 as? ConversionError, .watermarkSVGTooLarge)
        }
    }

    func testNotSVGOrNotUTF8Unreadable() throws {
        for data in [Data("hello".utf8), Data([0xFF, 0xFE, 0x3C, 0x00, 0x73, 0x00])] {
            let url = dir.appendingPathComponent("bad.svg")
            try data.write(to: url)
            XCTAssertThrowsError(try SVGRasterizer.rasterize(url: url)) {
                XCTAssertEqual($0 as? ConversionError, .watermarkImageUnreadable)
            }
        }
    }

    func testSymlinkRefused() throws {
        let target = try write(svg(#"<rect width="40" height="20" fill="red"/>"#))
        let link = dir.appendingPathComponent("link.svg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try SVGRasterizer.rasterize(url: link))
    }

    func testBatchReportsUnsafeSVGReason() async throws {
        let mark = try write(svg(#"<script>1</script>"#))
        let input = dir.appendingPathComponent("in.png")
        try TestImages.write(TestImages.make(width: 40, height: 30), to: input, type: .png)
        let options = WatermarkOptions(content: .image(ImageWatermark(path: mark.path)))
        let pipeline = Pipeline(steps: [PipelineStep(operation: .watermark(options))], output: .init(format: .png))
        let report = await BatchRunner.run(InputCollector.collect([input]), pipeline: pipeline,
                                           mode: .newFolder(dir.appendingPathComponent("out")))
        XCTAssertEqual(report.failures.map(\.reason), [ConversionError.watermarkSVGUnsafe.reason])
        let item = try XCTUnwrap(InputCollector.collect([input]).first)
        guard case .failed(let reason) = await PreviewRenderer().render(item: item, index: 0, pipeline: pipeline) else {
            return XCTFail("preview should fail")
        }
        XCTAssertEqual(reason, ConversionError.watermarkSVGUnsafe.reason)
    }

    func testBatchStampsSVGWatermark() async throws {
        let mark = try write(svg(##"<rect width="40" height="20" fill="#ff0000"/>"##))
        _ = try rasterizeOrSkip(mark)
        let input = dir.appendingPathComponent("in.png")
        try TestImages.write(TestImages.make(width: 400, height: 300, color: CGColor(gray: 1, alpha: 1)),
                             to: input, type: .png)
        let options = WatermarkOptions(content: .image(ImageWatermark(path: mark.path)), anchor: .bottomRight,
                                       sizePercent: 20, opacity: 1, marginPercent: 3)
        let pipeline = Pipeline(steps: [PipelineStep(operation: .watermark(options))], output: .init(format: .png))
        let report = await BatchRunner.run(InputCollector.collect([input]), pipeline: pipeline,
                                           mode: .newFolder(dir.appendingPathComponent("out")))
        XCTAssertEqual(report.failures, [])
        let written = try XCTUnwrap(report.written.first)
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(written as CFURL, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let pixel = TestImages.pixel(of: image, x: 360, y: 276)
        XCTAssertGreaterThan(pixel.red, 250)
        XCTAssertLessThan(pixel.green, 5)
    }
}
