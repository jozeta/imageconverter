import CoreGraphics
import XCTest
@testable import ImageconverterCore

/// Perspective's output size (fit / keep original) and empty areas (crop, colour, transparent, extend edges).
final class PerspectiveFillTests: XCTestCase {
    private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    private let blue = RGBAColor(red: 0, green: 0, blue: 1, alpha: 1)

    private func corners(_ image: CGImage) -> [(Int, Int)] {
        [(0, 0), (image.width - 1, 0), (0, image.height - 1), (image.width - 1, image.height - 1)]
    }

    // MARK: Options

    func testOldOptionsDecodeToTodaysBehaviour() throws {
        let old = try JSONDecoder().decode(PerspectiveOptions.self, from: Data(#"{"vertical":20,"auto":true}"#.utf8))
        XCTAssertEqual(old.size, .fit)
        XCTAssertEqual(old.emptyAreas, .crop)
        XCTAssertEqual(old.fillColor, .white)
        let odd = try JSONDecoder().decode(PerspectiveOptions.self,
                                           from: Data(#"{"size":"huge","emptyAreas":7,"fillColor":"x"}"#.utf8))
        XCTAssertEqual(odd, PerspectiveOptions())
        let full = PerspectiveOptions(vertical: 12, horizontal: -3, auto: true, size: .keepOriginal,
                                      emptyAreas: .transparent, fillColor: blue)
        XCTAssertEqual(try JSONDecoder().decode(PerspectiveOptions.self, from: JSONEncoder().encode(full)), full)
    }

    func testSummaryNamesSizeAndEmptyAreas() {
        XCTAssertEqual(ImageOperation.perspective(PerspectiveOptions(vertical: 20)).summary, "vertical +20")
        XCTAssertEqual(ImageOperation.perspective(PerspectiveOptions(vertical: 8, size: .keepOriginal,
                                                                     emptyAreas: .transparent)).summary,
                       "vertical +8 · keep size · transparent")
        XCTAssertEqual(ImageOperation.perspective(PerspectiveOptions(horizontal: -5, emptyAreas: .color,
                                                                     fillColor: blue)).summary,
                       "horizontal −5 · fill #0000FF")
        XCTAssertEqual(ImageOperation.perspective(PerspectiveOptions(auto: true, emptyAreas: .extend)).summary,
                       "auto · extend edges")
        XCTAssertEqual(ImageOperation.perspective(PerspectiveOptions(size: .keepOriginal)).summary, "no change")
    }

    // MARK: Largest rectangle inside the corrected image

    func testSingleAxisCropIsUnchangedFromBefore() {
        let source = CGSize(width: 400, height: 300)
        for options in [PerspectiveOptions(vertical: 60), PerspectiveOptions(vertical: -100),
                        PerspectiveOptions(horizontal: 35), PerspectiveOptions(horizontal: -80)] {
            guard let quad = Geometry.keystoneQuad(source: source, options: options) else { return XCTFail("quad") }
            // Before this change: each side at the inner end of its edge, one pixel clear.
            let left = (max(quad.topLeft.x, quad.bottomLeft.x) + 1).rounded(.up)
            let right = (min(quad.topRight.x, quad.bottomRight.x) - 1).rounded(.down)
            let top = (max(quad.topLeft.y, quad.topRight.y) + 1).rounded(.up)
            let bottom = (min(quad.bottomLeft.y, quad.bottomRight.y) - 1).rounded(.down)
            XCTAssertEqual(Geometry.perspectiveCrop(source: source, options: options),
                           CGRect(x: left, y: top, width: right - left, height: bottom - top), "\(options)")
        }
    }

    func testCropIsInsideAndAsLargeAsABruteForceSearch() {
        let source = CGSize(width: 200, height: 160)
        for (vertical, horizontal) in [(-40.0, 30.0), (100, 100), (-100, -100), (70, -25), (15, 90)] {
            let options = PerspectiveOptions(vertical: vertical, horizontal: horizontal)
            guard let quad = Geometry.keystoneQuad(source: source, options: options),
                  let crop = Geometry.perspectiveCrop(source: source, options: options) else { return XCTFail("crop") }
            for point in [CGPoint(x: crop.minX, y: crop.minY), CGPoint(x: crop.maxX, y: crop.minY),
                          CGPoint(x: crop.minX, y: crop.maxY), CGPoint(x: crop.maxX, y: crop.maxY)] {
                XCTAssertTrue(quad.contains(point), "\(options) \(point)")
            }
            // Every whole-pixel top/bottom pair: the best rectangle's area.
            var best: CGFloat = 0
            for top in 0...160 {
                for bottom in top...160 {
                    guard let upper = quad.span(atY: CGFloat(top)), let lower = quad.span(atY: CGFloat(bottom)) else {
                        continue
                    }
                    let width = min(upper.upperBound, lower.upperBound) - max(upper.lowerBound, lower.lowerBound)
                    best = max(best, max(0, width) * CGFloat(bottom - top))
                }
            }
            // The crop keeps a pixel clear on each side, so allow that border.
            let found = (crop.width + 2) * (crop.height + 2)
            XCTAssertGreaterThanOrEqual(found, best * 0.98, "\(options)")
        }
    }

    func testCombinedAxesKeepMoreThanTheInnerEnds() {
        let source = CGSize(width: 400, height: 300)
        let options = PerspectiveOptions(vertical: 100, horizontal: 100)
        guard let quad = Geometry.keystoneQuad(source: source, options: options),
              let crop = Geometry.perspectiveCrop(source: source, options: options) else { return XCTFail("crop") }
        let innerWidth = min(quad.topRight.x, quad.bottomRight.x) - max(quad.topLeft.x, quad.bottomLeft.x)
        let innerHeight = min(quad.bottomLeft.y, quad.bottomRight.y) - max(quad.topLeft.y, quad.topRight.y)
        XCTAssertGreaterThan(crop.width * crop.height, innerWidth * innerHeight)
    }

    func testHomographyMapsTheCornersAndInvertsIt() throws {
        let quad = try XCTUnwrap(Geometry.keystoneQuad(source: CGSize(width: 300, height: 200),
                                                       options: PerspectiveOptions(vertical: 100, horizontal: 100)))
        let map = try XCTUnwrap(Homography(quad))
        let units = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        for (unit, corner) in zip(units, quad.corners) {
            XCTAssertEqual(map.point(for: unit).x, corner.x, accuracy: 1e-6)
            XCTAssertEqual(map.point(for: unit).y, corner.y, accuracy: 1e-6)
        }
        let back = try XCTUnwrap(map.unit(for: map.point(for: CGPoint(x: 0.3, y: 0.8))))
        XCTAssertEqual(back.x, 0.3, accuracy: 1e-6)
        XCTAssertEqual(back.y, 0.8, accuracy: 1e-6)
        // The sides meet above the top edge, the top and bottom edges right of it: (299, 0) is past that line.
        XCTAssertNil(map.unit(for: CGPoint(x: 299, y: 0)))
    }

    // MARK: Empty areas (fit)

    func testFillWithColourKeepsTheWholeCorrectedImage() throws {
        let image = TestImages.make(width: 400, height: 300, color: red)
        let options = PerspectiveOptions(vertical: 60, emptyAreas: .color, fillColor: blue)
        let out = try Perspective.apply(options, to: image)
        XCTAssertEqual(out.width, 400)
        XCTAssertEqual(out.height, 300)
        let corner = TestImages.pixel(of: out, x: 0, y: 0)
        XCTAssertEqual(corner.alpha, 255)
        XCTAssertGreaterThan(corner.blue, 240)
        XCTAssertLessThan(corner.red, 15)
        let centre = TestImages.pixel(of: out, x: 200, y: 150)
        XCTAssertGreaterThan(centre.red, 240)
        XCTAssertEqual(Pipeline.size(after: .perspective(options), from: CGSize(width: 400, height: 300)),
                       CGSize(width: 400, height: 300))
    }

    func testTransparentLeavesAlphaForFormatsWithAlpha() throws {
        let image = TestImages.make(width: 400, height: 300, color: red)
        let options = PerspectiveOptions(vertical: -60, horizontal: 20, emptyAreas: .transparent, fillColor: blue)
        let pipeline = Pipeline(steps: [PipelineStep(operation: .perspective(options))], output: .init(format: .png))
        var notes: [String] = []
        let out = try pipeline.apply(to: image, notes: &notes)
        XCTAssertTrue(notes.isEmpty)
        XCTAssertTrue(ImageOps.hasAlpha(out))
        XCTAssertEqual(TestImages.pixel(of: out, x: 0, y: out.height - 1).alpha, 0)
        XCTAssertEqual(TestImages.pixel(of: out, x: 200, y: 150).alpha, 255)
    }

    func testTransparentInJPEGFillsWithTheColourAndSaysSo() throws {
        let image = TestImages.make(width: 400, height: 300, color: red)
        let options = PerspectiveOptions(vertical: 60, emptyAreas: .transparent, fillColor: blue)
        let pipeline = Pipeline(steps: [PipelineStep(operation: .perspective(options))], output: .init(format: .jpeg))
        var notes: [String] = []
        let out = try pipeline.apply(to: image, notes: &notes)
        XCTAssertEqual(notes, ["No transparency in JPEG; filled with #0000FF"])
        let corner = TestImages.pixel(of: out, x: 0, y: 0)
        XCTAssertEqual(corner.alpha, 255)
        XCTAssertGreaterThan(corner.blue, 240)
        // Nothing empty (sliders at 0, fit): no note.
        var none: [String] = []
        _ = try Pipeline(steps: [PipelineStep(operation: .perspective(PerspectiveOptions(auto: false,
                                                                                         emptyAreas: .transparent)))],
                         output: .init(format: .jpeg)).apply(to: image, notes: &none)
        XCTAssertTrue(none.isEmpty)
    }

    func testExtendEdgesLeavesNoEmptyCorners() throws {
        // Left half green, right half red: the clamped corners repeat the nearest edge colour.
        let image = halves(width: 400, height: 300)
        let out = try Perspective.apply(PerspectiveOptions(vertical: 80, horizontal: -40, emptyAreas: .extend),
                                        to: image)
        XCTAssertEqual(out.width, 400)
        XCTAssertEqual(out.height, 300)
        for (col, row) in corners(out) {
            let pix = TestImages.pixel(of: out, x: col, y: row)
            XCTAssertEqual(pix.alpha, 255, "(\(col),\(row))")
            XCTAssertGreaterThan(col == 0 ? pix.green : pix.red, 200, "(\(col),\(row))")
        }
    }

    func testExtendEdgesFillsEveryCornerAtTheExtremes() throws {
        let image = TestImages.make(width: 300, height: 200, color: red)
        for vertical in [-100.0, -50, 0, 50, 100] {
            for horizontal in [-100.0, -50, 0, 50, 100] where vertical != 0 || horizontal != 0 {
                let options = PerspectiveOptions(vertical: vertical, horizontal: horizontal, emptyAreas: .extend)
                let out = try Perspective.apply(options, to: image)
                for (col, row) in corners(out) + [(out.width / 2, 0), (0, out.height / 2)] {
                    let pix = TestImages.pixel(of: out, x: col, y: row)
                    XCTAssertEqual(pix.alpha, 255, "\(vertical) \(horizontal) (\(col),\(row))")
                    XCTAssertGreaterThan(pix.red, 240, "\(vertical) \(horizontal) (\(col),\(row))")
                }
            }
        }
    }

    // MARK: Keep original size

    func testKeepSizeWithCropScalesToFill() throws {
        let image = TestImages.make(width: 400, height: 300, color: red)
        let options = PerspectiveOptions(vertical: -40, horizontal: 30, size: .keepOriginal)
        let out = try Perspective.apply(options, to: image)
        XCTAssertEqual(out.width, 400)
        XCTAssertEqual(out.height, 300)
        for (col, row) in corners(out) {
            let pix = TestImages.pixel(of: out, x: col, y: row)
            XCTAssertEqual(pix.alpha, 255, "(\(col),\(row))")
            XCTAssertGreaterThan(pix.red, 240, "(\(col),\(row))")
        }
        XCTAssertEqual(Pipeline.size(after: .perspective(options), from: CGSize(width: 400, height: 300)),
                       CGSize(width: 400, height: 300))
    }

    /// Auto finds a 200 x 100 rectangle in a 400 x 300 image: corrected 200 x 100, kept at 400 x 300.
    private func autoKeep(_ empty: PerspectiveEmptyAreas, opaque: Bool = false,
                          notes: inout [String]) throws -> CGImage {
        let image = halves(width: 400, height: 300)
        let found = Quad(topLeft: CGPoint(x: 100, y: 100), topRight: CGPoint(x: 300, y: 100),
                         bottomRight: CGPoint(x: 300, y: 200), bottomLeft: CGPoint(x: 100, y: 200))
        let options = PerspectiveOptions(auto: true, size: .keepOriginal, emptyAreas: empty, fillColor: blue)
        return try Perspective.apply(options, to: image, noAlpha: opaque ? .jpeg : nil, notes: &notes, detect: { _ in found })
    }

    func testKeepSizeFitsAutoCorrectionAndFillsTheBars() throws {
        var notes: [String] = []
        let filled = try autoKeep(.color, notes: &notes)
        XCTAssertEqual(filled.width, 400)
        XCTAssertEqual(filled.height, 300)
        // Scaled 2x to 400 x 200, centred: 50 px bars above and below.
        XCTAssertGreaterThan(TestImages.pixel(of: filled, x: 200, y: 10).blue, 240)
        XCTAssertGreaterThan(TestImages.pixel(of: filled, x: 200, y: 290).blue, 240)
        XCTAssertGreaterThan(TestImages.pixel(of: filled, x: 10, y: 150).green, 200)
        XCTAssertGreaterThan(TestImages.pixel(of: filled, x: 390, y: 150).red, 200)

        let clear = try autoKeep(.transparent, notes: &notes)
        XCTAssertEqual(TestImages.pixel(of: clear, x: 200, y: 10).alpha, 0)
        XCTAssertEqual(TestImages.pixel(of: clear, x: 200, y: 150).alpha, 255)
        XCTAssertTrue(notes.isEmpty)

        let extended = try autoKeep(.extend, notes: &notes)
        XCTAssertGreaterThan(TestImages.pixel(of: extended, x: 10, y: 10).green, 200)
        XCTAssertEqual(TestImages.pixel(of: extended, x: 10, y: 10).alpha, 255)

        let jpeg = try autoKeep(.transparent, opaque: true, notes: &notes)
        XCTAssertGreaterThan(TestImages.pixel(of: jpeg, x: 200, y: 10).blue, 240)
        XCTAssertEqual(notes, ["No transparency in JPEG; filled with #0000FF"])
    }

    func testKeepSizeWithCropCentreCropsTheAutoCorrection() throws {
        var notes: [String] = []
        let out = try autoKeep(.crop, notes: &notes)
        XCTAssertEqual(out.width, 400)
        XCTAssertEqual(out.height, 300)
        // Scaled 3x to 600 x 300, the middle 400 kept: still green left, red right, nothing empty.
        XCTAssertGreaterThan(TestImages.pixel(of: out, x: 5, y: 5).green, 200)
        XCTAssertGreaterThan(TestImages.pixel(of: out, x: 394, y: 294).red, 200)
        XCTAssertEqual(TestImages.pixel(of: out, x: 5, y: 5).alpha, 255)
    }

    func testTransparentInJPEGNoteReachesTheReport() async throws {
        let dir = try TestImages.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("plain.png")
        try TestImages.write(TestImages.make(width: 160, height: 120), to: url, type: .png)
        let item = InputItem(source: url, relativeDirectory: "")
        let options = PerspectiveOptions(vertical: 40, emptyAreas: .transparent)
        let pipeline = Pipeline(steps: [PipelineStep(operation: .perspective(options))], output: .init(format: .jpeg))
        let estimate = try SizeEstimator.render(item: item, pipeline: pipeline)
        XCTAssertEqual(estimate.note, "No transparency in JPEG; filled with #FFFFFF")
        let report = await BatchRunner.run([item], pipeline: pipeline,
                                           mode: .newFolder(dir.appendingPathComponent("out", isDirectory: true)))
        XCTAssertEqual(report.written.count, 1)
        XCTAssertEqual(report.notes.map(\.text), ["No transparency in JPEG; filled with #FFFFFF"])
    }

    /// Left half green, right half red.
    private func halves(width: Int, height: Int) -> CGImage {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("context") }
        ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        guard let image = ctx.makeImage() else { fatalError("image") }
        return image
    }
}
