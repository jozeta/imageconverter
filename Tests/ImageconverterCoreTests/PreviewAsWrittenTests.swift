import CoreGraphics
import Foundation
import XCTest
@testable import ImageconverterCore

/// The preview's After side shows the image as the output format stores it: a format without alpha is
/// flattened the way the encoder flattens it (onto white, or onto Perspective's fill colour).
final class PreviewAsWrittenTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try TestImages.tempDir() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// Large enough for a proxy (more than twice the 1600 px proxy minimum).
    private func transparentItem() throws -> InputItem {
        let url = dir.appendingPathComponent("clear.png")
        try TestImages.write(TestImages.make(width: 3400, height: 2000, alpha: 0), to: url, type: .png)
        return InputItem(source: url, relativeDirectory: "")
    }

    private func after(_ outcome: PreviewOutcome) throws -> CGImage {
        guard case .ready(let result) = outcome else { throw CocoaError(.fileReadUnknown) }
        return result.after
    }

    func testTransparentPNGPreviewedAsJPEGIsWhite() async throws {
        let item = try transparentItem()
        let pipeline = Pipeline(output: .init(format: .jpeg))
        let renderer = PreviewRenderer(displayMax: 200)
        let exact = try after(await renderer.render(item: item, index: 0, pipeline: pipeline))
        let proxy = await renderer.renderProxy(item: item, index: 0, pipeline: pipeline)
        for image in [exact, try XCTUnwrap(proxy).after] {
            let corner = TestImages.pixel(of: image, x: 0, y: 0)
            XCTAssertEqual(corner.alpha, 255)
            XCTAssertGreaterThan(min(corner.red, corner.green, corner.blue), 250)
        }
    }

    func testTransparentPNGPreviewedAsPNGKeepsAlpha() async throws {
        let pipeline = Pipeline(output: .init(format: .png))
        let image = try after(await PreviewRenderer(displayMax: 200).render(item: try transparentItem(), index: 0,
                                                                            pipeline: pipeline))
        XCTAssertEqual(TestImages.pixel(of: image, x: 0, y: 0).alpha, 0)
    }

    func testAsWrittenUsesThePerspectiveMatte() throws {
        let blue = RGBAColor(red: 0, green: 0, blue: 1, alpha: 1)
        let pipeline = Pipeline(steps: [PipelineStep(operation: .perspective(
            PerspectiveOptions(vertical: 60, emptyAreas: .transparent, fillColor: blue)))],
            output: .init(format: .jpeg))
        let shown = pipeline.asWritten(TestImages.make(width: 40, height: 30, alpha: 0), for: .jpeg)
        let corner = TestImages.pixel(of: shown, x: 0, y: 0)
        XCTAssertEqual(corner.alpha, 255)
        XCTAssertGreaterThan(corner.blue, 240)
    }
}
