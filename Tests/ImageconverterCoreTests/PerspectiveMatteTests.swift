import CoreGraphics
import XCTest
@testable import ImageconverterCore

/// Perspective's Transparent empty areas per output: formats without alpha are flattened onto the fill colour.
final class PerspectiveMatteTests: XCTestCase {
    private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    private let blue = RGBAColor(red: 0, green: 0, blue: 1, alpha: 1)

    func testPipelineAlwaysRendersTransparentWithAlpha() throws {
        let image = TestImages.make(width: 400, height: 300, color: red)
        let options = PerspectiveOptions(vertical: 60, emptyAreas: .transparent, fillColor: blue)
        let pipeline = Pipeline(steps: [PipelineStep(operation: .perspective(options))], output: .init(format: .jpeg))
        var notes: [String] = []
        let out = try pipeline.apply(to: image, notes: &notes)
        XCTAssertTrue(notes.isEmpty)
        XCTAssertEqual(TestImages.pixel(of: out, x: 0, y: 0).alpha, 0)
        XCTAssertEqual(pipeline.transparencyMatte, RGBAColor(red: 0, green: 0, blue: 1, alpha: 1))
        // Off, or doing nothing: no matte, so the encoder keeps flattening onto white.
        var off = pipeline
        off.steps[0].isEnabled = false
        XCTAssertNil(off.transparencyMatte)
        XCTAssertNil(Pipeline(steps: [PipelineStep(operation: .perspective(
            PerspectiveOptions(emptyAreas: .transparent)))]).transparencyMatte)
    }

    func testTranslucentFillColourIsOpaqueInJPEG() throws {
        let image = TestImages.make(width: 400, height: 300, color: red)
        let half = RGBAColor(red: 0, green: 0, blue: 1, alpha: 0.5)
        let pipeline = Pipeline(steps: [PipelineStep(operation: .perspective(
            PerspectiveOptions(vertical: 60, emptyAreas: .color, fillColor: half)))], output: .init(format: .jpeg))
        let (flat, _) = pipeline.matted(try pipeline.apply(to: image), for: .jpeg)
        let corner = TestImages.pixel(of: flat, x: 0, y: 0)
        XCTAssertEqual(corner.alpha, 255)
        XCTAssertGreaterThan(corner.blue, 240)
        XCTAssertLessThan(corner.red, 15)
    }

    /// Encodes one 400 x 300 red image through the batch's encoder with a main output and one extra output.
    private func encoded(main: OutputFormat, extra: OutputFormat) throws -> (main: (Data, String?),
                                                                            extra: (Data, String?)) {
        let dir = try TestImages.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("red.png")
        try TestImages.write(TestImages.make(width: 400, height: 300, color: red), to: url, type: .png)
        let options = PerspectiveOptions(vertical: 60, emptyAreas: .transparent, fillColor: blue)
        let variant = OutputVariant(name: "Other", settings: OutputSettings(format: extra), resize: nil)
        let pipeline = Pipeline(steps: [PipelineStep(operation: .perspective(options))],
                                output: OutputSettings(format: main, optimizePNG: false), extraOutputs: [variant])
        let item = try BatchRunner.encodeItem(url, pipeline: pipeline, assets: .empty, maxPixels: ImageOps.maxPixels,
                                              variants: [variant])
        let other = try XCTUnwrap(item.variants.first).outcome.get()
        return ((item.data, item.note), (other.data, other.note))
    }

    func testPNGMainKeepsTransparencyAndJPEGExtraGetsTheColour() throws {
        let result = try encoded(main: .png, extra: .jpeg)
        XCTAssertEqual(try TestImages.pixel(of: result.main.0, x: 0, y: 0).alpha, 0)
        XCTAssertNil(result.main.1)
        let corner = try TestImages.pixel(of: result.extra.0, x: 0, y: 0)
        XCTAssertGreaterThan(corner.blue, 230)
        XCTAssertLessThan(corner.red, 25)
        XCTAssertEqual(result.extra.1, "No transparency in JPEG; filled with #0000FF")
    }

    func testJPEGMainGetsTheColourAndPNGExtraKeepsTransparency() throws {
        let result = try encoded(main: .jpeg, extra: .png)
        let corner = try TestImages.pixel(of: result.main.0, x: 0, y: 0)
        XCTAssertGreaterThan(corner.blue, 230)
        XCTAssertEqual(result.main.1, "No transparency in JPEG; filled with #0000FF")
        XCTAssertEqual(try TestImages.pixel(of: result.extra.0, x: 0, y: 0).alpha, 0)
        XCTAssertNil(result.extra.1)
        let bmp = try encoded(main: .bmp, extra: .png)
        XCTAssertEqual(bmp.main.1, "No transparency in BMP; filled with #0000FF")
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
}

/// Steps saved before the empty-area choices keep the earlier crop until they are edited.
final class PerspectiveLegacyCropTests: XCTestCase {
    private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)

    func testOldStepsWithBothSlidersKeepTheEarlierCropPixelForPixel() throws {
        let image = TestImages.make(width: 400, height: 300, color: red)
        let old = try JSONDecoder().decode(PerspectiveOptions.self,
                                           from: Data(#"{"vertical":40,"horizontal":30}"#.utf8))
        let size = CGSize(width: 400, height: 300)
        let quad = try XCTUnwrap(Geometry.keystoneQuad(source: size, options: old))
        // The previous release: each side at the inner end of its edge, one pixel clear.
        let left = (max(quad.topLeft.x, quad.bottomLeft.x) + 1).rounded(.up)
        let right = (min(quad.topRight.x, quad.bottomRight.x) - 1).rounded(.down)
        let top = (max(quad.topLeft.y, quad.topRight.y) + 1).rounded(.up)
        let bottom = (min(quad.bottomLeft.y, quad.bottomRight.y) - 1).rounded(.down)
        let earlier = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        XCTAssertEqual(Geometry.perspectiveCrop(source: size, options: old), earlier)
        XCTAssertEqual(Pipeline.size(after: .perspective(old), from: size), earlier.size)
        // The previous release's render, step for step.
        let vector: (CGPoint) -> CIVector = { CIVector(x: $0.x, y: 300 - $0.y) }
        let warped = CIImage(cgImage: image).applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": vector(quad.topLeft), "inputTopRight": vector(quad.topRight),
            "inputBottomRight": vector(quad.bottomRight), "inputBottomLeft": vector(quad.bottomLeft)])
        let expected = try Adjustments.render(warped, from: CGRect(x: earlier.minX, y: 300 - earlier.maxY,
                                                                   width: earlier.width, height: earlier.height),
                                              like: image, step: "Perspective")
        let out = try Perspective.apply(old, to: image)
        XCTAssertEqual(out.width, expected.width)
        XCTAssertEqual(out.height, expected.height)
        XCTAssertEqual(out.dataProvider?.data as Data?, expected.dataProvider?.data as Data?)
        // New steps get the larger rectangle.
        var new = old
        new.cropRule = .largest
        let larger = try XCTUnwrap(Geometry.perspectiveCrop(source: size, options: new))
        XCTAssertGreaterThan(larger.width * larger.height, earlier.width * earlier.height)
    }

    func testEditingAnOldStepSwitchesToTheLargestCrop() throws {
        var options = try JSONDecoder().decode(PerspectiveOptions.self,
                                               from: Data(#"{"vertical":40,"horizontal":30}"#.utf8))
        options.applyUserEdit(options)
        XCTAssertEqual(options.cropRule, .innerEnds, "no change, no switch")
        var changed = options
        changed.vertical = 41
        options.applyUserEdit(changed)
        XCTAssertEqual(options.cropRule, .largest)
        XCTAssertEqual(options.vertical, 41)
    }
}
