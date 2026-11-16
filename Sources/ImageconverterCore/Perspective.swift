import CoreGraphics
import CoreImage
import Foundation
import Vision

/// The size of the corrected image.
public enum PerspectiveSize: String, Codable, CaseIterable, Sendable {
    /// As large as the corrected image (or its inner rectangle when cropping).
    case fit
    /// Exactly the source's pixel size: the corrected image is scaled to fit inside (aspect kept, centred), or with
    /// "Crop to the image" scaled to fill and cropped from the centre.
    case keepOriginal

    public var displayName: String {
        switch self {
        case .fit: return "Fit the corrected image"
        case .keepOriginal: return "Keep original size"
        }
    }
}

/// What fills the areas the correction leaves empty.
public enum PerspectiveEmptyAreas: String, Codable, CaseIterable, Sendable {
    /// Keep the largest rectangle with no empty areas.
    case crop
    /// `PerspectiveOptions.fillColor`.
    case color
    /// Alpha; outputs without alpha get `fillColor` with a note.
    case transparent
    /// The image's edge pixels repeated outwards.
    case extend

    public var displayName: String {
        switch self {
        case .crop: return "Crop to the image"
        case .color: return "Fill with colour"
        case .transparent: return "Transparent"
        case .extend: return "Extend edges"
        }
    }
}

/// Which rectangle "Crop to the image" keeps.
public enum PerspectiveCropRule: String, Codable, CaseIterable, Sendable {
    /// Before the empty-area choices: each side at the inner end of its edge. Kept for steps saved then, so they
    /// write exactly what they did (only both sliders together differ from `largest`).
    case innerEnds
    /// The largest axis-aligned rectangle inside the corrected image.
    case largest
}

/// Perspective correction: optional automatic document straightening, then a manual keystone.
public struct PerspectiveOptions: Codable, Equatable, Sendable {
    /// −100...100. +100 pulls the top edge in by 25 % of the width on each side, −100 the bottom edge.
    public var vertical: Double
    /// −100...100. +100 pulls the right edge in by 25 % of the height on each side, −100 the left edge.
    public var horizontal: Double
    /// Detect a rectangle (a document, a screen) and straighten it before the manual keystone.
    public var auto: Bool
    public var size: PerspectiveSize
    public var emptyAreas: PerspectiveEmptyAreas
    /// For `.color`, and for `.transparent` when the output has no alpha.
    public var fillColor: RGBAColor
    /// `.innerEnds` for steps saved before the empty-area choices (no `emptyAreas` key) until the user edits them.
    public var cropRule: PerspectiveCropRule

    public static let range: ClosedRange<Double> = -100...100

    public init(vertical: Double = 0, horizontal: Double = 0, auto: Bool = false, size: PerspectiveSize = .fit,
                emptyAreas: PerspectiveEmptyAreas = .crop, fillColor: RGBAColor = .white,
                cropRule: PerspectiveCropRule = .largest) {
        self.vertical = vertical
        self.horizontal = horizontal
        self.auto = auto
        self.size = size
        self.emptyAreas = emptyAreas
        self.fillColor = fillColor
        self.cropRule = cropRule
    }

    /// Takes `edited` as the user's change in the editor: a step that really changed uses the largest crop from now
    /// on (a saved step left alone keeps its rule).
    public mutating func applyUserEdit(_ edited: PerspectiveOptions) {
        guard edited != self else { return }
        self = edited
        cropRule = .largest
    }

    private enum CodingKeys: String, CodingKey {
        case vertical, horizontal, auto, size, emptyAreas, fillColor, cropRule
    }

    /// Lenient: missing or unreadable keys are "no change" (fit, crop, white), out-of-range values are clamped.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let size = (try? container.decodeIfPresent(String.self, forKey: .size)).flatMap { PerspectiveSize(rawValue: $0) }
        let empty = (try? container.decodeIfPresent(String.self, forKey: .emptyAreas))
            .flatMap { PerspectiveEmptyAreas(rawValue: $0) }
        let saved = (try? container.decodeIfPresent(String.self, forKey: .cropRule))
            .flatMap { PerspectiveCropRule(rawValue: $0) }
        // Saved before the empty-area choices existed: keep the crop those versions made.
        let rule = saved ?? (container.contains(.emptyAreas) ? .largest : .innerEnds)
        self.init(vertical: Self.clamped(try container.decodeIfPresent(Double.self, forKey: .vertical) ?? 0),
                  horizontal: Self.clamped(try container.decodeIfPresent(Double.self, forKey: .horizontal) ?? 0),
                  auto: try container.decodeIfPresent(Bool.self, forKey: .auto) ?? false,
                  size: size ?? .fit, emptyAreas: empty ?? .crop,
                  fillColor: (try? container.decodeIfPresent(RGBAColor.self, forKey: .fillColor)) ?? .white,
                  cropRule: rule)
    }

    /// The value limited to −100...100; non-finite values become 0.
    public static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : 0
    }
}

/// Renders `PerspectiveOptions` with Core Image (and Vision for the automatic correction).
public enum Perspective {
    /// The note added when auto correction finds nothing to straighten.
    public static let noEdgesNote = "No document edges found"

    /// The note when transparent empty areas go to a format without alpha.
    static func noTransparencyNote(_ format: OutputFormat, color: RGBAColor) -> String {
        "No transparency in \(format.displayName); filled with \(ImageOperation.hex(color))"
    }

    public static func apply(_ options: PerspectiveOptions, to image: CGImage) throws -> CGImage {
        var notes: [String] = []
        return try apply(options, to: image, notes: &notes)
    }

    /// As `apply(_:to:)`, adding `noEdgesNote` to `notes` when auto correction found no rectangle. Transparent
    /// empty areas always keep alpha here; each output without alpha is flattened onto the fill colour when it is
    /// encoded (`Pipeline.matted`).
    public static func apply(_ options: PerspectiveOptions, to image: CGImage, notes: inout [String]) throws -> CGImage {
        try apply(options, to: image, notes: &notes, detect: detectRectangle)
    }

    /// The whole step with the rectangle detection passed in (tests use a fixed rectangle).
    static func apply(_ options: PerspectiveOptions, to image: CGImage, notes: inout [String],
                      detect: (CGImage) throws -> Quad?) throws -> CGImage {
        var current = image
        if options.auto {
            // A Vision error is treated like "nothing found": the image is left as it is.
            if let quad = try? detect(current) {
                current = try correct(current, to: quad)
            } else {
                notes.append(noEdgesNote)
            }
        }
        let size = CGSize(width: current.width, height: current.height)
        let original = CGSize(width: image.width, height: image.height)
        let quad = Geometry.keystoneQuad(source: size, options: options)
        let box = Geometry.keystoneBox(source: size, options: options) ?? CGRect(origin: .zero, size: size)
        let target = options.size == .keepOriginal && original != box.size ? original : nil
        guard quad != nil || target != nil else { return current }

        var layer = CIImage(cgImage: current)
        // Core Image is y-up.
        var rect = CGRect(x: box.minX, y: size.height - box.maxY, width: box.width, height: box.height)
        if let quad { layer = keystoned(current, quad, options, in: rect) }
        if let target { (layer, rect) = sized(layer, rect, to: target, options) }
        let empty = options.emptyAreas
        let alpha = ImageOps.hasAlpha(current) || empty == .transparent
            || (empty == .color && options.fillColor.alpha < 1)
        return try Adjustments.render(layer, from: rect, like: current, step: StepKind.perspective.displayName,
                                      alpha: alpha)
    }

    /// A slider value as applied: clamped, and 0 below 0.01 (no visible change).
    static func effective(_ value: Double) -> Double {
        let clean = PerspectiveOptions.clamped(value)
        return abs(clean) < 0.01 ? 0 : clean
    }

    /// True when the options change nothing (no auto, sliders effectively at 0). Keep original size alone changes
    /// nothing either: without a correction the size is already the original.
    public static func isNoOp(_ options: PerspectiveOptions) -> Bool {
        !options.auto && effective(options.vertical) == 0 && effective(options.horizontal) == 0
    }

    /// The most confident rectangle in `image` (top-left origin pixels), or nil when there is none.
    /// Throws when Vision can't run.
    static func detectRectangle(in image: CGImage) throws -> Quad? {
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.8
        request.minimumSize = 0.3
        request.maximumObservations = 1
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let found = request.results?.first else { return nil }
        // Vision's points are normalised with a bottom-left origin.
        let wide = CGFloat(image.width)
        let high = CGFloat(image.height)
        let point: (CGPoint) -> CGPoint = { CGPoint(x: $0.x * wide, y: (1 - $0.y) * high) }
        return Quad(topLeft: point(found.topLeft), topRight: point(found.topRight),
                    bottomRight: point(found.bottomRight), bottomLeft: point(found.bottomLeft))
    }

    /// Straightens the `quad` part of `image` into a rectangle (no empty areas).
    private static func correct(_ image: CGImage, to quad: Quad) throws -> CGImage {
        let step = StepKind.perspective.displayName
        let high = CGFloat(image.height)
        let output = CIImage(cgImage: image).applyingFilter("CIPerspectiveCorrection",
                                                            parameters: vectors(quad, height: high))
        let extent = output.extent.integral
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return image }
        return try Adjustments.render(output, from: extent, like: image, step: step)
    }

    /// The image corners mapped onto the keystone quad, kept to `rect` (Core Image coordinates): outside the
    /// quad transparent, the fill colour, or (extend) the edge pixels repeated outwards.
    private static func keystoned(_ image: CGImage, _ quad: Quad, _ options: PerspectiveOptions,
                                  in rect: CGRect) -> CIImage {
        let (empty, fill) = (options.emptyAreas, options.fillColor)
        let source = CIImage(cgImage: image)
        var parameters = vectors(quad, height: CGFloat(image.height))
        var warped: CIImage
        if empty == .extend {
            // The edge pixels repeated outwards, as far as the kept box reaches back into the source (finite:
            // Core Image can't warp an infinite image). The filter maps `inputExtent`, the image itself, onto the quad.
            let extent = source.extent
            parameters["inputExtent"] = CIVector(cgRect: extent)
            let (area, covered) = extendedSource(quad, box: rect, size: extent.size)
            warped = source.clampedToExtent().cropped(to: area)
                .applyingFilter("CIPerspectiveTransformWithExtent", parameters: parameters)
            // Past the horizon (extreme combined sliders) no source pixel lands: the corrected image's inner
            // rectangle, its edges repeated, fills what is left. Only then: it is a second warp.
            if !covered, let crop = Geometry.perspectiveCrop(source: extent.size, options: options) {
                let inner = CGRect(x: crop.minX, y: extent.height - crop.maxY, width: crop.width, height: crop.height)
                let plain = source.applyingFilter("CIPerspectiveTransform", parameters: vectors(quad, height: extent.height))
                warped = warped.composited(over: plain.cropped(to: inner).clampedToExtent())
            }
        } else {
            warped = source.applyingFilter("CIPerspectiveTransform", parameters: parameters)
        }
        if empty == .color { warped = warped.composited(over: solid(fill, rect)) }
        return warped.cropped(to: rect)
    }

    /// The source area (Core Image coordinates) whose warp covers what it can of `box` (Core Image coordinates):
    /// the image plus the reach of the box's edge back into the source, at most two image sizes out, and kept in
    /// front of the warp's horizon (Core Image's output extent breaks past it). `covered` is false when part of the
    /// box can't be reached that way (past the horizon, or beyond the limit).
    static func extendedSource(_ quad: Quad, box: CGRect, size: CGSize) -> (area: CGRect, covered: Bool) {
        let image = CGRect(origin: .zero, size: size)
        guard let map = Homography(quad), size.width > 0, size.height > 0 else { return (image, false) }
        // Top-left coordinates for the quad maths; the box's outline, sampled.
        let top = size.height - box.maxY
        let bottom = size.height - box.minY
        var outline: [CGPoint] = []
        for step in 0...32 {
            let fraction = CGFloat(step) / 32
            let across = box.minX + fraction * box.width
            let down = top + fraction * (bottom - top)
            outline += [CGPoint(x: across, y: top), CGPoint(x: across, y: bottom),
                        CGPoint(x: box.minX, y: down), CGPoint(x: box.maxX, y: down)]
        }
        let limit = image.insetBy(dx: -2 * size.width, dy: -2 * size.height)
        var area = image
        var covered = true
        for point in outline {
            guard let unit = map.unit(for: point) else { covered = false; continue }
            let exact = CGPoint(x: unit.x * size.width, y: size.height - unit.y * size.height)
            let source = CGPoint(x: min(limit.maxX, max(limit.minX, exact.x)),
                                 y: min(limit.maxY, max(limit.minY, exact.y)))
            if source != exact { covered = false }
            area = area.union(CGRect(origin: source, size: .zero))
        }
        area = area.insetBy(dx: -2, dy: -2).intersection(limit)
        // Pull the area back towards the image until all its corners map in front of the horizon.
        let safe: (CGRect) -> Bool = { rect in
            [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
             CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)].allSatisfy {
                map.weight(CGPoint(x: $0.x / size.width, y: 1 - $0.y / size.height)) > 0.05
            }
        }
        if !safe(area) { covered = false }
        for _ in 0..<24 where !safe(area) {
            area = CGRect(x: area.minX + (image.minX - area.minX) / 4, y: area.minY + (image.minY - area.minY) / 4,
                          width: area.width + (image.width - area.width) / 4,
                          height: area.height + (image.height - area.height) / 4)
        }
        return safe(area) ? (area.integral, covered) : (image, false)
    }

    /// `layer`'s `rect` scaled to exactly `target`, aspect kept: to fill and centre-cropped when cropping, else to
    /// fit and centred with the bars filled like the other empty areas. Returns the image and its rectangle.
    private static func sized(_ layer: CIImage, _ rect: CGRect, to target: CGSize,
                              _ options: PerspectiveOptions) -> (CIImage, CGRect) {
        let (empty, fill) = (options.emptyAreas, options.fillColor)
        let output = CGRect(origin: .zero, size: target)
        // Clamped so the scaled edges sample real pixels instead of fading out.
        let content = layer.cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .clampedToExtent()
        if empty == .crop {
            let scale = max(target.width / rect.width, target.height / rect.height)
            let shiftX = ((rect.width * scale - target.width) / 2).rounded()
            let shiftY = ((rect.height * scale - target.height) / 2).rounded()
            let scaled = content.transformed(by: CGAffineTransform(scaleX: scale, y: scale), highQualityDownsample: true)
                .transformed(by: CGAffineTransform(translationX: -shiftX, y: -shiftY))
            return (scaled.cropped(to: output), output)
        }
        let placed = Geometry.fitPlacement(content: rect.size, target: target)
        // One scale for both axes, so the aspect is kept exactly.
        let scale = min(target.width / rect.width, target.height / rect.height)
        let scaled = content.transformed(by: CGAffineTransform(scaleX: scale, y: scale), highQualityDownsample: true)
            .transformed(by: CGAffineTransform(translationX: placed.minX, y: placed.minY))
        switch empty {
        case .extend: return (scaled.cropped(to: output), output)
        case .color: return (scaled.cropped(to: placed).composited(over: solid(fill, output)), output)
        case .transparent, .crop: return (scaled.cropped(to: placed), output)
        }
    }

    /// `color` (sRGB) over `rect`.
    private static func solid(_ color: RGBAColor, _ rect: CGRect) -> CIImage {
        let clean: (Double) -> CGFloat = { CGFloat($0.isFinite ? min(1, max(0, $0)) : 0) }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let value = CIColor(red: clean(color.red), green: clean(color.green), blue: clean(color.blue),
                            alpha: clean(color.alpha), colorSpace: space) ?? CIColor(red: 1, green: 1, blue: 1)
        return CIImage(color: value).cropped(to: rect)
    }

    /// The filter's corner parameters (Core Image coordinates, y up) for `quad`.
    private static func vectors(_ quad: Quad, height: CGFloat) -> [String: Any] {
        let vector: (CGPoint) -> CIVector = { CIVector(x: $0.x, y: height - $0.y) }
        return ["inputTopLeft": vector(quad.topLeft), "inputTopRight": vector(quad.topRight),
                "inputBottomRight": vector(quad.bottomRight), "inputBottomLeft": vector(quad.bottomLeft)]
    }
}

extension PerspectiveOptions {
    /// How many input-sized images the step holds at once (`Pipeline.workingCopies`), from the measured peak at
    /// 100 MP (round 3): crop 2.0 GB, colour/transparent 2.5 GB, extend edges (with its fallback) 3.6 GB, so a big
    /// image runs alone instead of beside others.
    var workingCopies: Int {
        guard !Perspective.isNoOp(self) else { return 1 }
        switch emptyAreas {
        case .crop: return 4
        case .color, .transparent: return 5
        case .extend: return 6
        }
    }
}
