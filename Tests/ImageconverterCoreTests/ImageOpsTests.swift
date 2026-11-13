import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

final class ImageOpsTests: XCTestCase {
    private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    private let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)

    private func assertRed(_ image: CGImage, _ col: Int, _ row: Int, file: StaticString = #filePath, line: UInt = #line) {
        let pix = TestImages.pixel(of: image, x: col, y: row)
        XCTAssertGreaterThan(pix.red, 200, "(\(col),\(row)) should be red", file: file, line: line)
        XCTAssertLessThan(pix.blue, 50, "(\(col),\(row)) should be red", file: file, line: line)
    }

    private func assertBlue(_ image: CGImage, _ col: Int, _ row: Int, file: StaticString = #filePath, line: UInt = #line) {
        let pix = TestImages.pixel(of: image, x: col, y: row)
        XCTAssertGreaterThan(pix.blue, 200, "(\(col),\(row)) should be blue", file: file, line: line)
        XCTAssertLessThan(pix.red, 50, "(\(col),\(row)) should be blue", file: file, line: line)
    }

    func testResizeDimensions() throws {
        let out = try ImageOps.resize(TestImages.make(width: 4000, height: 3000),
                                      ResizeOptions(mode: .maxWidth(1600)))
        XCTAssertEqual(out.width, 1600)
        XCTAssertEqual(out.height, 1200)
    }

    func testResizeUnchangedReturnsInput() throws {
        let image = TestImages.make(width: 100, height: 50)
        let out = try ImageOps.resize(image, ResizeOptions(mode: .maxWidth(1600)))
        XCTAssertTrue(out === image)
    }

    func testFitAndPadFillsWithPadColor() throws {
        let image = TestImages.make(width: 400, height: 200, color: red)
        let options = ResizeOptions(mode: .exactSize(width: 200, height: 200, fill: .fitAndPad), padColor: .white)
        let out = try ImageOps.resize(image, options)
        XCTAssertEqual(out.width, 200)
        XCTAssertEqual(out.height, 200)
        let pad = TestImages.pixel(of: out, x: 100, y: 5)
        XCTAssertGreaterThan(pad.red, 250)
        XCTAssertGreaterThan(pad.blue, 250)
        assertRed(out, 100, 100)
    }

    func testFillAndCropCentres() throws {
        let image = TestImages.twoColor(width: 300, height: 100, left: red, right: blue)
        let options = ResizeOptions(mode: .exactSize(width: 100, height: 100, fill: .fillAndCrop))
        let out = try ImageOps.resize(image, options)
        XCTAssertEqual(out.width, 100)
        XCTAssertEqual(out.height, 100)
        assertRed(out, 10, 50)
        assertBlue(out, 90, 50)
    }

    func testCropTakesAnchoredRegion() throws {
        let image = TestImages.twoColor(width: 200, height: 100, left: red, right: blue)
        let out = try ImageOps.crop(image, CropOptions(mode: .size(width: 100, height: 100), anchor: .right))
        XCTAssertEqual(out.width, 100)
        assertBlue(out, 5, 50)
        assertBlue(out, 95, 50)
    }

    func testRotate90Clockwise() throws {
        let image = TestImages.twoColor(width: 200, height: 100, left: red, right: blue)
        let out = try ImageOps.rotateFlip(image, RotateFlipOptions(rotation: .cw90))
        XCTAssertEqual(out.width, 100)
        XCTAssertEqual(out.height, 200)
        assertRed(out, 50, 10)
        assertBlue(out, 50, 190)
    }

    func testRotate180And270() throws {
        let image = TestImages.twoColor(width: 200, height: 100, left: red, right: blue)
        let half = try ImageOps.rotateFlip(image, RotateFlipOptions(rotation: .cw180))
        assertBlue(half, 10, 50)
        assertRed(half, 190, 50)
        let three = try ImageOps.rotateFlip(image, RotateFlipOptions(rotation: .cw270))
        assertBlue(three, 50, 10)
        assertRed(three, 50, 190)
    }

    func testFlipHorizontal() throws {
        let image = TestImages.twoColor(width: 200, height: 100, left: red, right: blue)
        let out = try ImageOps.rotateFlip(image, RotateFlipOptions(rotation: .none, flipHorizontal: true))
        assertBlue(out, 10, 50)
        assertRed(out, 190, 50)
    }

    func testFlipVerticalAfterRotation() throws {
        let image = TestImages.twoColor(width: 200, height: 100, left: red, right: blue)
        let out = try ImageOps.rotateFlip(image, RotateFlipOptions(rotation: .cw90, flipVertical: true))
        assertBlue(out, 50, 10)
        assertRed(out, 50, 190)
    }

    func testCanvasTransparentKeepsAlpha() throws {
        let image = TestImages.make(width: 10, height: 10, color: red)
        let out = try ImageOps.canvas(image, CanvasOptions(mode: .padding(pixels: 5), background: .clear))
        XCTAssertEqual(out.width, 20)
        XCTAssertEqual(out.height, 20)
        XCTAssertEqual(TestImages.pixel(of: out, x: 1, y: 1).alpha, 0)
        assertRed(out, 10, 10)
        let dir = try TestImages.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.png")
        try TestImages.write(out, to: url, type: .png)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(try TestImages.pixel(of: data, x: 1, y: 1).alpha, 0)
    }

    func testCanvasHugeThrows() {
        let image = TestImages.make(width: 10, height: 10)
        XCTAssertThrowsError(try ImageOps.canvas(image, CanvasOptions(mode: .padding(pixels: Int.max)))) {
            XCTAssertEqual($0 as? ConversionError, .processingFailed("Canvas / padding"))
        }
    }

    func testWideGamut16BitPreserved() throws {
        let image = TestImages.displayP3(width: 40, height: 20)
        XCTAssertEqual(image.bitsPerComponent, 16)
        let resized = try ImageOps.resize(image, ResizeOptions(mode: .exactWidth(20)))
        let cropped = try ImageOps.crop(resized, CropOptions(mode: .size(width: 10, height: 10)))
        for out in [resized, cropped] {
            XCTAssertEqual(out.bitsPerComponent, 16)
            XCTAssertEqual(out.colorSpace?.name as String?, CGColorSpace.displayP3 as String)
        }
        let rotated = try ImageOps.rotateFlip(image, RotateFlipOptions(rotation: .cw90))
        XCTAssertEqual(rotated.bitsPerComponent, 16)
    }
}
