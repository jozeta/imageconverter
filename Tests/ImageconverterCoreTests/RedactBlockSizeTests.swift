import CoreGraphics
import XCTest
@testable import ImageconverterCore

/// Pixelate's "Blocks across" and Blur's "Strength": relative to each area, so every slider position changes the
/// result on any image size (Johan: "when dragging the slider the pixel size is not changed").
final class RedactBlockSizeTests: XCTestCase {
    /// A 800 × 900 px face box on a 6000 × 4000 photo: today's fixed 4…200 px blocks all hit the floor there.
    private static let size = CGSize(width: 6000, height: 4000)
    private static let faceBox = CGRect(x: 0.4, y: 0.3, width: 800.0 / 6000, height: 900.0 / 4000)

    func testEveryBlocksAcrossValueChangesPixels() throws {
        let (image, rect) = Self.photo()
        for style in [RedactStyle.pixelate, .blur] {
            var digests: Set<Data> = []
            for across in RedactOptions.acrossRange {
                var options = RedactOptions(style: style)
                if style == .pixelate { options.blocksAcross = across } else { options.blurAcross = across }
                digests.insert(try Self.pixels(of: ImageOps.redact(image, options, rects: [rect]), in: rect))
            }
            XCTAssertEqual(digests.count, RedactOptions.acrossRange.count, "\(style): every value draws differently")
        }
    }

    func testBlocksAcrossNeverFinerThanFloor() {
        let rects = [CGRect(x: 0, y: 0, width: 1040, height: 1170), CGRect(x: 0, y: 0, width: 1430, height: 59),
                     CGRect(x: 0, y: 0, width: 30, height: 12)]
        for rect in rects {
            let floor = Redaction.minimumFixedSize(for: rect)
            for across in RedactOptions.acrossRange {
                var options = RedactOptions(style: .pixelate)
                options.blocksAcross = across
                options.blurAcross = across
                XCTAssertGreaterThanOrEqual(options.blockSize(for: rect), floor, "\(rect) \(across)")
                XCTAssertGreaterThanOrEqual(options.blurRadius(for: rect), floor, "\(rect) \(across)")
                XCTAssertFalse(options.raisesFixedSize(for: rect), "the floor is part of the scale: no note")
            }
        }
        // 5 is the floor itself, 3 is exactly Auto (stored as nil), 2 is coarser.
        let face = rects[0]
        var options = RedactOptions(style: .pixelate)
        options.blocksAcross = 5
        options.blurAcross = 5
        XCTAssertEqual(options.blockSize(for: face), 208)
        XCTAssertEqual(options.blurRadius(for: face), 208)
        options.blocksAcross = 2
        options.blurAcross = 2
        XCTAssertEqual(options.blockSize(for: face), 520)
        XCTAssertEqual(options.blurRadius(for: face), 520)
        XCTAssertEqual(RedactOptions(style: .pixelate).blockSize(for: face), Redaction.blockSize(for: face))
        XCTAssertEqual(RedactOptions(style: .blur).blurRadius(for: face), Redaction.blurRadius(for: face))
        XCTAssertEqual(RedactOptions.acrossRange, 2...5)
        XCTAssertEqual(RedactOptions.autoAcross, 3)
    }

    func testOldFixedBlockSizeDecodes() throws {
        let json = #"{"target":"faces","style":"pixelate","padding":15,"blockSize":16,"blurRadius":20}"#
        let old = try JSONDecoder().decode(RedactOptions.self, from: Data(json.utf8))
        XCTAssertEqual(old.fixedBlockSize, 16)
        XCTAssertEqual(old.fixedBlurRadius, 20)
        XCTAssertNil(old.blocksAcross)
        XCTAssertNil(old.blurAcross)
        // Today's behaviour: the px size, raised to the floor, with the note.
        let small = CGRect(x: 0, y: 0, width: 60, height: 50)
        let face = CGRect(x: 0, y: 0, width: 1040, height: 1170)
        XCTAssertEqual(old.blockSize(for: small), 16)
        XCTAssertEqual(old.blockSize(for: face), 208)
        XCTAssertEqual(old.blurRadius(for: small), 20)
        XCTAssertTrue(old.raisesFixedSize(for: face))
        XCTAssertEqual(old.raisedNote(for: [face]), "Block size raised to keep 1 area unreadable")
        var built = RedactOptions(target: .faces, style: .pixelate)
        built.fixedBlockSize = 16
        built.fixedBlurRadius = 20
        XCTAssertEqual(old, built)
        let (image, rect) = Self.photo()
        XCTAssertEqual(try Self.pixels(of: ImageOps.redact(image, old, rects: [rect]), in: rect),
                       try Self.pixels(of: ImageOps.redact(image, built, rects: [rect]), in: rect))
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(old), encoding: .utf8))
        XCTAssertTrue(encoded.contains(#""blockSize":16"#), encoded)
        XCTAssertFalse(encoded.contains("Across"), encoded)
        XCTAssertEqual(old.summary, "faces · pixelate · blocks 16 px")
    }

    func testRoundTripRelative() throws {
        var options = RedactOptions(target: .both, style: .pixelate)
        options.blocksAcross = 2
        options.blurAcross = 5
        let data = try JSONEncoder().encode(options)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains(#""blocksAcross":2"#), json)
        XCTAssertTrue(json.contains(#""blurAcross":5"#), json)
        XCTAssertFalse(json.contains("blockSize"), json)
        XCTAssertEqual(try JSONDecoder().decode(RedactOptions.self, from: data), options)
        XCTAssertEqual(options.summary, "faces and text · pixelate · 2 blocks across")
        options.style = .blur
        XCTAssertEqual(options.summary, "faces and text · blur · radius 1/5 of each area")
        // Out of range is clamped, a non-number is Auto; Auto isn't written.
        let odd = try JSONDecoder().decode(RedactOptions.self,
                                           from: Data(#"{"style":"pixelate","blocksAcross":40,"blurAcross":"x"}"#.utf8))
        XCTAssertEqual(odd.clampedBlocksAcross, 5)
        XCTAssertNil(odd.blurAcross)
        let auto = try XCTUnwrap(String(data: JSONEncoder().encode(RedactOptions()), encoding: .utf8))
        XCTAssertFalse(auto.contains("Across"), auto)
    }

    func testRelativeChoiceWinsOverAnOldPixelSize() {
        var options = RedactOptions(style: .pixelate)
        options.fixedBlockSize = 16
        let edited = options.withAcross(4)
        XCTAssertEqual(edited.blocksAcross, 4)
        XCTAssertNil(edited.fixedBlockSize, "the first edit switches to relative")
        XCTAssertNil(options.withAcross(RedactOptions.autoAcross).blocksAcross, "3 is Auto")
        XCTAssertNil(options.withAcross(RedactOptions.autoAcross).fixedBlockSize)
        var blur = RedactOptions(style: .blur)
        blur.fixedBlurRadius = 30
        let strong = blur.withAcross(2)
        XCTAssertEqual(strong.blurAcross, 2)
        XCTAssertNil(strong.fixedBlurRadius)
        XCTAssertEqual(options.across, RedactOptions.autoAcross)
        XCTAssertEqual(options.legacyPixels, 16)
        XCTAssertNil(edited.legacyPixels)
    }

    func testPreviewShowsTheRaisedNoteOnlyForAnOldPixelSize() async throws {
        let dir = try TestImages.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.png")
        try TestImages.write(TestImages.noise(width: 400, height: 400), to: url, type: .png)
        let renderer = PreviewRenderer(detector: FakeVisionDetector(faces: [CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)]))
        let item = InputItem(source: url, relativeDirectory: "")
        var old = RedactOptions(style: .pixelate)
        old.fixedBlockSize = 4
        for (options, expected) in [(old, "Block size raised to keep 1 area unreadable"),
                                    (old.withAcross(5), nil)] {
            let pipeline = Pipeline(steps: [PipelineStep(operation: .redact(options))])
            guard case .ready(let result) = await renderer.render(item: item, index: 0, pipeline: pipeline) else {
                return XCTFail("preview failed")
            }
            XCTAssertEqual(result.redactSizeNote, expected)
        }
        XCTAssertTrue(RedactOptions.isRaisedNote("Blur strength raised to keep 2 areas unreadable"))
        XCTAssertFalse(RedactOptions.isRaisedNote("Redacted 1 face"))
    }

    /// A 6000 × 4000 image with a fine checker pattern inside the padded face box (cheap to build).
    private static func photo() -> (CGImage, CGRect) {
        let rect = Redaction.pixelRects([faceBox], padding: RedactOptions.defaultPadding, in: size)[0]
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError() }
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let cell = 37.0
        var row = 0
        for top in stride(from: Double(rect.minY), to: Double(rect.maxY), by: cell) {
            var col = 0
            for left in stride(from: Double(rect.minX), to: Double(rect.maxX), by: cell) {
                let shade = Double((row * 7 + col * 13) % 17) / 16
                ctx.setFillColor(CGColor(red: shade, green: 1 - shade, blue: (row + col) % 2 == 0 ? 0.1 : 0.9, alpha: 1))
                ctx.fill(CGRect(x: left, y: size.height - top - cell, width: cell, height: cell))
                col += 1
            }
            row += 1
        }
        guard let image = ctx.makeImage() else { fatalError() }
        return (image, rect)
    }

    /// The RGBA bytes of `rect` (top-left origin) in `image`.
    private static func pixels(of image: CGImage, in rect: CGRect) throws -> Data {
        let crop = try XCTUnwrap(image.cropping(to: rect))
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8,
                                          bytesPerRow: crop.width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return Data(bytes: try XCTUnwrap(ctx.data), count: crop.width * crop.height * 4)
    }
}
