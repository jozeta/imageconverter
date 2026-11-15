import CoreGraphics
import Foundation

/// What a Redact step hides.
public enum RedactTarget: String, Codable, CaseIterable, Sendable {
    case faces, text, both

    public var displayName: String {
        switch self {
        case .faces: return "Faces"
        case .text: return "Text"
        case .both: return "Faces and text"
        }
    }

    public var includesFaces: Bool { self != .text }
    public var includesText: Bool { self != .faces }

    /// The target that hides both `self` and `other`.
    public func adding(_ other: RedactTarget) -> RedactTarget {
        let faces = includesFaces || other.includesFaces
        let text = includesText || other.includesText
        return faces && text ? .both : (faces ? .faces : .text)
    }
}

/// How a Redact step hides what it found.
public enum RedactStyle: String, Codable, CaseIterable, Sendable {
    case blur, pixelate, fill

    public var displayName: String {
        switch self {
        case .blur: return "Blur"
        case .pixelate: return "Pixelate"
        case .fill: return "Solid colour"
        }
    }
}

public struct RedactOptions: Codable, Equatable, Sendable {
    public var target: RedactTarget
    public var style: RedactStyle
    /// The colour of a solid fill, always drawn fully opaque.
    public var fillColor: RGBAColor
    /// How far each box grows on every side, as a percentage of its own width (left, right) and height (top,
    /// bottom), 0...100.
    public var padding: Double

    public static let defaultPadding = 15.0
    public static let paddingRange: ClosedRange<Double> = 0...100

    /// `style` nil: the default for `target` (`defaultStyle(for:)`).
    public init(target: RedactTarget = .faces, style: RedactStyle? = nil, fillColor: RGBAColor = .black,
                padding: Double = RedactOptions.defaultPadding) {
        self.target = target
        self.style = style ?? Self.defaultStyle(for: target)
        self.fillColor = fillColor
        self.padding = padding
    }

    /// Blur for faces; a solid colour as soon as text is included, since blurred or pixelated text can sometimes be
    /// reconstructed by rendering guesses in the same font and comparing.
    public static func defaultStyle(for target: RedactTarget) -> RedactStyle {
        target.includesText ? .fill : .blur
    }

    /// These options for `target`; the style follows the new target's default unless another style was chosen.
    public func retargeted(_ target: RedactTarget) -> RedactOptions {
        var options = self
        options.target = target
        if style == Self.defaultStyle(for: self.target) { options.style = Self.defaultStyle(for: target) }
        return options
    }

    /// `padding` limited to 0...100 (NaN → the default).
    public var clampedPadding: Double {
        padding.isFinite ? min(max(padding, Self.paddingRange.lowerBound), Self.paddingRange.upperBound)
            : Self.defaultPadding
    }

    private enum CodingKeys: String, CodingKey {
        case target, style, fillColor, padding
    }

    /// Lenient: a missing or unknown value takes its default (a style saved before text defaulted to a fill: blur).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = (try? container.decodeIfPresent(RedactTarget.self, forKey: .target)) ?? .faces
        style = (try? container.decodeIfPresent(RedactStyle.self, forKey: .style)) ?? .blur
        fillColor = (try? container.decodeIfPresent(RGBAColor.self, forKey: .fillColor)) ?? .black
        padding = (try? container.decodeIfPresent(Double.self, forKey: .padding)) ?? Self.defaultPadding
    }

    /// "faces · blur", "text · solid colour · padding 0 %".
    public var summary: String {
        var parts = [target.displayName.lowercased(), style.displayName.lowercased()]
        if clampedPadding != Self.defaultPadding { parts.append("padding \(Self.number(clampedPadding)) %") }
        return parts.joined(separator: " · ")
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// What Vision found for one Redact step, in normalised boxes (0...1, top-left origin) of the step's input.
public struct RedactDetections: Equatable, Sendable {
    public var faces: [CGRect]
    public var text: [CGRect]
    /// Why (part of) the detection couldn't run; nil when it ran.
    public var failure: String?

    public init(faces: [CGRect] = [], text: [CGRect] = [], failure: String? = nil) {
        self.faces = faces
        self.text = text
        self.failure = failure
    }
}

/// The geometry and wording of the Redact step, without Vision.
public enum Redaction {
    /// Text needs more resolution than faces: the copy Vision reads text from is at most this long.
    public static let textMaxLongSide = 2048
    public static let nothingFoundNote = "Redact: nothing found"
    /// The note on an image a condition would have copied unchanged: it is converted with the Redact step instead.
    public static let convertedToRedactNote = "Converted to redact: a copy of the original would not be redacted"
    /// The note when face or person regions were taken out of the output's metadata.
    public static let faceRegionsRemovedNote = "Removed face regions from metadata"
    /// Shown in the editor, the hover help and the README.
    public static let textAdvice = "For text, use Solid colour: blur and pixelation can sometimes be reversed."

    /// Normalised boxes as whole-pixel rects of an image of `size` (top-left origin), each grown by `padding`
    /// percent of its own width and height on every side, then clamped to the image. Boxes are untrusted:
    /// non-finite or empty ones are dropped, the rest clamped to the unit square first.
    public static func pixelRects(_ boxes: [CGRect], padding: Double, in size: CGSize) -> [CGRect] {
        let width = Double(size.width)
        let height = Double(size.height)
        guard width >= 1, height >= 1 else { return [] }
        let pad = (padding.isFinite ? min(max(padding, 0), 100) : RedactOptions.defaultPadding) / 100
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        return boxes.compactMap { box -> CGRect? in
            let unit = sanitized(box)
            guard let unit else { return nil }
            let boxWidth = Double(unit.width) * width
            let boxHeight = Double(unit.height) * height
            let rect = CGRect(x: Double(unit.minX) * width, y: Double(unit.minY) * height,
                              width: boxWidth, height: boxHeight)
                .insetBy(dx: -boxWidth * pad, dy: -boxHeight * pad)
            let minX = floor(max(Double(rect.minX), 0))
            let minY = floor(max(Double(rect.minY), 0))
            let maxX = ceil(min(Double(rect.maxX), width))
            let maxY = ceil(min(Double(rect.maxY), height))
            guard maxX > minX, maxY > minY else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).intersection(bounds)
        }
    }

    /// A box clamped to the unit square; nil when it isn't finite or is empty.
    static func sanitized(_ box: CGRect) -> CGRect? {
        let values = [box.origin.x, box.origin.y, box.size.width, box.size.height]
        guard values.allSatisfy(\.isFinite) else { return nil }
        let clamped = box.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return nil }
        return clamped
    }

    /// The Gaussian blur radius for a box: a third of its shorter side (at least 6 px), so a small face and a
    /// large one, or a line of text, are both blurred beyond recognition.
    public static func blurRadius(for rect: CGRect) -> Double {
        max(6, Double(min(rect.width, rect.height)) / 3)
    }

    /// The pixel block size for a box: a third of its shorter side (at least 6 px), so about three blocks span
    /// it: a face or a line of text keeps no readable detail.
    public static func blockSize(for rect: CGRect) -> Double {
        max(6, (Double(min(rect.width, rect.height)) / 3).rounded(.up))
    }

    /// The report note for one image: "Redacted 2 faces, 1 text area" or "Redact: nothing found". (When Vision
    /// can't run the image fails instead: `ConversionError.redactUnchecked`.)
    public static func note(faces: Int, text: Int) -> String {
        var found: [String] = []
        if faces > 0 { found.append("\(faces) \(faces == 1 ? "face" : "faces")") }
        if text > 0 { found.append("\(text) text \(text == 1 ? "area" : "areas")") }
        return found.isEmpty ? nothingFoundNote : "Redacted " + found.joined(separator: ", ")
    }

    /// Runs the step's detections on `image` (the image as it arrives at the step) on one copy of at most
    /// `textMaxLongSide` pixels, for faces and text alike (small faces in big group photos need it too). A throwing
    /// detection records the reason; the step then fails the image rather than write it unchecked.
    public static func detect(_ target: RedactTarget, in image: CGImage, detector: any VisionDetector)
        -> RedactDetections {
        guard let input = VisionInput.prepared(image, maxSide: textMaxLongSide) else {
            return RedactDetections(failure: "the image couldn't be prepared")
        }
        var result = RedactDetections()
        var failures: [String] = []
        if target.includesFaces {
            do {
                result.faces = try detector.faceRects(in: input, maxSide: textMaxLongSide).compactMap(sanitized)
            } catch {
                failures.append(ImageAnalysis.reason(error))
            }
        }
        if target.includesText {
            do { result.text = try detector.textRects(in: input).compactMap(sanitized) } catch {
                failures.append(ImageAnalysis.reason(error))
            }
        }
        if !failures.isEmpty { result.failure = Array(Set(failures)).sorted().joined(separator: ", ") }
        return result
    }
}

/// Text boxes from two detectors together: every recognised line, plus each text rectangle that isn't mostly the
/// same area as one of them (stylised or handwritten text that recognition drops).
public enum TextBoxes {
    public static func merged(recognized: [CGRect], rectangles: [CGRect]) -> [CGRect] {
        recognized + rectangles.filter { box in
            !recognized.contains { overlap(box, $0) >= 0.5 }
        }
    }

    /// Intersection over the smaller box's area (0 when they don't meet).
    static func overlap(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        let common = lhs.intersection(rhs)
        guard !common.isNull, !common.isEmpty else { return 0 }
        let smaller = min(lhs.width * lhs.height, rhs.width * rhs.height)
        return smaller > 0 ? Double(common.width * common.height / smaller) : 0
    }
}
