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

    func testEncodedAndAnimatedLinksRejected() throws {
        // Character references and CSS escapes are decoded before the scan.
        try assertUnsafe(##"<rect style="fill:u&#114;l(http://example.com/p.svg#p)" width="5" height="5"/>"##)
        try assertUnsafe(##"<style>@&#x69;mport "x.css";</style>"##)
        try assertUnsafe(##"<style>rect { fill: u\72 l(http://example.com/p.svg#p) }</style>"##)
        try assertUnsafe(##"<style>@\69mport "x.css";</style>"##)
        try assertUnsafe(##"<a><set attributeName="href" to="http://example.com"/></a>"##)
        try assertUnsafe(##"<use href="#a"><animate attributeName="xlink:href" values="http://x/a.svg#a"/></use>"##)
    }

    func testDataURIsRejected() throws {
        // An embedded raster would be decoded by AppKit outside the pixel guard.
        try assertUnsafe(##"<image href="data:image/png;base64,iVBORw0KGgo=" width="5" height="5"/>"##)
        try assertUnsafe(##"<image xlink:href="DATA:image/svg+xml,%3Csvg/%3E"/>"##)
    }

    func testSVGDetectedByContent() throws {
        let rect = ##"<rect width="40" height="20" fill="red"/>"##
        let prolog = "\u{FEFF}<?xml version=\"1.0\"?>\n<!-- logo -->\n" + svg(rect)
        _ = try rasterizeOrSkip(try write(prolog))
        for text in ["<html><body>" + svg(rect) + "</body></html>", "<svgx/>" + svg(rect), "hello " + svg(rect)] {
            let url = try write(text, name: "x.svg")
            XCTAssertThrowsError(try SVGRasterizer.rasterize(url: url), text) {
                XCTAssertEqual($0 as? ConversionError, .watermarkImageUnreadable, text)
            }
        }
    }

    private func assertRefused(_ text: String, _ expected: ConversionError = .watermarkSVGUnsafe,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let url = try write(text, name: "probe.svg")
        XCTAssertThrowsError(try SVGRasterizer.rasterize(url: url), text, file: file, line: line) {
            XCTAssertEqual($0 as? ConversionError, expected, text, file: file, line: line)
        }
    }

    func testUTF7AndOtherEncodingsRefused() throws {
        // CoreSVG honours a UTF-7 declaration: this would draw an embedded PNG, unseen by a text scan.
        let utf7 = ##"<?xml version="1.0" encoding="UTF-7"?>"##
            + svg(##"<image hr+AGU-f="+AGQ-ata:image/png;base64,iVBORw0KGgo=" width="5" height="5"/>"##)
        try assertRefused(utf7)
        try assertRefused(##"<?xml version="1.0" encoding="ISO-8859-1"?>"## + svg(""))
        // UTF-8 may be declared, with either quote and spacing.
        _ = try rasterizeOrSkip(try write(##"<?xml version='1.0' encoding = 'utf-8'?>"##
            + svg(##"<rect width="40" height="20" fill="red"/>"##)))
        // UTF-16, with or without a BOM, isn't read.
        for data in [Data([0xFF, 0xFE]) + svg("").data(using: .utf16LittleEndian)!,
                     svg("").data(using: .utf16LittleEndian)!] {
            let url = dir.appendingPathComponent("u16.svg")
            try data.write(to: url)
            XCTAssertThrowsError(try SVGRasterizer.rasterize(url: url)) {
                XCTAssertEqual($0 as? ConversionError, .watermarkImageUnreadable)
            }
        }
    }

    func testDoctypeEntityAndBaseRefused() throws {
        try assertRefused(##"<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "svg11.dtd">"## + svg(""))
        try assertRefused(svg(##"<!ENTITY x "y">"##))
        try assertRefused(svg(##"<g xml:base="http://example.com/"><use href="#a"/></g>"##))
        try assertRefused(svg(##"<?xml-stylesheet href="http://example.com/a.css"?>"##))
    }

    func testPaddedReferencesAreDecodedByTheParser() throws {
        try assertRefused(svg(##"<rect fill="url(&#x00000000000068;ttp://example.com/p.svg#p)"/>"##))
        try assertRefused(svg(##"<rect style="fill:u&#x00000000000072;l(http://example.com/p.svg#p)"/>"##))
        // A padded reference that decodes to something harmless still draws.
        let image = try rasterizeOrSkip(try write(svg(##"<rect width="40" height="20" fill="&#x00000000000023;ff0000"/>"##)))
        XCTAssertGreaterThan(TestImages.pixel(of: image, x: 10, y: 10).red, 250)
    }

    func testNamespaceTricksRefused() throws {
        let svgNS = "http://www.w3.org/2000/svg"
        try assertRefused(svg(##"<x:script xmlns:x="\##(svgNS)">alert(1)</x:script>"##))
        try assertRefused(svg(##"<x:style xmlns:x="\##(svgNS)">rect{fill:green}</x:style>"##))
        try assertRefused(svg(##"<h:iframe xmlns:h="http://www.w3.org/1999/xhtml"/>"##))
        try assertRefused(svg(##"<set xmlns:foo="http://www.w3.org/1999/xlink" attributeName="foo:href" to="http://x"/>"##))
        try assertRefused(svg(##"<use xmlns:foo="http://www.w3.org/1999/xlink" foo:href="http://x/a.svg#a"/>"##))
        try assertRefused(svg(##"<use xmlns:foo="urn:other" foo:href="#a"/>"##))
        try assertRefused(svg(##"<rect onclick="alert(1)" width="5" height="5"/>"##))
        try assertRefused(svg(##"<path href="#a" d="M0 0"/>"##))
        try assertRefused(svg(##"<rect style="fill:red;behavior:url(#a) x;@media" width="5"/>"##))
        try assertRefused(svg(##"<rect fill="url(#a) url(#b)" width="5"/>"##))
        // A prefix bound to the SVG namespace is just SVG, and a prefixed xlink:href to #id is fine.
        let prefixed = svg(##"<s:rect xmlns:s="\##(svgNS)" width="40" height="20" fill="red"/>"##
                           + ##"<defs><rect id="b" width="1" height="1"/></defs>"##
                           + ##"<use xmlns:foo="http://www.w3.org/1999/xlink" foo:href="#b"/>"##)
        let image = try rasterizeOrSkip(try write(prefixed))
        XCTAssertGreaterThan(TestImages.pixel(of: image, x: image.width / 2, y: image.height / 2).red, 250)
    }

    func testPathologicalInputIsFastAndBounded() throws {
        // About 1 MB of comments before the root: linear work, well under a second.
        let comments = String(repeating: "<!-- padding -->", count: (SVGRasterizer.maxFileSize - 400) / 16)
        let start = Date()
        _ = try? SVGRasterizer.rasterize(url: try write(comments + svg(##"<rect width="40" height="20" fill="red"/>"##)))
        let doctypes = String(repeating: "<!DOCTYPE a>", count: (SVGRasterizer.maxFileSize - 400) / 12)
        try assertRefused(doctypes + svg(""))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        try assertRefused(svg(String(repeating: "<g>", count: 100) + String(repeating: "</g>", count: 100)))
        try assertRefused(svg(String(repeating: "<rect/>", count: SVGSanitizer.maxElements + 1)))
    }

    func testNormalLogoRendersTheSameColours() throws {
        let body = [
            ##"<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#ff0000"/>"##,
            ##"<stop offset="1" stop-color="#ff0000"/></linearGradient>"##,
            ##"<rect id="blue" width="20" height="10" fill="#0000ff"/></defs>"##,
            ##"<rect x="0" y="0" width="20" height="10" fill="url(#g)"/>"##,
            ##"<use xlink:href="#blue" x="20" y="0"/>"##,
            ##"<path d="M0 10 H40 V20 H0 Z" style="fill:#00ff00;stroke:none"/>"##,
            ##"<text x="2" y="19" font-family="Helvetica" font-size="8" fill="#000000">A &amp; B</text>"##
        ].joined(separator: "\n")
        let image = try rasterizeOrSkip(try write(svg(body)))
        // The original, drawn by AppKit as it is, must look the same as the sanitised version.
        let original = try SVGRasterizer.render(Data(svg(body).utf8), maxPixels: ImageLoader.defaultMaxPixels)
        XCTAssertEqual(image.width, original.width)
        let scale = image.width / 40
        for (col, row) in [(5, 5), (30, 5), (38, 12), (3, 17), (10, 19), (25, 15)] {
            let mine = TestImages.pixel(of: image, x: col * scale, y: row * scale)
            let theirs = TestImages.pixel(of: original, x: col * scale, y: row * scale)
            XCTAssertEqual(mine.red, theirs.red, accuracy: 1, "\(col),\(row)")
            XCTAssertEqual(mine.green, theirs.green, accuracy: 1, "\(col),\(row)")
            XCTAssertEqual(mine.blue, theirs.blue, accuracy: 1, "\(col),\(row)")
            XCTAssertEqual(mine.alpha, theirs.alpha, accuracy: 1, "\(col),\(row)")
        }
        let blue = TestImages.pixel(of: image, x: 30 * scale, y: 5 * scale)
        let green = TestImages.pixel(of: image, x: 38 * scale, y: 12 * scale)
        XCTAssertTrue(blue.blue > 250 && blue.red < 5 && blue.green < 5, "\(blue)")
        XCTAssertTrue(green.green > 250 && green.red < 5 && green.blue < 5, "\(green)")
        XCTAssertGreaterThan(TestImages.pixel(of: image, x: 5 * scale, y: 5 * scale).red, 250)
        // Text survives the round trip, escaped.
        let canonical = try XCTUnwrap(String(bytes: SVGSanitizer.sanitize(Data(svg(body).utf8)), encoding: .utf8))
        XCTAssertTrue(canonical.contains("A &amp; B"), canonical)
        XCTAssertTrue(canonical.contains(##"xlink:href="#blue""##), canonical)
    }
}
