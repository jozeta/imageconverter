import CoreGraphics
import Foundation

/// A text watermark.
public struct TextWatermark: Codable, Equatable, Sendable {
    public var text: String
    public var fontName: String
    public var color: RGBAColor
    /// Nil: no shadow (today's look).
    public var shadow: WatermarkShadow?
    /// Nil: no outline. Drawn under the fill.
    public var outline: WatermarkOutline?

    public init(text: String = "©", fontName: String = "Helvetica-Bold", color: RGBAColor = .white,
                shadow: WatermarkShadow? = nil, outline: WatermarkOutline? = nil) {
        self.text = text
        self.fontName = fontName
        self.color = color
        self.shadow = shadow
        self.outline = outline
    }

    /// `text` on one line: line breaks become spaces.
    static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private enum CodingKeys: String, CodingKey { case text, fontName, color, shadow, outline }

    /// Lenient: a missing field takes its default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? "©"
        fontName = try container.decodeIfPresent(String.self, forKey: .fontName) ?? "Helvetica-Bold"
        color = try container.decodeIfPresent(RGBAColor.self, forKey: .color) ?? .white
        shadow = try container.decodeIfPresent(WatermarkShadow.self, forKey: .shadow)
        outline = try container.decodeIfPresent(WatermarkOutline.self, forKey: .outline)
    }
}

/// An image watermark (any format ImageIO reads, or SVG), stored as a plain path for now.
public struct ImageWatermark: Codable, Equatable, Sendable {
    public var path: String
    /// Nil: no shadow.
    public var shadow: WatermarkShadow?

    public init(path: String = "", shadow: WatermarkShadow? = nil) {
        self.path = path
        self.shadow = shadow
    }

    private enum CodingKeys: String, CodingKey { case path, shadow }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        shadow = try container.decodeIfPresent(WatermarkShadow.self, forKey: .shadow)
    }
}

/// A drop shadow, down and to the right of the mark. Sizes are percent of the mark's height
/// (the line height for text).
public struct WatermarkShadow: Codable, Equatable, Sendable {
    public var color: RGBAColor
    /// Blur radius, 0...50 %.
    public var blur: Double
    /// Distance down and right, 0...50 %.
    public var offset: Double

    public init(color: RGBAColor = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.6), blur: Double = 10,
                offset: Double = 6) {
        self.color = color
        self.blur = blur
        self.offset = offset
    }

    public var clampedBlur: Double { WatermarkOptions.clamp(blur, 0...50, 10) }
    public var clampedOffset: Double { WatermarkOptions.clamp(offset, 0...50, 6) }
}

/// A stroke around text, drawn under the fill. Width is percent of the line height.
public struct WatermarkOutline: Codable, Equatable, Sendable {
    public var color: RGBAColor
    /// 0...20 %.
    public var width: Double

    public init(color: RGBAColor = .black, width: Double = 6) {
        self.color = color
        self.width = width
    }

    public var clampedWidth: Double { WatermarkOptions.clamp(width, 0...20, 6) }
}

/// One mark at the anchor, or the mark repeated over the whole image.
public enum WatermarkLayout: Codable, Equatable, Sendable {
    /// At the anchor, inside the margin.
    case single
    /// A grid centred on the image; anchor and margin are ignored. `spacing` is the gap between marks in
    /// percent of the (rotated) mark's size, 0...400; `stagger` shifts every other row by half a step.
    case tiled(spacing: Double = 100, stagger: Bool = true)

    public static let defaultSpacing = 100.0

    private enum CodingKeys: String, CodingKey { case single, tiled }
    private enum TiledKeys: String, CodingKey { case spacing, stagger }

    /// Lenient: a missing spacing or stagger takes its default; an unknown layout is `single`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.tiled) else {
            self = .single
            return
        }
        let tiled = try? container.nestedContainer(keyedBy: TiledKeys.self, forKey: .tiled)
        self = .tiled(spacing: (try? tiled?.decodeIfPresent(Double.self, forKey: .spacing)) ?? Self.defaultSpacing,
                      stagger: (try? tiled?.decodeIfPresent(Bool.self, forKey: .stagger)) ?? true)
    }

    /// The same shape Swift's synthesized coding used: `{"single":{}}` or `{"tiled":{"spacing":…,"stagger":…}}`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .single:
            _ = container.nestedContainer(keyedBy: TiledKeys.self, forKey: .single)
        case .tiled(let spacing, let stagger):
            var tiled = container.nestedContainer(keyedBy: TiledKeys.self, forKey: .tiled)
            try tiled.encode(spacing, forKey: .spacing)
            try tiled.encode(stagger, forKey: .stagger)
        }
    }
}

public enum WatermarkContent: Codable, Equatable, Sendable {
    case text(TextWatermark)
    case image(ImageWatermark)
}

public struct WatermarkOptions: Codable, Equatable, Sendable {
    public static let defaultSizePercent = 4.0
    public static let defaultImageSizePercent = 20.0
    public static let defaultOpacity = 0.65
    public static let defaultMarginPercent = 3.0

    public var content: WatermarkContent
    public var anchor: Anchor
    public var sizePercent: Double
    public var opacity: Double
    public var marginPercent: Double
    /// Degrees, clockwise positive (as the Rotate step), −180...180, about the mark's centre.
    public var rotation: Double
    public var layout: WatermarkLayout

    public init(content: WatermarkContent = .text(TextWatermark()), anchor: Anchor = .bottomRight,
                sizePercent: Double = WatermarkOptions.defaultSizePercent,
                opacity: Double = WatermarkOptions.defaultOpacity,
                marginPercent: Double = WatermarkOptions.defaultMarginPercent,
                rotation: Double = 0, layout: WatermarkLayout = .single) {
        self.content = content
        self.anchor = anchor
        self.sizePercent = sizePercent
        self.opacity = opacity
        self.marginPercent = marginPercent
        self.rotation = rotation
        self.layout = layout
    }

    private enum CodingKeys: String, CodingKey {
        case content, anchor, sizePercent, opacity, marginPercent, rotation, layout
    }

    /// Lenient: a missing field takes its default, so older saved pipelines keep loading.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decodeIfPresent(WatermarkContent.self, forKey: .content) ?? .text(TextWatermark())
        anchor = try container.decodeIfPresent(Anchor.self, forKey: .anchor) ?? .bottomRight
        let defaultSize: Double
        if case .image = content { defaultSize = Self.defaultImageSizePercent } else { defaultSize = Self.defaultSizePercent }
        sizePercent = try container.decodeIfPresent(Double.self, forKey: .sizePercent) ?? defaultSize
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? Self.defaultOpacity
        marginPercent = try container.decodeIfPresent(Double.self, forKey: .marginPercent)
            ?? Self.defaultMarginPercent
        rotation = try container.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        layout = try container.decodeIfPresent(WatermarkLayout.self, forKey: .layout) ?? .single
    }

    /// Size in percent of the shorter side, limited to 0...100 (NaN: the default).
    public var clampedSizePercent: Double { Self.clamp(sizePercent, 0...100, Self.defaultSizePercent) }
    /// Opacity limited to 0...1 (NaN: the default).
    public var clampedOpacity: Double { Self.clamp(opacity, 0...1, Self.defaultOpacity) }
    /// Margin in percent of the shorter side, limited to 0...25 (NaN: the default).
    public var clampedMarginPercent: Double { Self.clamp(marginPercent, 0...25, Self.defaultMarginPercent) }

    /// The outline width and the shadow's offset and blur, as fractions of the mark's height (0 when absent).
    var styleFractions: WatermarkStyleFractions {
        var outline = 0.0
        var shadow: WatermarkShadow?
        switch content {
        case .text(let text):
            outline = (text.outline?.clampedWidth ?? 0) / 100
            shadow = text.shadow
        case .image(let image):
            shadow = image.shadow
        }
        return WatermarkStyleFractions(outline: outline, offset: (shadow?.clampedOffset ?? 0) / 100,
                                       blur: (shadow?.clampedBlur ?? 0) / 100)
    }

    /// Rotation limited to −180...180 degrees (NaN or infinite: 0).
    public var clampedRotation: Double { rotation.isFinite ? Self.clamp(rotation, -180...180, 0) : 0 }

    static func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
        guard !value.isNaN else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// A mark's outline width and shadow offset and blur, as fractions of its height.
struct WatermarkStyleFractions {
    var outline: Double
    var offset: Double
    var blur: Double

    /// What a `mark`-sized mark rotated by `degrees` covers: the rotated box with its outline, plus how far the
    /// (unrotated, down-right) shadow reaches past it on the left/top and right/bottom.
    func measure(_ mark: CGSize, degrees: Double) -> WatermarkExtent {
        let outlineWidth = mark.height * CGFloat(outline)
        let bounds = Geometry.rotatedBounds(
            CGSize(width: mark.width + 2 * outlineWidth, height: mark.height + 2 * outlineWidth), degrees: degrees)
        return WatermarkExtent(bounds: bounds, leading: mark.height * CGFloat(max(0, blur - offset)),
                               trailing: mark.height * CGFloat(offset + blur))
    }
}

/// See `WatermarkStyleFractions.measure`.
struct WatermarkExtent {
    var bounds: CGSize
    var leading: CGFloat
    var trailing: CGFloat

    var size: CGSize {
        CGSize(width: bounds.width + leading + trailing, height: bounds.height + leading + trailing)
    }
}

/// Where a watermark goes: the mark's own (unrotated) size, its rotation, and the centre of every copy.
public struct WatermarkPlacement: Equatable, Sendable {
    /// The mark before rotation.
    public var markSize: CGSize
    /// Degrees, clockwise positive.
    public var degrees: Double
    /// The rotated mark's bounding box size, its outline included.
    public var boundingSize: CGSize
    /// Top-left origin; one for the single layout.
    public var centers: [CGPoint]
    /// How far the shadow reaches past the bounding box on the left and top (width, height) …
    public var shadowLeading: CGSize = .zero
    /// … and on the right and bottom. The shadow falls down-right whatever the rotation.
    public var shadowTrailing: CGSize = .zero

    /// The rotated mark's bounding box around `center`, its outline included.
    public func boundingBox(at center: CGPoint) -> CGRect {
        CGRect(x: center.x - boundingSize.width / 2, y: center.y - boundingSize.height / 2,
               width: boundingSize.width, height: boundingSize.height)
    }

    /// Everything the mark draws around `center`: outline and shadow included.
    public func extentBox(at center: CGPoint) -> CGRect {
        let box = boundingBox(at: center)
        return CGRect(x: box.minX - shadowLeading.width, y: box.minY - shadowLeading.height,
                      width: box.width + shadowLeading.width + shadowTrailing.width,
                      height: box.height + shadowLeading.height + shadowTrailing.height)
    }
}

extension Geometry {
    /// Most marks a tiled layout draws; a tinier mark gets a wider step instead of more copies.
    static let maxTiles = 2_500
    /// Smallest mark side drawn, in pixels.
    static let minMarkSide: CGFloat = 1

    /// The bounding box size of `size` rotated by `degrees`.
    public static func rotatedBounds(_ size: CGSize, degrees: Double) -> CGSize {
        let radians = degrees * .pi / 180
        let cosine = abs(cos(radians))
        let sine = abs(sin(radians))
        return CGSize(width: size.width * cosine + size.height * sine,
                      height: size.width * sine + size.height * cosine)
    }

    /// Where a watermark of `contentSize` (its natural size, used for the aspect ratio) goes on an
    /// `imageSize` image, top-left origin. The size is a percent of the shorter side (width for images, height
    /// for text); the rotated bounding box is what must fit inside the margins (single) or the image (tiled).
    /// Nil when there is nothing to draw or nothing fits.
    public static func watermarkPlacement(imageSize: CGSize, contentSize: CGSize,
                                          options: WatermarkOptions) -> WatermarkPlacement? {
        guard imageSize.width.isFinite, imageSize.height.isFinite, imageSize.width > 0, imageSize.height > 0,
              contentSize.width.isFinite, contentSize.height.isFinite,
              contentSize.width > 0, contentSize.height > 0 else { return nil }
        let shorter = min(imageSize.width, imageSize.height)
        let target = shorter * options.clampedSizePercent / 100
        let degrees = options.clampedRotation
        var margin = shorter * options.clampedMarginPercent / 100
        if case .tiled = options.layout { margin = 0 }

        var size: CGSize
        switch options.content {
        case .image:
            size = CGSize(width: target, height: target * contentSize.height / contentSize.width)
        case .text:
            size = CGSize(width: target * contentSize.width / contentSize.height, height: target)
        }
        let availableWidth = imageSize.width - 2 * margin
        let availableHeight = imageSize.height - 2 * margin
        // The extent scales linearly with the mark, so one factor fits it.
        let style = options.styleFractions
        var extent = style.measure(size, degrees: degrees).size
        guard size.width > 0, size.height > 0, extent.width > 0, extent.height > 0,
              availableWidth > 0, availableHeight > 0 else { return nil }
        let factor = min(1, availableWidth / extent.width, availableHeight / extent.height)
        size = CGSize(width: size.width * factor, height: size.height * factor)
        // A mark under a pixel draws nothing visible (and a crafted tiny size must not reach the tiling maths).
        guard size.width.isFinite, size.height.isFinite, min(size.width, size.height) >= minMarkSide else { return nil }
        let measured = style.measure(size, degrees: degrees)
        extent = measured.size
        let bounds = measured.bounds

        let centers: [CGPoint]
        switch options.layout {
        case .single:
            let inset = CGSize(width: availableWidth, height: availableHeight)
            let origin = options.anchor.origin(content: extent, container: inset)
            centers = [CGPoint(x: origin.x + margin + measured.leading + bounds.width / 2,
                               y: origin.y + margin + measured.leading + bounds.height / 2)]
        case .tiled(let spacing, let stagger):
            centers = tileCenters(imageSize: imageSize, extent: extent, spacing: spacing, stagger: stagger)
                .map { CGPoint(x: $0.x + (measured.leading - measured.trailing) / 2,
                               y: $0.y + (measured.leading - measured.trailing) / 2) }
        }
        return WatermarkPlacement(markSize: size, degrees: degrees, boundingSize: bounds, centers: centers,
                                  shadowLeading: CGSize(width: measured.leading, height: measured.leading),
                                  shadowTrailing: CGSize(width: measured.trailing, height: measured.trailing))
    }

    /// A grid of centres covering the image (for marks whose drawn extent is `extent`), one at the centre, rows
    /// shifted by half a step when staggered. Counted in `Double` and widened to `maxTiles` before any `Int`.
    private static func tileCenters(imageSize: CGSize, extent: CGSize, spacing: Double, stagger: Bool) -> [CGPoint] {
        let gap = 1 + WatermarkOptions.clamp(spacing, 0...400, WatermarkLayout.defaultSpacing) / 100
        var stepX = Double(extent.width) * gap
        var stepY = Double(extent.height) * gap
        // Steps needed on each side of the centre (one extra for the stagger shift).
        func count(_ side: CGFloat, _ step: Double, _ mark: CGFloat) -> Double {
            ((Double(side) / 2 + Double(mark) / 2) / step).rounded(.up) + 1
        }
        let estimate = (2 * count(imageSize.width, stepX, extent.width) + 1)
            * (2 * count(imageSize.height, stepY, extent.height) + 1)
        guard estimate.isFinite, stepX > 0, stepY > 0 else { return [] }
        if estimate > Double(maxTiles) {
            let widen = (estimate / Double(maxTiles)).squareRoot()
            stepX *= widen
            stepY *= widen
        }
        let columns = Int(min(count(imageSize.width, stepX, extent.width), Double(maxTiles)))
        let rows = Int(min(count(imageSize.height, stepY, extent.height), Double(maxTiles)))
        let mid = CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
        var centers: [CGPoint] = []
        for row in -rows...rows {
            let shift = stagger && row % 2 != 0 ? stepX / 2 : 0
            for column in -columns...columns {
                let center = CGPoint(x: Double(mid.x) + Double(column) * stepX + shift,
                                     y: Double(mid.y) + Double(row) * stepY)
                // Only marks that touch the image.
                guard center.x + extent.width / 2 > 0, center.x - extent.width / 2 < imageSize.width,
                      center.y + extent.height / 2 > 0, center.y - extent.height / 2 < imageSize.height else { continue }
                centers.append(center)
            }
        }
        return Array(centers.prefix(maxTiles))
    }

    /// The bounding box of a single-layout watermark (the mark itself when it isn't rotated).
    public static func watermarkRect(imageSize: CGSize, contentSize: CGSize, options: WatermarkOptions) -> CGRect? {
        var single = options
        single.layout = .single
        guard let placement = watermarkPlacement(imageSize: imageSize, contentSize: contentSize, options: single),
              let center = placement.centers.first else { return nil }
        return placement.boundingBox(at: center)
    }
}
