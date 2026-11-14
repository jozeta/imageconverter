import ImageIO
import XCTest
@testable import ImageconverterCore

final class ImageLoaderTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws { dir = try TestImages.tempDir() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testLoadsPNG() throws {
        let url = dir.appendingPathComponent("a.png")
        try TestImages.write(TestImages.make(width: 40, height: 20), to: url, type: .png)
        let loaded = try ImageLoader.load(url)
        XCTAssertEqual(loaded.image.width, 40)
        XCTAssertEqual(loaded.image.height, 20)
    }

    func testAppliesExifOrientation() throws {
        let url = dir.appendingPathComponent("rot.jpg")
        try TestImages.write(TestImages.make(width: 40, height: 20), to: url, type: .jpeg,
                             properties: [kCGImagePropertyOrientation as String: 6])
        let loaded = try ImageLoader.load(url)
        XCTAssertEqual(loaded.image.width, 20)
        XCTAssertEqual(loaded.image.height, 40)
        XCTAssertEqual(loaded.properties[kCGImagePropertyOrientation as String] as? Int, 1)
    }

    func testRejectsOverPixelLimit() throws {
        let url = dir.appendingPathComponent("big.png")
        try TestImages.write(TestImages.make(width: 100, height: 100), to: url, type: .png)
        XCTAssertThrowsError(try ImageLoader.load(url, maxPixels: 9_999)) {
            XCTAssertEqual($0 as? ConversionError, .tooLarge(pixels: 10_000))
        }
    }

    func testCorruptAndEmptyFilesAreUnreadable() throws {
        let empty = dir.appendingPathComponent("empty.jpg")
        try Data().write(to: empty)
        let junk = dir.appendingPathComponent("junk.png")
        try Data("not an image".utf8).write(to: junk)
        for url in [empty, junk] {
            XCTAssertThrowsError(try ImageLoader.load(url)) { XCTAssertEqual($0 as? ConversionError, .unreadable) }
        }
    }

    func testTooLargeReasonFormatsMegapixels() {
        XCTAssertEqual(ConversionError.tooLarge(pixels: 412_000_000).reason,
                       "Image is too large (412 MP, limit 250 MP)")
    }

    // MARK: Decode-time downsampling

    /// A smooth photo-like image: gradients and soft-edged shapes (no pixel-level noise).
    private func photo(width: Int, height: Int) -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: space, colors: [
                  CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1), CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1),
              ] as CFArray, locations: [0, 1]) else { fatalError("Couldn't create a context") }
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        let radial = CGGradient(colorsSpace: space, colors: [
            CGColor(red: 1, green: 1, blue: 0.6, alpha: 1), CGColor(red: 1, green: 1, blue: 0.6, alpha: 0),
        ] as CFArray, locations: [0, 1])
        if let radial {
            let center = CGPoint(x: width / 3, y: height / 2)
            ctx.drawRadialGradient(radial, startCenter: center, startRadius: 0, endCenter: center,
                                   endRadius: CGFloat(height) / 3, options: [])
        }
        guard let image = ctx.makeImage() else { fatalError("Couldn't make an image") }
        return image
    }

    private func resize(_ mode: ResizeMode, _ resampling: Resampling = .lanczos) -> PipelineStep {
        PipelineStep(operation: .resize(ResizeOptions(mode: mode, resampling: resampling)))
    }

    func testDecodeDownsampleMatchesFullPath() throws {
        let url = dir.appendingPathComponent("photo.png")
        try TestImages.write(photo(width: 1600, height: 1200), to: url, type: .png)
        for mode in [ResizeMode.longestEdge(300), .maxWidth(250), .percent(20), .fitBox(width: 320, height: 320)] {
            let pipeline = Pipeline(steps: [resize(mode)])
            let full = try BatchRunner.prepare(url, pipeline: pipeline, assets: .empty, maxPixels: 250_000_000)
            let fast = try BatchRunner.prepare(url, pipeline: pipeline, assets: .empty, maxPixels: 250_000_000,
                                               downsample: true)
            XCTAssertEqual(fast.image.width, full.image.width, "\(mode)")
            XCTAssertEqual(fast.image.height, full.image.height, "\(mode)")
            let stats = try XCTUnwrap(ImageDifference.stats(before: full.image, after: fast.image))
            XCTAssertGreaterThan(stats.psnr, 40, "\(mode)")
            // Peak memory: the decoded image is far smaller.
            XCTAssertEqual(full.source.width * full.source.height, 1600 * 1200)
            XCTAssertLessThan(fast.source.width * fast.source.height, 1600 * 1200 / 4, "\(mode)")
        }
    }

    func testDownsampleKeepsTheSourceMetadataAndDPI() throws {
        let url = dir.appendingPathComponent("photo.jpg")
        try TestImages.write(photo(width: 1200, height: 800), to: url, type: .jpeg, properties: [
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFArtist as String: "Ann"],
        ])
        var pipeline = Pipeline(steps: [resize(.physical(width: 2, height: nil, unit: .inch, dpi: 100))])
        pipeline.metadata = MetadataOptions(isEnabled: true)
        let full = try BatchRunner.prepare(url, pipeline: pipeline, assets: .empty, maxPixels: 250_000_000)
        let fast = try BatchRunner.prepare(url, pipeline: pipeline, assets: .empty, maxPixels: 250_000_000,
                                           downsample: true)
        XCTAssertLessThan(fast.source.width, full.source.width)
        XCTAssertEqual(fast.image.width, 200)
        XCTAssertEqual(fast.properties[kCGImagePropertyDPIWidth as String] as? Double,
                       full.properties[kCGImagePropertyDPIWidth as String] as? Double)
        // The artist travels in the output XMP, read from the original file.
        XCTAssertTrue(fast.properties.values.contains { "\($0)".contains("dc:[0] = Ann") })
        XCTAssertEqual(fast.properties[kCGImagePropertyPixelWidth as String] as? Int, 1200)
    }

    func testDownsampleNotUsedWhenCropFirst() throws {
        let url = dir.appendingPathComponent("photo.png")
        try TestImages.write(photo(width: 1600, height: 1200), to: url, type: .png)
        let pipeline = Pipeline(steps: [PipelineStep(operation: .crop(CropOptions())), resize(.longestEdge(200))])
        XCTAssertNil(pipeline.decodeHint(sourceWidth: 1600, sourceHeight: 1200))
        let prepared = try BatchRunner.prepare(url, pipeline: pipeline, assets: .empty, maxPixels: 250_000_000,
                                               downsample: true)
        XCTAssertEqual(prepared.source.width, 1600, "Decoded at full size")
        XCTAssertEqual(prepared.image.width, 200)
    }

    func testDecodeHintEligibility() throws {
        let shrink = resize(.longestEdge(200))
        func hint(_ steps: [PipelineStep], width: Int = 1600, height: Int = 1200) -> DecodeHint? {
            Pipeline(steps: steps).decodeHint(sourceWidth: width, sourceHeight: height)
        }
        // Eligible: a shrinking resize first, or after 90° turns and flips, or after a switched-off step.
        let plain = try XCTUnwrap(hint([shrink]))
        XCTAssertEqual(plain.maxLongSide, 400)
        XCTAssertEqual(plain.pipeline.steps.first?.operation,
                       .resize(ResizeOptions(mode: .exactSize(width: 200, height: 150, fill: .stretch),
                                             allowEnlarge: true)))
        let turned = PipelineStep(operation: .rotateFlip(RotateFlipOptions(rotation: .cw90, flipHorizontal: true)))
        XCTAssertNotNil(hint([turned, shrink]))
        XCTAssertNotNil(hint([PipelineStep(isEnabled: false, operation: .crop(CropOptions())), shrink]))
        // Steps after the resize don't matter.
        XCTAssertNotNil(hint([shrink, PipelineStep(operation: .adjust(AdjustOptions(exposure: 1)))]))

        // Not eligible: anything before it that reads or moves full-size pixels.
        let before: [ImageOperation] = [
            .crop(CropOptions()),
            .rotateFlip(RotateFlipOptions(rotation: .none, angle: 5)),
            .perspective(PerspectiveOptions(vertical: 10)),
            .trim(TrimOptions()),
            .canvas(CanvasOptions()),
            .colorProfile(.sRGB),
            .adjust(AdjustOptions(exposure: 1)),
            .watermark(WatermarkOptions()),
            .condition(ConditionalStep()),
        ]
        for operation in before {
            XCTAssertNil(hint([PipelineStep(operation: operation), shrink]), "\(operation.kind)")
        }
        // Not eligible: no resize, a resize that doesn't shrink (or barely), padding/cropping fills, nearest.
        XCTAssertNil(hint([]))
        XCTAssertNil(hint([resize(.longestEdge(3000))]))
        XCTAssertNil(hint([resize(.longestEdge(1000))]), "2 × 1000 isn't smaller than the source")
        XCTAssertNil(hint([resize(.exactSize(width: 200, height: 200, fill: .fitAndPad))]))
        XCTAssertNil(hint([resize(.exactSize(width: 200, height: 200, fill: .fillAndCrop))]))
        XCTAssertNil(hint([resize(.longestEdge(200), .nearest)]))
        XCTAssertNil(hint([shrink], width: 0, height: 0))
    }

    func testDownsampleNotUsedForConditionResolvedCrop() throws {
        let url = dir.appendingPathComponent("photo.png")
        try TestImages.write(photo(width: 1600, height: 1200), to: url, type: .png)
        let branch = ConditionalStep(conditions: [.longestEdge(.greaterThan, 100)],
                                     then: [.step(PipelineStep(operation: .crop(CropOptions())))])
        let pipeline = Pipeline(steps: [PipelineStep(operation: .condition(branch)), resize(.longestEdge(200))])
        let resolved = pipeline.resolved(forSource: url, maxPixels: 250_000_000).pipeline
        XCTAssertNil(resolved.decodeHint(sourceWidth: 1600, sourceHeight: 1200))
        // The branch not taken leaves the resize first: eligible.
        let other = ConditionalStep(conditions: [.longestEdge(.lessThan, 100)],
                                    then: [.step(PipelineStep(operation: .crop(CropOptions())))])
        let plain = Pipeline(steps: [PipelineStep(operation: .condition(other)), resize(.longestEdge(200))])
            .resolved(forSource: url, maxPixels: 250_000_000).pipeline
        XCTAssertNotNil(plain.decodeHint(sourceWidth: 1600, sourceHeight: 1200))
    }

    func testDecodeFailureIsNotUnreadable() {
        XCTAssertNotEqual(ConversionError.decodeFailed.reason, ConversionError.unreadable.reason)
    }
}
