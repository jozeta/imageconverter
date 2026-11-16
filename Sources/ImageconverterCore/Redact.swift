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
    /// Pixelate's block size in pixels of the image as it arrives at the step; nil: Auto (a third of each box's
    /// shorter side, `Redaction.blockSize(for:)`). Saved as `blockSize` only when fixed.
    public var fixedBlockSize: Double?
    /// Blur's Gaussian radius in pixels of the image as it arrives at the step; nil: Auto
    /// (`Redaction.blurRadius(for:)`). Saved as `blurRadius` only when fixed.
    public var fixedBlurRadius: Double?

    public static let defaultPadding = 15.0
    public static let paddingRange: ClosedRange<Double> = 0...100
    public static let blockSizeRange: ClosedRange<Double> = 4...256
    public static let blurRadiusRange: ClosedRange<Double> = 2...200
    /// What a Fixed choice starts at in the editor.
    public static let defaultFixedBlockSize = 16.0
    public static let defaultFixedBlurRadius = 20.0

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

    /// The fixed block size within `blockSizeRange`; nil for Auto (also when it isn't a finite number).
    public var clampedBlockSize: Double? { Self.clamped(fixedBlockSize, to: Self.blockSizeRange) }
    /// The fixed blur radius within `blurRadiusRange`; nil for Auto.
    public var clampedBlurRadius: Double? { Self.clamped(fixedBlurRadius, to: Self.blurRadiusRange) }

    /// Pixelate's block size for `rect` (whole pixels of the step's input): Auto, or the fixed size raised to
    /// `Redaction.minimumFixedSize(for:)` so small blocks never leave text or a face readable.
    public func blockSize(for rect: CGRect) -> Double {
        clampedBlockSize.map { max($0, Redaction.minimumFixedSize(for: rect)) } ?? Redaction.blockSize(for: rect)
    }

    /// Blur's radius for `rect`: Auto, or the fixed radius raised to the same floor.
    public func blurRadius(for rect: CGRect) -> Double {
        clampedBlurRadius.map { max($0, Redaction.minimumFixedSize(for: rect)) } ?? Redaction.blurRadius(for: rect)
    }

    /// True when the chosen style's fixed size is below the floor for `rect`, so it is drawn larger.
    public func raisesFixedSize(for rect: CGRect) -> Bool {
        let fixed: Double?
        switch style {
        case .pixelate: fixed = clampedBlockSize
        case .blur: fixed = clampedBlurRadius
        case .fill: fixed = nil
        }
        guard let fixed else { return false }
        return fixed < Redaction.minimumFixedSize(for: rect)
    }

    /// "Block size raised to keep 2 areas unreadable"; nil when no box needed it.
    public func raisedNote(for rects: [CGRect]) -> String? {
        let count = rects.filter(raisesFixedSize(for:)).count
        guard count > 0 else { return nil }
        let what = style == .pixelate ? "Block size" : "Blur strength"
        return "\(what) raised to keep \(count) \(count == 1 ? "area" : "areas") unreadable"
    }

    private static func clamped(_ value: Double?, to range: ClosedRange<Double>) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case target, style, fillColor, padding
        case fixedBlockSize = "blockSize", fixedBlurRadius = "blurRadius"
    }

    /// Lenient: a missing or unknown value takes its default (a style saved before text defaulted to a fill: blur).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = (try? container.decodeIfPresent(RedactTarget.self, forKey: .target)) ?? .faces
        style = (try? container.decodeIfPresent(RedactStyle.self, forKey: .style)) ?? .blur
        fillColor = (try? container.decodeIfPresent(RGBAColor.self, forKey: .fillColor)) ?? .black
        padding = (try? container.decodeIfPresent(Double.self, forKey: .padding)) ?? Self.defaultPadding
        fixedBlockSize = (try? container.decodeIfPresent(Double.self, forKey: .fixedBlockSize)) ?? nil
        fixedBlurRadius = (try? container.decodeIfPresent(Double.self, forKey: .fixedBlurRadius)) ?? nil
    }

    /// "faces · blur", "faces · pixelate · blocks 16 px", "text · solid colour · padding 0 %".
    public var summary: String {
        var parts = [target.displayName.lowercased(), style.displayName.lowercased()]
        if style == .pixelate, let size = clampedBlockSize { parts.append("blocks \(Self.number(size)) px") }
        if style == .blur, let radius = clampedBlurRadius { parts.append("radius \(Self.number(radius)) px") }
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
    /// The task was cancelled while detecting (the item is cancelled, not "unchecked").
    public var cancelled = false

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

    /// The smallest fixed block size or blur radius for a box: 8 px, or a fifth of its shorter side when that is
    /// more (smaller blocks or radii left 40 px text readable to Vision).
    public static func minimumFixedSize(for rect: CGRect) -> Double {
        max(8, Double(min(rect.width, rect.height)) / 5)
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

    /// Runs the step's detections on `image` (the image as it arrives at the step): faces on one copy of at most
    /// `textMaxLongSide` pixels (small faces in big group photos need it), text on the image itself (the detector
    /// shrinks it and also reads it in full-resolution tiles, `TextTiles`). A throwing
    /// detection records the reason; the step then fails the image rather than write it unchecked.
    public static func detect(_ target: RedactTarget, in image: CGImage, detector: any VisionDetector)
        -> RedactDetections {
        var result = RedactDetections()
        var failures: [String] = []
        if target.includesFaces {
            // Only faces need the copy made here; the text detector makes its own.
            guard let input = VisionInput.prepared(image, maxSide: textMaxLongSide) else {
                return RedactDetections(failure: "the image couldn't be prepared")
            }
            do {
                result.faces = try detector.faceRects(in: input, maxSide: textMaxLongSide).compactMap(sanitized)
            } catch {
                failures.append(ImageAnalysis.reason(error))
            }
        }
        if target.includesText {
            do { result.text = try detector.textRects(in: image).compactMap(sanitized) } catch is CancellationError {
                result.cancelled = true
            } catch {
                failures.append(ImageAnalysis.reason(error))
            }
        }
        if !failures.isEmpty { result.failure = Array(Set(failures)).sorted().joined(separator: ", ") }
        return result
    }
}

/// Text boxes from two detectors together. Every box is redacted: recognised lines and text rectangles alike (a
/// rectangle can be larger than the line inside it, and stylised or handwritten text has only a rectangle). Overlaps
/// matter only for the report's count.
public enum TextBoxes {
    /// Every recognised line, then every text rectangle; nothing dropped.
    public static func combined(recognized: [CGRect], rectangles: [CGRect]) -> [CGRect] {
        recognized + rectangles
    }

    /// How many text areas `boxes` are for the report: a box overlapping one already counted by at least half of
    /// the smaller box's area is the same area.
    public static func distinctCount(_ boxes: [CGRect]) -> Int {
        var counted: [CGRect] = []
        for box in boxes where !counted.contains(where: { overlap(box, $0) >= 0.5 }) { counted.append(box) }
        return counted.count
    }

    /// Intersection over the smaller box's area (0 when they don't meet).
    static func overlap(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        let common = lhs.intersection(rhs)
        guard !common.isNull, !common.isEmpty else { return 0 }
        let smaller = min(lhs.width * lhs.height, rhs.width * rhs.height)
        return smaller > 0 ? Double(common.width * common.height / smaller) : 0
    }
}
