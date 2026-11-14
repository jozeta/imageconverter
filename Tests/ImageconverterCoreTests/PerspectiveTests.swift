import CoreGraphics
import XCTest
@testable import ImageconverterCore

final class PerspectiveTests: XCTestCase {
    private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)

    func testPerspectiveZeroIsIdentity() throws {
        let image = TestImages.make(width: 120, height: 90)
        XCTAssertTrue(try Perspective.apply(PerspectiveOptions(), to: image) === image)
        XCTAssertEqual(Pipeline.size(after: .perspective(PerspectiveOptions()), from: CGSize(width: 120, height: 90)),
                       CGSize(width: 120, height: 90))
    }

    func testPerspectiveVerticalKeepsNoTransparentCorners() throws {
        let image = TestImages.make(width: 400, height: 300, color: red)
        for options in [PerspectiveOptions(vertical: 60), PerspectiveOptions(vertical: -40, horizontal: 30)] {
            let out = try Perspective.apply(options, to: image)
            XCTAssertLessThan(out.width, 400)
            XCTAssertGreaterThan(out.width, 100)
            for (col, row) in [(0, 0), (out.width - 1, 0), (0, out.height - 1), (out.width - 1, out.height - 1)] {
                let pix = TestImages.pixel(of: out, x: col, y: row)
                XCTAssertEqual(pix.alpha, 255, "\(options) (\(col),\(row))")
                XCTAssertGreaterThan(pix.red, 240, "\(options) (\(col),\(row))")
            }
            let planned = Pipeline.size(after: .perspective(options), from: CGSize(width: 400, height: 300))
            XCTAssertEqual(planned, CGSize(width: out.width, height: out.height))
        }
    }

    func testAutoPerspectiveFindsRectangle() throws {
        // A 240 x 120 white rectangle, tilted 6°, on black.
        guard let ctx = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return XCTFail("context")
        }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        ctx.translateBy(x: 300, y: 200)
        ctx.rotate(by: 6 * .pi / 180)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: -120, y: -60, width: 240, height: 120))
        guard let image = ctx.makeImage() else { return XCTFail("image") }

        guard let quad = try? Perspective.detectRectangle(in: image) else {
            throw XCTSkip("Vision rectangle detection is unavailable here")
        }
        XCTAssertNotNil(quad)
        let out = try Perspective.apply(PerspectiveOptions(auto: true), to: image)
        XCTAssertEqual(Double(out.width) / Double(out.height), 2, accuracy: 0.15)
        XCTAssertEqual(Double(out.width), 240, accuracy: 20)
    }

    func testAutoWithoutRectangleIsUnchanged() throws {
        let image = TestImages.make(width: 200, height: 150)
        XCTAssertTrue(try Perspective.apply(PerspectiveOptions(auto: true), to: image) === image)
    }

    func testOptionsDecodeLeniently() throws {
        let options = try JSONDecoder().decode(PerspectiveOptions.self, from: Data(#"{"vertical":500}"#.utf8))
        XCTAssertEqual(options, PerspectiveOptions(vertical: 100))
        XCTAssertEqual(ImageOperation.perspective(PerspectiveOptions()).summary, "no change")
        XCTAssertEqual(ImageOperation.perspective(PerspectiveOptions(vertical: 20, horizontal: -10, auto: true)).summary,
                       "auto · vertical +20 · horizontal −10")
    }
}

final class PerspectivePlanningTests: XCTestCase {
    func testAutoNotesWhenNothingFound() throws {
        let pipeline = Pipeline(steps: [PipelineStep(operation: .perspective(PerspectiveOptions(auto: true)))])
        var notes: [String] = []
        let image = TestImages.make(width: 200, height: 150)
        XCTAssertTrue(try pipeline.apply(to: image, notes: &notes) === image)
        XCTAssertEqual(notes, [Perspective.noEdgesNote])
        var none: [String] = []
        _ = try Pipeline(steps: [PipelineStep(operation: .perspective(PerspectiveOptions(vertical: 20)))])
            .apply(to: image, notes: &none)
        XCTAssertTrue(none.isEmpty)
    }

    func testNearZeroSlidersAreNoOp() throws {
        let image = TestImages.make(width: 120, height: 90)
        let tiny = PerspectiveOptions(vertical: 0.004, horizontal: -0.009)
        XCTAssertTrue(Perspective.isNoOp(tiny))
        XCTAssertTrue(try Perspective.apply(tiny, to: image) === image)
        XCTAssertEqual(Pipeline.workingCopies(.perspective(tiny)), 1)
        XCTAssertEqual(Pipeline.workingCopies(.perspective(PerspectiveOptions(auto: true))), 3)
    }

    func testAutoPlanningKeepsInputSizeAndBoundsPeak() {
        let options = PerspectiveOptions(vertical: 50, auto: true)
        XCTAssertEqual(Pipeline.size(after: .perspective(options), from: CGSize(width: 400, height: 300)),
                       CGSize(width: 400, height: 300))
        let pipeline = Pipeline(steps: [PipelineStep(operation: .perspective(options))])
        // 3 input copies + a corrected image up to the diagonal squared (500² for 400 x 300).
        XCTAssertEqual(pipeline.peakPixels(sourceWidth: 400, sourceHeight: 300), 3 * 120_000 + 250_000)
    }
}
