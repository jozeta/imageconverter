import XCTest
@testable import ImageconverterCore

final class WatermarkModelTests: XCTestCase {
    private func options(_ content: WatermarkContent, anchor: Anchor = .bottomRight, size: Double = 4,
                         margin: Double = 3) -> WatermarkOptions {
        WatermarkOptions(content: content, anchor: anchor, sizePercent: size, opacity: 0.65, marginPercent: margin)
    }

    func testDefaultsAndSummary() {
        let defaults = WatermarkOptions()
        XCTAssertEqual(defaults.content, .text(TextWatermark(text: "©", fontName: "Helvetica-Bold", color: .white)))
        XCTAssertEqual(defaults.anchor, .bottomRight)
        XCTAssertEqual(defaults.sizePercent, 4)
        XCTAssertEqual(defaults.opacity, 0.65)
        XCTAssertEqual(defaults.marginPercent, 3)
        XCTAssertEqual(StepKind.allCases.last, .watermark)
        XCTAssertEqual(StepKind.watermark.displayName, "Watermark")
        XCTAssertEqual(StepKind.watermark.defaultOperation, .watermark(WatermarkOptions()))
        XCTAssertEqual(ImageOperation.watermark(defaults).kind, .watermark)

        let text = options(.text(TextWatermark(text: "© Johan")))
        XCTAssertEqual(ImageOperation.watermark(text).summary, "© Johan · bottom right · 4 %")
        let logo = options(.image(ImageWatermark(path: "/a/b/logo.png")), anchor: .topLeft, size: 20)
        XCTAssertEqual(ImageOperation.watermark(logo).summary, "logo.png · top left · 20 %")
        let empty = options(.image(ImageWatermark()))
        XCTAssertEqual(empty.summary, "no image · bottom right · 4 %")
        let long = options(.text(TextWatermark(text: String(repeating: "a", count: 25))))
        XCTAssertEqual(long.summary, String(repeating: "a", count: 20) + "… · bottom right · 4 %")
    }

    func testCodableRoundTripAndPartialDecode() throws {
        let original = options(.image(ImageWatermark(path: "/x/logo.png")), anchor: .top, size: 12.5, margin: 7)
        let data = try JSONEncoder().encode(ImageOperation.watermark(original))
        XCTAssertEqual(try JSONDecoder().decode(ImageOperation.self, from: data), .watermark(original))

        let content = try JSONEncoder().encode(WatermarkContent.text(TextWatermark(text: "Hi")))
        let contentJSON = try XCTUnwrap(String(bytes: content, encoding: .utf8))
        let json = "{\"content\": \(contentJSON)}"
        let partial = try JSONDecoder().decode(WatermarkOptions.self, from: Data(json.utf8))
        XCTAssertEqual(partial.content, .text(TextWatermark(text: "Hi")))
        XCTAssertEqual(partial.anchor, .bottomRight)
        XCTAssertEqual(partial.sizePercent, 4)
        XCTAssertEqual(partial.opacity, 0.65)
        XCTAssertEqual(partial.marginPercent, 3)

        let bare = try JSONDecoder().decode(WatermarkOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(bare, WatermarkOptions())
    }

    func testImageWatermarkSizedByShorterSide() throws {
        let rect = try XCTUnwrap(Geometry.watermarkRect(
            imageSize: CGSize(width: 4000, height: 3000), contentSize: CGSize(width: 500, height: 250),
            options: options(.image(ImageWatermark(path: "a.png")), size: 20)))
        XCTAssertEqual(rect, CGRect(x: 3310, y: 2610, width: 600, height: 300))
    }

    func testTextScaledByHeight() throws {
        let rect = try XCTUnwrap(Geometry.watermarkRect(
            imageSize: CGSize(width: 1000, height: 1500), contentSize: CGSize(width: 300, height: 50),
            options: options(.text(TextWatermark()))))
        XCTAssertEqual(rect.height, 40, accuracy: 0.0001)
        XCTAssertEqual(rect.width, 240, accuracy: 0.0001)
    }

    func testTooWideIsScaledDownToFit() throws {
        let rect = try XCTUnwrap(Geometry.watermarkRect(
            imageSize: CGSize(width: 400, height: 300), contentSize: CGSize(width: 3000, height: 50),
            options: options(.text(TextWatermark()), size: 10)))
        let margin = 300 * 0.03
        XCTAssertLessThanOrEqual(rect.width, 400 - 2 * margin + 0.0001)
        XCTAssertEqual(rect.width, 400 - 2 * margin, accuracy: 0.0001)
        XCTAssertEqual(rect.width / rect.height, 60, accuracy: 0.0001)
        XCTAssertEqual(rect.maxX, 400 - margin, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(rect.minX, margin - 0.0001)
    }

    func testTinyImage() {
        let bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        for anchor in Anchor.allCases {
            let rect = Geometry.watermarkRect(imageSize: bounds.size, contentSize: CGSize(width: 300, height: 50),
                                              options: options(.text(TextWatermark()), anchor: anchor))
            if let rect { XCTAssertTrue(bounds.contains(rect), "\(anchor) \(rect)") }
        }
        let big = Geometry.watermarkRect(imageSize: bounds.size, contentSize: CGSize(width: 10, height: 10),
                                         options: options(.image(ImageWatermark(path: "a")), size: 100, margin: 25))
        XCTAssertEqual(big, CGRect(x: 4, y: 4, width: 8, height: 8))
    }

    func testCenterAnchorNoMargin() throws {
        let rect = try XCTUnwrap(Geometry.watermarkRect(
            imageSize: CGSize(width: 1000, height: 500), contentSize: CGSize(width: 100, height: 100),
            options: options(.image(ImageWatermark(path: "a")), anchor: .center, size: 20, margin: 0)))
        XCTAssertEqual(rect, CGRect(x: 450, y: 200, width: 100, height: 100))
        let topLeft = Geometry.watermarkRect(
            imageSize: CGSize(width: 1000, height: 500), contentSize: CGSize(width: 100, height: 100),
            options: options(.image(ImageWatermark(path: "a")), anchor: .topLeft, size: 20, margin: 0))
        XCTAssertEqual(topLeft?.origin, .zero)
    }

    func testNaNAndOutOfRangeClamped() throws {
        let nan = options(.text(TextWatermark()), size: .nan, margin: .nan)
        XCTAssertEqual(nan.clampedSizePercent, 4)
        XCTAssertEqual(nan.clampedMarginPercent, 3)
        XCTAssertEqual(WatermarkOptions(opacity: .nan).clampedOpacity, 0.65)
        XCTAssertEqual(WatermarkOptions(sizePercent: 500, opacity: 7, marginPercent: 99).clampedSizePercent, 100)
        XCTAssertEqual(WatermarkOptions(opacity: 7).clampedOpacity, 1)
        XCTAssertEqual(WatermarkOptions(opacity: -1).clampedOpacity, 0)
        XCTAssertEqual(WatermarkOptions(marginPercent: 99).clampedMarginPercent, 25)
        XCTAssertEqual(WatermarkOptions(sizePercent: -5).clampedSizePercent, 0)

        let image = CGSize(width: 800, height: 600)
        let rect = Geometry.watermarkRect(imageSize: image, contentSize: CGSize(width: 100, height: 50),
                                          options: options(.text(TextWatermark()), size: .nan, margin: .nan))
        XCTAssertEqual(rect?.height ?? 0, 24, accuracy: 0.0001)
        let huge = try XCTUnwrap(Geometry.watermarkRect(
            imageSize: image, contentSize: CGSize(width: 100, height: 50),
            options: options(.text(TextWatermark()), size: 1e9, margin: 1e9)))
        XCTAssertTrue(CGRect(origin: .zero, size: image).contains(huge))
        XCTAssertNil(Geometry.watermarkRect(imageSize: image, contentSize: .zero, options: WatermarkOptions()))
        XCTAssertNil(Geometry.watermarkRect(imageSize: image, contentSize: CGSize(width: 10, height: 10),
                                            options: options(.text(TextWatermark()), size: 0)))
    }

    func testImageContentDefaultsToImageSize() throws {
        XCTAssertEqual(WatermarkOptions.defaultImageSizePercent, 20)
        let json = #"{"content":{"image":{"_0":{"path":"/a.png"}}}}"#
        let image = try JSONDecoder().decode(WatermarkOptions.self, from: Data(json.utf8))
        XCTAssertEqual(image.sizePercent, 20)
        let withSize = try JSONDecoder().decode(
            WatermarkOptions.self, from: Data(#"{"content":{"image":{"_0":{"path":"/a.png"}}},"sizePercent":7}"#.utf8))
        XCTAssertEqual(withSize.sizePercent, 7)
        let text = try JSONDecoder().decode(WatermarkOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(text.sizePercent, 4)
    }

    func testSummaryShowsNewlinesAsSpaces() {
        let options = WatermarkOptions(content: .text(TextWatermark(text: "a\nb\rc")))
        XCTAssertTrue(options.summary.hasPrefix("a b c · "), options.summary)
    }
}
