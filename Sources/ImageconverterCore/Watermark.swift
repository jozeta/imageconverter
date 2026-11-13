import CoreGraphics
import Foundation

/// A text watermark.
public struct TextWatermark: Codable, Equatable, Sendable {
    public var text: String
    public var fontName: String
    public var color: RGBAColor

    public init(text: String = "©", fontName: String = "Helvetica-Bold", color: RGBAColor = .white) {
        self.text = text
        self.fontName = fontName
        self.color = color
    }

    /// `text` on one line: line breaks become spaces.
    static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private enum CodingKeys: String, CodingKey { case text, fontName, color }

    /// Lenient: a missing field takes its default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? "©"
        fontName = try container.decodeIfPresent(String.self, forKey: .fontName) ?? "Helvetica-Bold"
        color = try container.decodeIfPresent(RGBAColor.self, forKey: .color) ?? .white
    }
}

/// An image watermark, stored as a plain path for now.
public struct ImageWatermark: Codable, Equatable, Sendable {
    public var path: String

    public init(path: String = "") { self.path = path }

    private enum CodingKeys: String, CodingKey { case path }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
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

    public init(content: WatermarkContent = .text(TextWatermark()), anchor: Anchor = .bottomRight,
                sizePercent: Double = WatermarkOptions.defaultSizePercent,
                opacity: Double = WatermarkOptions.defaultOpacity,
                marginPercent: Double = WatermarkOptions.defaultMarginPercent) {
        self.content = content
        self.anchor = anchor
        self.sizePercent = sizePercent
        self.opacity = opacity
        self.marginPercent = marginPercent
    }

    private enum CodingKeys: String, CodingKey { case content, anchor, sizePercent, opacity, marginPercent }

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
    }

    /// Size in percent of the shorter side, limited to 0...100 (NaN: the default).
    public var clampedSizePercent: Double { Self.clamp(sizePercent, 0...100, Self.defaultSizePercent) }
    /// Opacity limited to 0...1 (NaN: the default).
    public var clampedOpacity: Double { Self.clamp(opacity, 0...1, Self.defaultOpacity) }
    /// Margin in percent of the shorter side, limited to 0...25 (NaN: the default).
    public var clampedMarginPercent: Double { Self.clamp(marginPercent, 0...25, Self.defaultMarginPercent) }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
        guard !value.isNaN else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

extension Geometry {
    /// Where a watermark of `contentSize` (its natural size, used for the aspect ratio) goes on an
    /// `imageSize` image, top-left origin. Nil when there is nothing to draw or nothing fits.
    public static func watermarkRect(imageSize: CGSize, contentSize: CGSize, options: WatermarkOptions) -> CGRect? {
        guard imageSize.width.isFinite, imageSize.height.isFinite, imageSize.width > 0, imageSize.height > 0,
              contentSize.width.isFinite, contentSize.height.isFinite,
              contentSize.width > 0, contentSize.height > 0 else { return nil }
        let shorter = min(imageSize.width, imageSize.height)
        let target = shorter * options.clampedSizePercent / 100
        let margin = shorter * options.clampedMarginPercent / 100

        var size: CGSize
        switch options.content {
        case .image:
            size = CGSize(width: target, height: target * contentSize.height / contentSize.width)
        case .text:
            size = CGSize(width: target * contentSize.width / contentSize.height, height: target)
        }
        let availableWidth = imageSize.width - 2 * margin
        let availableHeight = imageSize.height - 2 * margin
        guard size.width > 0, size.height > 0, availableWidth > 0, availableHeight > 0 else { return nil }
        let factor = min(1, availableWidth / size.width, availableHeight / size.height)
        size = CGSize(width: size.width * factor, height: size.height * factor)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }

        let inset = CGSize(width: imageSize.width - 2 * margin, height: imageSize.height - 2 * margin)
        let origin = options.anchor.origin(content: size, container: inset)
        return CGRect(x: origin.x + margin, y: origin.y + margin, width: size.width, height: size.height)
    }
}
