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

    // MARK: Resampling

    /// A solid 8-bit image without an alpha channel.
    private func opaqueImage(width: Int, height: Int) -> CGImage {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            fatalError("Couldn't create a bitmap context")
        }
        ctx.setFillColor(red)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { fatalError("Couldn't make an image") }
        return image
    }

    func testResamplersKeepSizeColorSpaceAndDepth() throws {
        let image = TestImages.displayP3(width: 40, height: 20)
        for method in Resampling.allCases {
            for target in [(17, 9), (80, 41)] {
                let out = try Resampler.scale(image, to: target, method: method)
                XCTAssertEqual(out.width, target.0, "\(method)")
                XCTAssertEqual(out.height, target.1, "\(method)")
                XCTAssertEqual(out.bitsPerComponent, 16, "\(method)")
                XCTAssertEqual(out.colorSpace?.name as String?, CGColorSpace.displayP3 as String, "\(method)")
                // A solid image stays solid up to the edges (no dark or transparent fringe).
                for (col, row) in [(0, 0), (target.0 - 1, target.1 - 1), (target.0 / 2, target.1 / 2)] {
                    let pix = TestImages.pixel(of: out, x: col, y: row)
                    let reference = TestImages.pixel(of: image, x: 0, y: 0)
                    XCTAssertEqual(pix.red, reference.red, accuracy: 3, "\(method) (\(col),\(row))")
                    XCTAssertEqual(pix.green, reference.green, accuracy: 3, "\(method) (\(col),\(row))")
                    XCTAssertEqual(pix.alpha, 255, accuracy: 1, "\(method) (\(col),\(row))")
                }
            }
        }
    }

    func testResamplersKeepOpaqueAndAlpha() throws {
        let opaque = opaqueImage(width: 30, height: 20)
        let translucent = TestImages.make(width: 30, height: 20, alpha: 0.5)
        for method in Resampling.allCases {
            XCTAssertFalse(ImageOps.hasAlpha(try Resampler.scale(opaque, to: (12, 8), method: method)), "\(method)")
            let out = try Resampler.scale(translucent, to: (12, 8), method: method)
            XCTAssertTrue(ImageOps.hasAlpha(out), "\(method)")
            let pix = TestImages.pixel(of: out, x: 6, y: 4)
            let reference = TestImages.pixel(of: translucent, x: 6, y: 4)
            XCTAssertEqual(pix.alpha, 128, accuracy: 2, "\(method)")
            // Unpremultiplied colour matches: no straight/premultiplied mix-up.
            XCTAssertEqual(pix.red, reference.red, accuracy: 3, "\(method)")
            XCTAssertEqual(pix.green, reference.green, accuracy: 3, "\(method)")
            XCTAssertEqual(pix.blue, reference.blue, accuracy: 3, "\(method)")
        }
    }

    func testNearestKeepsHardEdges() throws {
        let image = TestImages.twoColor(width: 4, height: 2, left: red, right: blue)
        let out = try Resampler.scale(image, to: (40, 20), method: .nearest)
        // Exactly the source colours on both sides of the edge (compared after the same sRGB rendering).
        let sourceLeft = TestImages.pixel(of: image, x: 1, y: 0)
        let sourceRight = TestImages.pixel(of: image, x: 2, y: 0)
        let left = TestImages.pixel(of: out, x: 19, y: 10)
        let right = TestImages.pixel(of: out, x: 20, y: 10)
        XCTAssertEqual(left.red, sourceLeft.red, accuracy: 1)
        XCTAssertEqual(left.blue, sourceLeft.blue, accuracy: 1)
        XCTAssertEqual(right.blue, sourceRight.blue, accuracy: 1)
        XCTAssertEqual(right.red, sourceRight.red, accuracy: 1)
        // Lanczos blends across the edge.
        let smooth = try Resampler.scale(image, to: (40, 20), method: .lanczos)
        XCTAssertGreaterThan(TestImages.pixel(of: smooth, x: 19, y: 10).blue, sourceLeft.blue + 10)
    }

    func testResizeUsesChosenResampling() throws {
        let image = TestImages.twoColor(width: 4, height: 2, left: red, right: blue)
        let out = try ImageOps.resize(image, ResizeOptions(mode: .exactWidth(40), allowEnlarge: true,
                                                           resampling: .nearest))
        XCTAssertEqual(out.width, 40)
        XCTAssertEqual(TestImages.pixel(of: out, x: 19, y: 10).blue, TestImages.pixel(of: image, x: 0, y: 0).blue,
                       accuracy: 1)
    }

    func testDPIWrittenWithoutResampling() throws {
        let dir = try TestImages.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("in.png")
        try TestImages.write(TestImages.make(width: 30, height: 20), to: source, type: .png)
        for format in [OutputFormat.jpeg, .png, .tiff, .heic] {
            var pipeline = Pipeline(steps: [
                PipelineStep(operation: .resize(ResizeOptions(mode: .percent(100), dpi: 300)))
            ])
            pipeline.output.format = format
            let encoded = try BatchRunner.encodeItem(source, pipeline: pipeline, assets: .empty, maxPixels: 1_000_000)
            let props = try TestImages.properties(of: encoded.data)
            XCTAssertEqual((props[kCGImagePropertyDPIWidth as String] as? NSNumber)?.doubleValue ?? 0, 300,
                           accuracy: 0.5, "\(format)")
            XCTAssertEqual((props[kCGImagePropertyDPIHeight as String] as? NSNumber)?.doubleValue ?? 0, 300,
                           accuracy: 0.5, "\(format)")
            XCTAssertEqual(props[kCGImagePropertyPixelWidth as String] as? Int, 30, "\(format)")
            XCTAssertEqual(props[kCGImagePropertyPixelHeight as String] as? Int, 20, "\(format)")
        }
    }

    /// A 32-bit float sRGB image: left half opaque white, right half transparent (a hard alpha edge).
    private func floatEdgeImage(width: Int, height: Int) -> CGImage {
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.extendedSRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 32, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { fatalError("Couldn't create a float context") }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        guard let image = ctx.makeImage() else { fatalError("Couldn't make an image") }
        return image
    }

    func testFloatStaysFloatAndLanczosStaysInRange() throws {
        let image = floatEdgeImage(width: 16, height: 4)
        for method in Resampling.allCases {
            let out = try Resampler.scale(image, to: (40, 10), method: method)
            XCTAssertEqual(out.bitsPerComponent, 32, "\(method)")
            XCTAssertTrue(out.bitmapInfo.contains(.floatComponents), "\(method)")
        }
        // Lanczos rings at the hard edge; every premultiplied value must stay in 0 ≤ colour ≤ alpha ≤ 1.
        let out = try Resampler.scale(image, to: (40, 10), method: .lanczos)
        let data = try XCTUnwrap(out.dataProvider?.data) as Data
        data.withUnsafeBytes { raw in
            for row in 0..<out.height {
                for col in 0..<out.width {
                    let base = row * out.bytesPerRow + col * 16
                    let pixel = (0..<4).map { raw.loadUnaligned(fromByteOffset: base + $0 * 4, as: Float.self) }
                    XCTAssertGreaterThanOrEqual(pixel[3], 0)
                    XCTAssertLessThanOrEqual(pixel[3], 1)
                    for channel in 0..<3 {
                        XCTAssertGreaterThanOrEqual(pixel[channel], 0, "(\(col),\(row))")
                        XCTAssertLessThanOrEqual(pixel[channel], pixel[3] + 1e-6, "(\(col),\(row))")
                    }
                }
            }
        }
    }

    func testFillAndCropScalesOnlyTheKeptRegion() throws {
        // 40 x 10, red | blue: the centred square is 10 x 10 around the edge.
        let image = TestImages.twoColor(width: 40, height: 10, left: red, right: blue)
        let options = ResizeOptions(mode: .exactSize(width: 20, height: 20, fill: .fillAndCrop), allowEnlarge: true,
                                    resampling: .nearest)
        let out = try ImageOps.resize(image, options)
        XCTAssertEqual(out.width, 20)
        XCTAssertEqual(out.height, 20)
        assertRed(out, 4, 10)
        assertBlue(out, 15, 10)
        // A wide panorama into a square: works without building the 162 000 px wide intermediate.
        let panorama = TestImages.make(width: 30_000, height: 200)
        let square = try ImageOps.resize(panorama, ResizeOptions(
            mode: .exactSize(width: 1080, height: 1080, fill: .fillAndCrop), allowEnlarge: true))
        XCTAssertEqual(square.width, 1080)
        XCTAssertEqual(square.height, 1080)
    }
}
