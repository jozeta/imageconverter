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

    public init(target: RedactTarget = .faces, style: RedactStyle = .blur, fillColor: RGBAColor = .black,
                padding: Double = RedactOptions.defaultPadding) {
        self.target = target
        self.style = style
        self.fillColor = fillColor
        self.padding = padding
    }

    /// `padding` limited to 0...100 (NaN → the default).
    public var clampedPadding: Double {
        padding.isFinite ? min(max(padding, Self.paddingRange.lowerBound), Self.paddingRange.upperBound)
            : Self.defaultPadding
    }

    private enum CodingKeys: String, CodingKey {
        case target, style, fillColor, padding
    }

    /// Lenient: a missing or unknown value takes its default.
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

    /// The report note for one image: "Redacted 2 faces, 1 text area", "Redact: nothing found", or, when Vision
    /// couldn't run, "Image analysis unavailable: <reason>; nothing was redacted" (an unredacted image may leak,
    /// so the report shows that note as a warning).
    public static func note(faces: Int, text: Int, failure: String?) -> String {
        var found: [String] = []
        if faces > 0 { found.append("\(faces) \(faces == 1 ? "face" : "faces")") }
        if text > 0 { found.append("\(text) text \(text == 1 ? "area" : "areas")") }
        let list = found.joined(separator: ", ")
        if let failure {
            let unavailable = ImageAnalysis.unavailableNote(failure)
            return found.isEmpty ? unavailable + "; nothing was redacted" : unavailable + "; only redacted " + list
        }
        return found.isEmpty ? nothingFoundNote : "Redacted " + list
    }

    /// Runs the step's detections on `image` (the image as it arrives at the step). One copy of at most
    /// `textMaxLongSide` pixels serves both: text is read from it, faces from the detector's own smaller copy.
    /// A throwing detection keeps what the other one found and records the reason (never fails a run).
    public static func detect(_ target: RedactTarget, in image: CGImage, detector: any VisionDetector)
        -> RedactDetections {
        guard let input = VisionInput.prepared(image, maxSide: textMaxLongSide) else {
            return RedactDetections(failure: "the image couldn't be prepared")
        }
        var result = RedactDetections()
        var failures: [String] = []
        if target.includesFaces {
            do { result.faces = try detector.faceRects(in: input).compactMap(sanitized) } catch {
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

extension ReportEntry {
    /// A written file whose note needs attention: image analysis couldn't run (a Redact step may have left
    /// faces or text visible, a condition may have taken the other branch), or the original couldn't be trashed.
    public var isWarning: Bool {
        guard status == .succeeded, let note else { return false }
        return note.contains(ImageAnalysis.unavailableNote("").trimmingCharacters(in: .whitespaces))
            || note.hasPrefix(FileCommitter.trashFailurePrefix)
    }
}
