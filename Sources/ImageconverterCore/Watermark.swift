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

    /// Rotation limited to −180...180 degrees (NaN or infinite: 0).
    public var clampedRotation: Double { rotation.isFinite ? Self.clamp(rotation, -180...180, 0) : 0 }

    static func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
        guard !value.isNaN else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Where a watermark goes: the mark's own (unrotated) size, its rotation, and the centre of every copy.
public struct WatermarkPlacement: Equatable, Sendable {
    /// The mark before rotation.
    public var markSize: CGSize
    /// Degrees, clockwise positive.
    public var degrees: Double
    /// The rotated mark's bounding box size.
    public var boundingSize: CGSize
    /// Top-left origin; one for the single layout.
    public var centers: [CGPoint]

    /// The rotated mark's bounding box around `center`.
    public func boundingBox(at center: CGPoint) -> CGRect {
        CGRect(x: center.x - boundingSize.width / 2, y: center.y - boundingSize.height / 2,
               width: boundingSize.width, height: boundingSize.height)
    }
}

extension Geometry {
    /// Most marks a tiled layout draws; a tinier mark gets a wider step instead of more copies.
    static let maxTiles = 2_500

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
        var bounds = rotatedBounds(size, degrees: degrees)
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0,
              availableWidth > 0, availableHeight > 0 else { return nil }
        let factor = min(1, availableWidth / bounds.width, availableHeight / bounds.height)
        size = CGSize(width: size.width * factor, height: size.height * factor)
        bounds = CGSize(width: bounds.width * factor, height: bounds.height * factor)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }

        let centers: [CGPoint]
        switch options.layout {
        case .single:
            let inset = CGSize(width: availableWidth, height: availableHeight)
            let origin = options.anchor.origin(content: bounds, container: inset)
            centers = [CGPoint(x: origin.x + margin + bounds.width / 2, y: origin.y + margin + bounds.height / 2)]
        case .tiled(let spacing, let stagger):
            centers = tileCenters(imageSize: imageSize, bounds: bounds, spacing: spacing, stagger: stagger)
        }
        return WatermarkPlacement(markSize: size, degrees: degrees, boundingSize: bounds, centers: centers)
    }

    /// A grid of centres covering the image, one mark at the centre, rows shifted by half a step when staggered.
    private static func tileCenters(imageSize: CGSize, bounds: CGSize, spacing: Double, stagger: Bool) -> [CGPoint] {
        let gap = 1 + WatermarkOptions.clamp(spacing, 0...400, WatermarkLayout.defaultSpacing) / 100
        var stepX = bounds.width * gap
        var stepY = bounds.height * gap
        // Columns and rows needed on each side of the centre (one extra for the stagger shift).
        func count(_ extent: CGFloat, _ step: CGFloat, _ mark: CGFloat) -> Int {
            Int(((extent / 2 + mark / 2) / step).rounded(.up)) + 1
        }
        let estimate = Double(2 * count(imageSize.width, stepX, bounds.width) + 1)
            * Double(2 * count(imageSize.height, stepY, bounds.height) + 1)
        if estimate > Double(maxTiles) {
            let widen = (estimate / Double(maxTiles)).squareRoot()
            stepX *= widen
            stepY *= widen
        }
        let columns = count(imageSize.width, stepX, bounds.width)
        let rows = count(imageSize.height, stepY, bounds.height)
        let mid = CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
        var centers: [CGPoint] = []
        for row in -rows...rows {
            let shift = stagger && row % 2 != 0 ? stepX / 2 : 0
            for column in -columns...columns {
                let center = CGPoint(x: mid.x + CGFloat(column) * stepX + shift, y: mid.y + CGFloat(row) * stepY)
                // Only marks that touch the image.
                guard center.x + bounds.width / 2 > 0, center.x - bounds.width / 2 < imageSize.width,
                      center.y + bounds.height / 2 > 0, center.y - bounds.height / 2 < imageSize.height else { continue }
                centers.append(center)
            }
        }
        return centers
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
