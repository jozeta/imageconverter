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

    func testOldWatermarkJSONDecodes() throws {
        // A step as saved before rotation, layout, shadow and outline existed.
        let json = #"{"content":{"text":{"_0":{"text":"© Me","fontName":"Helvetica-Bold","#
            + #""color":{"red":1,"green":1,"blue":1,"alpha":1}}}},"anchor":"topLeft","sizePercent":5,"#
            + #""opacity":0.5,"marginPercent":2}"#
        let old = try JSONDecoder().decode(WatermarkOptions.self, from: Data(json.utf8))
        XCTAssertEqual(old.rotation, 0)
        XCTAssertEqual(old.layout, .single)
        XCTAssertEqual(old.content, .text(TextWatermark(text: "© Me")))
        guard case .text(let text) = old.content else { return XCTFail("text expected") }
        XCTAssertNil(text.shadow)
        XCTAssertNil(text.outline)
        XCTAssertEqual(old.anchor, .topLeft)
        let image = try JSONDecoder().decode(
            WatermarkOptions.self, from: Data(#"{"content":{"image":{"_0":{"path":"/a.png"}}}}"#.utf8))
        XCTAssertEqual(image.content, .image(ImageWatermark(path: "/a.png", shadow: nil)))
    }

    func testNewFieldsRoundTrip() throws {
        let text = TextWatermark(text: "{filename}", shadow: WatermarkShadow(blur: 5, offset: 3),
                                 outline: WatermarkOutline(color: .black, width: 4))
        let options = WatermarkOptions(content: .text(text), rotation: -30, layout: .tiled(spacing: 50, stagger: false))
        let data = try JSONEncoder().encode(options)
        XCTAssertEqual(try JSONDecoder().decode(WatermarkOptions.self, from: data), options)
        let image = WatermarkOptions(content: .image(ImageWatermark(path: "/l.svg", shadow: WatermarkShadow())))
        XCTAssertEqual(try JSONDecoder().decode(WatermarkOptions.self, from: JSONEncoder().encode(image)), image)
    }

    func testNewFieldsClamped() {
        XCTAssertEqual(WatermarkOptions(rotation: 400).clampedRotation, 180)
        XCTAssertEqual(WatermarkOptions(rotation: -400).clampedRotation, -180)
        XCTAssertEqual(WatermarkOptions(rotation: .nan).clampedRotation, 0)
        XCTAssertEqual(WatermarkOptions(rotation: .infinity).clampedRotation, 0)
        XCTAssertEqual(WatermarkShadow(blur: 99, offset: -1).clampedBlur, 50)
        XCTAssertEqual(WatermarkShadow(blur: 99, offset: -1).clampedOffset, 0)
        XCTAssertEqual(WatermarkOutline(width: 50).clampedWidth, 20)
        XCTAssertEqual(WatermarkOutline(width: .nan).clampedWidth, 6)
    }

    func testRotationKeepsMarginForRotatedBox() throws {
        let image = CGSize(width: 1000, height: 800)
        for anchor in Anchor.allCases {
            for degrees in [0.0, 30, 45, 90, -60, 180] {
                let options = WatermarkOptions(content: .image(ImageWatermark(path: "a")), anchor: anchor,
                                               sizePercent: 60, opacity: 1, marginPercent: 5, rotation: degrees)
                let placement = try XCTUnwrap(Geometry.watermarkPlacement(
                    imageSize: image, contentSize: CGSize(width: 400, height: 100), options: options))
                let center = try XCTUnwrap(placement.centers.first)
                XCTAssertEqual(placement.centers.count, 1)
                // The rotated mark's real corners, not just the stored box, stay inside the margins.
                let radians = degrees * .pi / 180
                let half = CGSize(width: placement.markSize.width / 2, height: placement.markSize.height / 2)
                for (signX, signY) in [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)] {
                    let cornerX = center.x + signX * half.width * cos(radians) - signY * half.height * sin(radians)
                    let cornerY = center.y + signX * half.width * sin(radians) + signY * half.height * cos(radians)
                    XCTAssertGreaterThanOrEqual(cornerX, 40 - 0.001, "\(anchor) \(degrees)")
                    XCTAssertLessThanOrEqual(cornerX, 960 + 0.001, "\(anchor) \(degrees)")
                    XCTAssertGreaterThanOrEqual(cornerY, 40 - 0.001, "\(anchor) \(degrees)")
                    XCTAssertLessThanOrEqual(cornerY, 760 + 0.001, "\(anchor) \(degrees)")
                }
                let box = placement.boundingBox(at: center)
                if anchor == .bottomRight {
                    XCTAssertEqual(box.maxX, 960, accuracy: 0.001)
                    XCTAssertEqual(box.maxY, 760, accuracy: 0.001)
                }
            }
        }
        // 45°: the 480 x 120 mark's box is 424 px square, which fits, so the mark isn't shrunk.
        let rotated = try XCTUnwrap(Geometry.watermarkPlacement(
            imageSize: image, contentSize: CGSize(width: 400, height: 100),
            options: WatermarkOptions(content: .image(ImageWatermark(path: "a")), sizePercent: 60,
                                      marginPercent: 5, rotation: 45)))
        XCTAssertEqual(rotated.markSize.width, 480, accuracy: 0.001)
        XCTAssertEqual(rotated.boundingSize.width, 600 / 2.0.squareRoot(), accuracy: 0.001)
    }

    func testTiledGridIsCentredAndBounded() throws {
        let image = CGSize(width: 400, height: 300)
        let options = WatermarkOptions(content: .image(ImageWatermark(path: "a")), anchor: .topLeft,
                                       sizePercent: 10, opacity: 1, marginPercent: 20,
                                       layout: .tiled(spacing: 100, stagger: false))
        let placement = try XCTUnwrap(Geometry.watermarkPlacement(
            imageSize: image, contentSize: CGSize(width: 10, height: 10), options: options))
        XCTAssertTrue(placement.centers.contains(CGPoint(x: 200, y: 150)))
        XCTAssertTrue(placement.centers.contains(CGPoint(x: 260, y: 150)))
        XCTAssertTrue(placement.centers.allSatisfy { placement.boundingBox(at: $0).intersects(CGRect(origin: .zero, size: image)) })
        let tiny = WatermarkOptions(content: .image(ImageWatermark(path: "a")), sizePercent: 0.01,
                                    layout: .tiled(spacing: 0, stagger: true))
        let many = try XCTUnwrap(Geometry.watermarkPlacement(
            imageSize: CGSize(width: 20000, height: 20000), contentSize: CGSize(width: 10, height: 10), options: tiny))
        XCTAssertLessThanOrEqual(many.centers.count, Geometry.maxTiles)
    }

    func testStyleExtentsCountInPlacement() throws {
        let text = TextWatermark(text: "A", shadow: WatermarkShadow(blur: 10, offset: 20),
                                 outline: WatermarkOutline(width: 10))
        let options = WatermarkOptions(content: .text(text), anchor: .bottomRight, sizePercent: 10, opacity: 1,
                                       marginPercent: 5)
        let placement = try XCTUnwrap(Geometry.watermarkPlacement(
            imageSize: CGSize(width: 1000, height: 800), contentSize: CGSize(width: 50, height: 50), options: options))
        let center = try XCTUnwrap(placement.centers.first)
        let extent = placement.extentBox(at: center)
        XCTAssertEqual(extent.maxX, 960, accuracy: 0.001)
        XCTAssertEqual(extent.maxY, 760, accuracy: 0.001)
        // 80 px mark: outline 8 px around it, shadow reaching 24 px (offset 16 + blur 8) past it down-right.
        XCTAssertEqual(placement.boundingSize.height, 96, accuracy: 0.001)
        XCTAssertEqual(placement.shadowTrailing.height, 24, accuracy: 0.001)
        XCTAssertEqual(placement.shadowLeading.height, 0, accuracy: 0.001)
    }

    func testLayoutDecodesLeniently() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(WatermarkLayout.self, from: Data(#"{"tiled":{"spacing":50}}"#.utf8)),
                       .tiled(spacing: 50, stagger: true))
        XCTAssertEqual(try decoder.decode(WatermarkLayout.self, from: Data(#"{"tiled":{}}"#.utf8)),
                       .tiled(spacing: 100, stagger: true))
        XCTAssertEqual(try decoder.decode(WatermarkLayout.self, from: Data(#"{"spiral":{}}"#.utf8)), .single)
        XCTAssertEqual(try decoder.decode(WatermarkLayout.self, from: Data(#"{"single":{}}"#.utf8)), .single)
        for layout in [WatermarkLayout.single, .tiled(spacing: 30, stagger: false)] {
            let data = try JSONEncoder().encode(layout)
            XCTAssertEqual(try decoder.decode(WatermarkLayout.self, from: data), layout)
        }
        XCTAssertEqual(String(data: try JSONEncoder().encode(WatermarkLayout.single), encoding: .utf8), #"{"single":{}}"#)
    }
}
