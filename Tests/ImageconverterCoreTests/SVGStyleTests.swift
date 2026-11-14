import CoreGraphics
import XCTest
@testable import ImageconverterCore

/// The standard SVG doctype and simple `<style>` sheets (as Illustrator exports them), inlined as attributes
/// that then pass the same allowlist and reference checks.
final class SVGStyleTests: XCTestCase {
    private func svg(_ body: String) -> String {
        #"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="40" "#
            + #"height="20" viewBox="0 0 40 20">"# + body + "</svg>"
    }

    private func canonical(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let data = try SVGSanitizer.sanitize(Data(text.utf8))
        return try XCTUnwrap(String(bytes: data, encoding: .utf8), file: file, line: line)
    }

    private func assertRefused(_ text: String, _ expected: ConversionError = .watermarkSVGUnsafe,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SVGSanitizer.sanitize(Data(text.utf8)), text, file: file, line: line) {
            XCTAssertEqual($0 as? ConversionError, expected, text, file: file, line: line)
        }
    }

    private static let illustrator = """
    <?xml version="1.0" encoding="utf-8"?>
    <!-- Generator: Adobe Illustrator 28.0.0, SVG Export Plug-In . SVG Version: 6.00 Build 0)  -->
    <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN"
      "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
    <svg version="1.1" id="Layer_1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
      x="0px" y="0px" width="40px" height="20px" viewBox="0 0 40 20" style="enable-background:new 0 0 40 20;"
      xml:space="preserve">
    <style type="text/css">
    \t.st0{fill:#E30613;}
    \t.st1{fill:none;stroke:#000000;stroke-miterlimit:10;}
    </style>
    <rect class="st0" width="40" height="20"/>
    <line class="st1" x1="0" y1="0" x2="0" y2="0"/>
    </svg>
    """

    func testIllustratorExportRendersRed() throws {
        let out = try canonical(Self.illustrator)
        XCTAssertFalse(out.contains("<style"), out)
        XCTAssertFalse(out.contains("class="), out)
        XCTAssertFalse(out.contains("DOCTYPE"), out)
        XCTAssertTrue(out.contains(##"fill="#E30613""##), out)
        let image: CGImage
        do {
            image = try SVGRasterizer.render(Data(out.utf8), maxPixels: ImageLoader.defaultMaxPixels)
        } catch ConversionError.watermarkSVGUnsupported {
            throw XCTSkip("NSImage can't render SVG on this macOS")
        }
        let pixel = TestImages.pixel(of: image, x: image.width / 2, y: image.height / 2)
        XCTAssertGreaterThan(pixel.red, 200, "\(pixel)")
        XCTAssertLessThan(pixel.green, 40, "\(pixel)")
        XCTAssertLessThan(pixel.blue, 50, "\(pixel)")
    }

    func testRefusalMessagesByReason() {
        XCTAssertEqual(ConversionError.watermarkSVGUnsafe.reason, "This SVG uses features that aren't supported "
                       + "(scripts, animation or advanced styling). Export it as plain SVG or PNG.")
        XCTAssertEqual(ConversionError.watermarkSVGExternal.reason, "This SVG uses embedded images or links to other "
                       + "files, which aren't allowed. Export the logo as plain SVG or PNG.")
        XCTAssertEqual(ConversionError.watermarkSVGInvalid.reason, "This file isn't a valid SVG.")
        XCTAssertEqual(ConversionError.watermarkSVGTooLarge.reason, "This SVG is too large (over 1 MB).")
    }

    func testStyleWithLinksRefusedAsExternal() {
        assertRefused(svg(##"<style>@import "http://example.com/a.css";</style><rect/>"##), .watermarkSVGExternal)
        assertRefused(svg(##"<style>@IMPORT url(a.css);</style>"##), .watermarkSVGExternal)
        assertRefused(svg(##"<style>.a{fill:url(http://example.com/p.svg#p)}</style><rect class="a"/>"##),
                      .watermarkSVGExternal)
        // A rule that matches nothing is checked all the same.
        assertRefused(svg(##"<style>.unused{fill:url(file:///etc/x#p)}</style>"##), .watermarkSVGExternal)
    }

    func testOnlySimpleCSSAccepted() {
        for css in ["@media print{rect{fill:red}}", "@font-face{font-family:x}", "g rect{fill:red}", "g>rect{fill:red}",
                    "g+rect{fill:red}", "g~rect{fill:red}", "rect.a{fill:red}", "rect:hover{fill:red}",
                    "rect::before{fill:red}", "[id]{fill:red}", "*{fill:red}", "rect{fill:red !important}",
                    "rect{fill:\\72 ed}", ".a{fill:red", ".a{fill:red}}", ".a{b{fill:red}}", "rect{}x",
                    ".a{transform:rotate(45deg)}", ".a{d:path('M0 0')}", ".a{behavior:x}", ".a{fill}",
                    ".a{fill:expression(1)}", ".a{fill:image-set(x 1x)}", "/* open", ".1a{fill:red}", ",{fill:red}",
                    ".a{font-x y:1}"] {
            assertRefused(svg("<style>" + css + "</style><rect class=\"a\"/>"))
        }
        // Style attributes other than type="text/css", and markup inside a style, are refused.
        assertRefused(svg(##"<style media="print">rect{fill:red}</style>"##))
        assertRefused(svg(##"<style type="text/x-less">rect{fill:red}</style>"##))
        assertRefused(svg(##"<style><rect/></style>"##))
        assertRefused(svg(##"<rect class="a 1b"/>"##))
        assertRefused(svg("<rect class=\"" + (0...SVGSanitizer.maxClasses).map { "c\($0)" }.joined(separator: " ") + "\"/>"))
    }

    func testSelectorsAndPrecedence() throws {
        let css = """
        <style><![CDATA[
          /* comment */ rect, .b { fill: #ff0000; stroke: blue }
          #x { fill: rgb(0, 255, 0) }
          .c { fill: #0000ff; opacity: .5 }
        ]]></style>
        """
        let out = try canonical(svg(css + ##"<rect id="x" class="c" width="1" height="1"/><circle class="b" r="1"/>"##
                                    + ##"<rect fill="black" stroke="none" width="2" height="2"/>"##))
        // Later rules win (.c after #x after rect), whatever the selector kind.
        XCTAssertTrue(out.contains(##"<rect height="1" id="x" width="1" fill="#0000ff" opacity=".5" stroke="blue"/>"##), out)
        XCTAssertTrue(out.contains(##"<circle r="1" fill="#ff0000" stroke="blue"/>"##), out)
        // Existing attributes win over the sheet.
        XCTAssertTrue(out.contains(##"<rect fill="black" height="2" stroke="none" width="2"/>"##), out)
    }

    func testInlinedAttributesPassReferenceChecks() {
        // The pattern fills its own content once the rule is inlined: a cycle.
        assertRefused(svg(##"<style>.c{fill:url(#p)}</style><pattern id="p"><rect class="c"/></pattern>"##))
        // A rule matching many elements can't blow up the output.
        let big = String(repeating: "a", count: 200_000)
        assertRefused(svg("<style>rect{font-family:" + big + "}</style>" + String(repeating: "<rect/>", count: 20)))
        XCTAssertNoThrow(try SVGSanitizer.sanitize(Data(svg(##"<style>.c{fill:url(#g)}</style>"##
            + ##"<linearGradient id="g"/><rect class="c"/>"##).utf8)))
    }

    func testOnlyTheStandardDoctypeIsDropped() throws {
        let svg11 = ##"<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">"##
        let svg10 = ##"<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.0//EN" "##
            + ##""http://www.w3.org/TR/2001/REC-SVG-20010904/DTD/svg10.dtd">"##
        XCTAssertFalse(try canonical(svg11 + svg("")).contains("DOCTYPE"))
        XCTAssertNoThrow(try canonical("<?xml version=\"1.0\"?>\n<!-- x -->\n" + svg10 + "\n" + svg("")))
        // An internal subset, another public id, a lowercase keyword, a second doctype, or one after the root.
        assertRefused(##"<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd" []>"##
                      + svg(""))
        assertRefused(##"<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://example.com/svg11.dtd">"## + svg(""))
        assertRefused(##"<!doctype svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">"##
                      + svg(""))
        assertRefused(svg11 + svg11 + svg(""))
        assertRefused(svg11 + "<!DOCTYPE a>" + svg(""))
        assertRefused("<x/>" + svg11 + svg(""))
        assertRefused(svg("") + svg11)
        assertRefused(svg11 + svg(##"<!ENTITY x "y">"##))
    }
}
