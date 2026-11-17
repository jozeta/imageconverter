import CoreGraphics
import XCTest
@testable import ImageconverterCore

/// Text on a transparent background: Vision reads transparent pixels as black, so dark text on them was found
/// nowhere and the Redact step wrote it readable ("Redact: nothing found"). Real Vision, skipped when it finds no
/// text in the opaque control (CI virtual machines).
final class RedactTransparencyTests: XCTestCase {
    private static let black = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
    private static let white = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)

    private static func item(_ name: String, width: Int, background: RedactCorpus.Background,
                             color: RGBAColor = black) -> RedactCorpus.Case {
        RedactCorpus.Case(name: name, width: width, height: 300, background: background,
                          texts: [RedactCorpus.Text(string: "CONFIDENTIAL 4485 2231 9087", font: "Helvetica", size: 64,
                                                    color: color, center: CGPoint(x: Double(width) / 2, y: 150))])
    }

    private func assertCovered(_ item: RedactCorpus.Case, file: StaticString = #filePath, line: UInt = #line) {
        let outcome = RedactCorpusTests.run(item)
        XCTAssertTrue(outcome.covered, "\(item.name): text left visible \(outcome.coverages)", file: file, line: line)
    }

    private func skipWithoutVision() throws {
        let control = RedactCorpus.image(Self.item("control", width: 1400, background: .white))
        let found = Redaction.detect(.text, in: control, detector: SystemVisionDetector())
        try XCTSkipIf(found.failure != nil || found.text.isEmpty, "Vision found no text here (CI virtual machine?)")
    }

    func testDarkTextOnTransparencyIsFound() throws {
        try skipWithoutVision()
        assertCovered(Self.item("black on white", width: 1400, background: .white))
        assertCovered(Self.item("black on transparent", width: 1400, background: .transparent))
        // Wider than `Redaction.textMaxLongSide`: the full-resolution tiles are read too.
        assertCovered(Self.item("black on transparent 3000 px", width: 3000, background: .transparent))
    }

    func testLightTextOnTransparencyIsFound() throws {
        try skipWithoutVision()
        assertCovered(Self.item("white on transparent", width: 1400, background: .transparent, color: Self.white))
        assertCovered(Self.item("white on transparent 3000 px", width: 3000, background: .transparent,
                                color: Self.white))
    }

    func testTextOnTransparencyIsCountedOnce() throws {
        try skipWithoutVision()
        let image = RedactCorpus.image(Self.item("black on transparent", width: 1400, background: .transparent))
        let found = Redaction.detect(.text, in: image, detector: SystemVisionDetector())
        XCTAssertNil(found.failure)
        XCTAssertEqual(TextBoxes.distinctCount(found.text), 1, "one line, read on two backgrounds")
    }

    /// The working copy of an image with alpha is opaque, its transparent pixels the background; an opaque
    /// image is handed over as it is (no extra copy, no extra pass).
    func testFlattenedCopyIsOpaqueOnTheBackground() throws {
        let clear = RedactCorpus.image(Self.item("clear", width: 400, background: .transparent))
        for background in VisionInput.textBackgrounds + [VisionInput.faceBackground] {
            let copy = try XCTUnwrap(VisionInput.prepared(clear, maxSide: 2048, background: background))
            XCTAssertFalse(ImageOps.hasAlpha(copy))
            XCTAssertEqual(copy.width, 400)
            let corner = try XCTUnwrap(Self.firstPixel(copy))
            XCTAssertEqual(Double(corner), background * 255, accuracy: 1)
        }
        XCTAssertEqual(VisionInput.textBackgrounds, [1, 0])
        XCTAssertEqual(VisionInput.faceBackground, 0.5)
        XCTAssertEqual(VisionInput.backgrounds(forText: clear), [1, 0])
        let opaque = try XCTUnwrap(ImageEncoder.flattened(clear, onto: Self.white))
        XCTAssertFalse(ImageOps.hasAlpha(opaque))
        XCTAssertTrue(VisionInput.prepared(opaque, maxSide: 2048, background: 0.5) === opaque)
        XCTAssertEqual(VisionInput.backgrounds(forText: opaque), [nil])
    }

    /// The red channel of the top-left pixel.
    private static func firstPixel(_ image: CGImage) -> UInt8? {
        guard let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 1 - image.height, width: image.width, height: image.height))
        return ctx.data?.load(as: UInt8.self)
    }
}
