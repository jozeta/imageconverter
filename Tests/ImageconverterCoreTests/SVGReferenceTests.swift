import CoreGraphics
import XCTest
@testable import ImageconverterCore

/// Reference graph, style and prolog rules of `SVGSanitizer` (on the bytes, so no rendering is needed to refuse).
final class SVGReferenceTests: XCTestCase {
    private func svg(_ body: String) -> String {
        #"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="40" "#
            + #"height="20" viewBox="0 0 40 20">"# + body + "</svg>"
    }

    private func assertRefused(_ text: String, _ expected: ConversionError = .watermarkSVGUnsafe,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SVGSanitizer.sanitize(Data(text.utf8)), file: file, line: line) {
            XCTAssertEqual($0 as? ConversionError, expected, file: file, line: line)
        }
    }

    private func assertAccepted(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNoThrow(try SVGSanitizer.sanitize(Data(text.utf8)), file: file, line: line)
    }

    func testMutualUseRecursionRefused() {
        // CoreSVG crashes on these (indirect cycles outside <defs>).
        assertRefused(svg(##"<g id="a"><use xlink:href="#b"/></g><use id="b" xlink:href="#a"/>"##))
        assertRefused(svg(##"<g id="a"><use xlink:href="#b"/></g><g id="b"><use xlink:href="#a"/></g>"##))
        assertRefused(svg(##"<g id="a"><use href="#a"/></g>"##))
        assertRefused(svg(##"<use id="u" href="#u"/>"##))
        // Cycles through gradients, masks and patterns are refused too.
        assertRefused(svg(##"<linearGradient id="g1" href="#g2"/><linearGradient id="g2" href="#g1"/>"##))
        assertRefused(svg(##"<mask id="m1"><rect mask="url(#m2)"/></mask><mask id="m2"><rect mask="url(#m1)"/></mask>"##))
        assertRefused(svg(##"<pattern id="p"><rect style="fill:url(#p)"/></pattern>"##))
    }

    func testFanOutRefusedFast() {
        // Seven levels of ten uses each: about 10 million instances (CoreSVG took 43 s on this 2 KB file).
        var body = ##"<g id="l0"><rect width="1" height="1"/></g>"##
        for level in 1...7 {
            body += "<g id=\"l\(level)\">"
                + String(repeating: "<use xlink:href=\"#l\(level - 1)\"/>", count: 10) + "</g>"
        }
        let start = Date()
        assertRefused(svg("<defs>" + body + "</defs><use xlink:href=\"#l7\"/>"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        // Three levels (a little over a thousand instances) is fine.
        var small = ##"<g id="l0"><rect width="1" height="1"/></g>"##
        for level in 1...3 {
            small += "<g id=\"l\(level)\">"
                + String(repeating: "<use xlink:href=\"#l\(level - 1)\"/>", count: 10) + "</g>"
        }
        assertAccepted(svg("<defs>" + small + "</defs><use xlink:href=\"#l3\"/>"))
    }

    func testSharedGradientIsNotAnInstance() {
        // Many shapes filling with one gradient: references to paint servers don't multiply the count.
        let gradient = ##"<defs><linearGradient id="g"><stop offset="0" stop-color="red"/></linearGradient></defs>"##
        assertAccepted(svg(gradient + String(repeating: ##"<rect width="1" height="1" fill="url(#g)"/>"##, count: 5000)))
        assertRefused(svg(##"<rect id="d"/><rect id="d"/>"##))
        // A reference to a missing id is harmless.
        assertAccepted(svg(##"<use xlink:href="#missing"/><rect fill="url(#nope)"/>"##))
    }

    func testAttributeCap() {
        let many = (0..<65).map { " font-a\($0)=\"1\"" }.joined()
        assertRefused(svg("<rect" + many + "/>"))
        // The reviewer's 60 000-attribute rect (about 950 KB) is refused at once instead of taking seconds.
        let huge = (0..<60_000).map { " font-a\($0)=\"1\"" }.joined()
        let start = Date()
        assertRefused(svg("<rect" + huge + "/>"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testStyleDeclarations() {
        assertAccepted(svg(##"<rect style="fill:#f00; stroke-width: 2;STROKE:blue;" width="5" height="5"/>"##))
        assertAccepted(svg(##"<defs><linearGradient id="g"/></defs><rect style="fill: url(#g)"/>"##))
        assertRefused(svg(##"<rect style="fill: image-set('file:///etc/x' 1x)"/>"##))
        assertRefused(svg(##"<rect style="fill:src(http://x)"/>"##))
        // Colour functions with plain numbers are fine; anything else inside them isn't.
        assertAccepted(svg(##"<rect style="fill: rgb(1, 2, 3); stroke: RGBA(10%, 20%, 30%, .5); color: hsl(1,2%,3%)"/>"##))
        assertRefused(svg(##"<rect style="fill: rgb(1, url(#a), 3)"/>"##))
        assertRefused(svg(##"<rect style="fill: rgb(var(--x))"/>"##))
        assertRefused(svg(##"<rect style="fill: rgb(-1, 2, 3)"/>"##))
        assertRefused(svg(##"<rect style="fill: rgb(1, 2, 3"/>"##))
        assertRefused(svg(##"<rect style="fill: xrgb(1, 2, 3)"/>"##))
        assertRefused(svg(##"<rect style="behavior: x"/>"##))
        assertRefused(svg(##"<rect style="fill"/>"##))
        assertRefused(svg(##"<rect style="fill: (#g)"/>"##))
    }

    func testXMLDeclarationParsedProperly() {
        assertRefused(##"<?xml version="encodingutf-8" encoding="UTF-7"?>"## + svg(""))
        assertRefused(##"<?xml version='1.0' encoding='latin1'?>"## + svg(""))
        assertRefused(##"<?xml version=1.0?>"## + svg(""), .watermarkSVGInvalid)
        assertAccepted(##"<?xml version="1.0" standalone="yes"?>"## + svg(""))
        assertAccepted(##"<?xml version="1.0" encoding="UTF-8" standalone="no"?>"## + svg(""))
    }
}
