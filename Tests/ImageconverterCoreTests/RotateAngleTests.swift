import CoreGraphics
import XCTest
@testable import ImageconverterCore

/// Arbitrary rotation, straighten (crop to fit) and the canvas aspect mode.
final class RotateAngleTests: XCTestCase {
    private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)

    func testAngle0IsIdentity() throws {
        let image = TestImages.make(width: 120, height: 80)
        let options = RotateFlipOptions(rotation: .none, angle: 0)
        XCTAssertTrue(try ImageOps.rotateFlip(image, options) === image)
        XCTAssertEqual(Pipeline.size(after: .rotateFlip(options), from: CGSize(width: 120, height: 80)),
                       CGSize(width: 120, height: 80))
    }

    func testAngle45ExpandSize() throws {
        let image = TestImages.make(width: 100, height: 100, color: red)
        let options = RotateFlipOptions(rotation: .none, angle: 45)
        let out = try ImageOps.rotateFlip(image, options)
        XCTAssertEqual(out.width, 142)
        XCTAssertEqual(out.height, 142)
        // Expanded corners are the white background, the centre is the image.
        let corner = TestImages.pixel(of: out, x: 1, y: 1)
        XCTAssertGreaterThan(corner.blue, 240)
        let centre = TestImages.pixel(of: out, x: 71, y: 71)
        XCTAssertGreaterThan(centre.red, 240)
        XCTAssertLessThan(centre.blue, 20)
        XCTAssertEqual(Pipeline.size(after: .rotateFlip(options), from: CGSize(width: 100, height: 100)),
                       CGSize(width: 142, height: 142))
    }

    func testCropToFitHasNoEmptyCorners() throws {
        let opaque = try ImageOps.convertColor(TestImages.make(width: 300, height: 200, color: red), to: .sRGB)
        let options = RotateFlipOptions(rotation: .none, angle: 10, angleFill: .cropToFit)
        let out = try ImageOps.rotateFlip(opaque, options)
        XCTAssertLessThan(out.width, 300)
        XCTAssertEqual(Double(out.height), Double(out.width) * 200 / 300, accuracy: 1)
        for (col, row) in [(0, 0), (out.width - 1, 0), (0, out.height - 1), (out.width - 1, out.height - 1)] {
            let pix = TestImages.pixel(of: out, x: col, y: row)
            XCTAssertGreaterThan(pix.red, 240, "(\(col),\(row))")
            XCTAssertLessThan(pix.blue, 15, "(\(col),\(row))")
            XCTAssertEqual(pix.alpha, 255, "(\(col),\(row))")
        }
        let planned = Pipeline.size(after: .rotateFlip(options), from: CGSize(width: 300, height: 200))
        XCTAssertEqual(planned, CGSize(width: out.width, height: out.height))
    }

    func testAngleKeepsDepthAndColorSpace() throws {
        let image = TestImages.displayP3(width: 60, height: 40)
        for fill in [AngleFill.expand(background: .white), .cropToFit] {
            let out = try ImageOps.rotateFlip(image, RotateFlipOptions(rotation: .none, angle: 7, angleFill: fill))
            XCTAssertEqual(out.bitsPerComponent, 16)
            XCTAssertEqual(out.colorSpace?.name, CGColorSpace.displayP3)
        }
        let keystoned = try Perspective.apply(PerspectiveOptions(vertical: 30), to: image)
        XCTAssertEqual(keystoned.bitsPerComponent, 16)
        XCTAssertEqual(keystoned.colorSpace?.name, CGColorSpace.displayP3)
    }

    func testPeakCountsPerspectiveAndTrimCopies() {
        let pipeline = Pipeline(steps: [PipelineStep(operation: .perspective(PerspectiveOptions(vertical: 10)))])
        XCTAssertEqual(pipeline.peakPixels(sourceWidth: 100, sourceHeight: 100), 30_000)
        let trim = Pipeline(steps: [PipelineStep(operation: .trim(TrimOptions()))])
        XCTAssertEqual(trim.peakPixels(sourceWidth: 100, sourceHeight: 100), 20_000)
        let neutral = Pipeline(steps: [PipelineStep(operation: .perspective(PerspectiveOptions()))])
        XCTAssertEqual(neutral.peakPixels(sourceWidth: 100, sourceHeight: 100), 10_000)
    }

    func testAngleAfterRightAngleRotation() throws {
        let image = TestImages.make(width: 200, height: 100)
        let options = RotateFlipOptions(rotation: .cw90, angle: 90)
        let out = try ImageOps.rotateFlip(image, options)
        XCTAssertEqual(out.width, 200)
        XCTAssertEqual(out.height, 100)
    }

    func testCanvasAspectSquare() throws {
        let image = TestImages.make(width: 300, height: 200, color: red)
        let options = CanvasOptions(mode: .aspect(width: 1, height: 1), background: .white)
        let plan = Geometry.canvas(source: CGSize(width: 300, height: 200), options: options)
        XCTAssertEqual(plan.canvas, CGSize(width: 300, height: 300))
        XCTAssertEqual(plan.imageOrigin, CGPoint(x: 0, y: 50))
        let out = try ImageOps.canvas(image, options)
        XCTAssertEqual(out.width, 300)
        XCTAssertEqual(out.height, 300)
        XCTAssertGreaterThan(TestImages.pixel(of: out, x: 150, y: 10).blue, 240)
        XCTAssertLessThan(TestImages.pixel(of: out, x: 150, y: 150).blue, 15)
        // Never crops: an image already wider than 1:1 for a 1:2 target grows taller.
        let tall = Geometry.canvas(source: CGSize(width: 300, height: 200),
                                   options: CanvasOptions(mode: .aspect(width: 1, height: 2)))
        XCTAssertEqual(tall.canvas, CGSize(width: 300, height: 600))
    }

    func testOldRotateFlipJSONDecodes() throws {
        let json = #"{"rotation":180,"flipHorizontal":true,"flipVertical":false}"#
        let options = try JSONDecoder().decode(RotateFlipOptions.self, from: Data(json.utf8))
        XCTAssertEqual(options.rotation, .cw180)
        XCTAssertTrue(options.flipHorizontal)
        XCTAssertEqual(options.angle, 0)
        XCTAssertEqual(options.angleFill, .expand(background: .white))
        let round = try JSONDecoder().decode(RotateFlipOptions.self, from: JSONEncoder().encode(
            RotateFlipOptions(rotation: .none, angle: -3.5, angleFill: .cropToFit)))
        XCTAssertEqual(round.angle, -3.5)
        XCTAssertEqual(round.angleFill, .cropToFit)
    }

    func testSummaries() {
        XCTAssertEqual(ImageOperation.rotateFlip(RotateFlipOptions(rotation: .none, angle: 2.5,
                                                                   angleFill: .cropToFit)).summary,
                       "straighten 2.5°")
        XCTAssertEqual(ImageOperation.rotateFlip(RotateFlipOptions(rotation: .cw90, angle: -10)).summary,
                       "90° · rotate −10°")
        XCTAssertEqual(ImageOperation.canvas(CanvasOptions(mode: .aspect(width: 4, height: 3))).summary, "4:3")
    }
}
