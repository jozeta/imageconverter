import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Perspective correction: optional automatic document straightening, then a manual keystone.
public struct PerspectiveOptions: Codable, Equatable, Sendable {
    /// −100...100. +100 pulls the top edge in by 25 % of the width on each side, −100 the bottom edge.
    public var vertical: Double
    /// −100...100. +100 pulls the right edge in by 25 % of the height on each side, −100 the left edge.
    public var horizontal: Double
    /// Detect a rectangle (a document, a screen) and straighten it before the manual keystone.
    public var auto: Bool

    public static let range: ClosedRange<Double> = -100...100

    public init(vertical: Double = 0, horizontal: Double = 0, auto: Bool = false) {
        self.vertical = vertical
        self.horizontal = horizontal
        self.auto = auto
    }

    private enum CodingKeys: String, CodingKey { case vertical, horizontal, auto }

    /// Lenient: missing keys are "no change", out-of-range values are clamped.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(vertical: Self.clamped(try container.decodeIfPresent(Double.self, forKey: .vertical) ?? 0),
                  horizontal: Self.clamped(try container.decodeIfPresent(Double.self, forKey: .horizontal) ?? 0),
                  auto: try container.decodeIfPresent(Bool.self, forKey: .auto) ?? false)
    }

    /// The value limited to −100...100; non-finite values become 0.
    public static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : 0
    }
}

/// Four corners, top-left origin (y down).
struct Quad: Equatable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint
}

extension Geometry {
    /// Where the source corners go for the manual keystone, or nil when the sliders are at 0.
    static func keystoneQuad(source: CGSize, options: PerspectiveOptions) -> Quad? {
        let vertical = Perspective.effective(options.vertical) / 100
        let horizontal = Perspective.effective(options.horizontal) / 100
        guard vertical != 0 || horizontal != 0 else { return nil }
        let wide = source.width
        let high = source.height
        var quad = Quad(topLeft: .zero, topRight: CGPoint(x: wide, y: 0),
                        bottomRight: CGPoint(x: wide, y: high), bottomLeft: CGPoint(x: 0, y: high))
        let inX = 0.25 * abs(vertical) * wide
        if vertical > 0 {
            quad.topLeft.x += inX
            quad.topRight.x -= inX
        } else {
            quad.bottomLeft.x += inX
            quad.bottomRight.x -= inX
        }
        let inY = 0.25 * abs(horizontal) * high
        if horizontal > 0 {
            quad.topRight.y += inY
            quad.bottomRight.y -= inY
        } else {
            quad.topLeft.y += inY
            quad.bottomLeft.y -= inY
        }
        return quad
    }

    /// The axis-aligned rectangle inside the keystoned image, with no empty areas (top-left origin, whole
    /// pixels), or nil when the sliders are at 0. Each side sits at the inner end of its edge, which for a
    /// quad whose corners only move inwards keeps all four corners inside; one pixel is kept clear of the
    /// antialiased edges.
    public static func perspectiveCrop(source: CGSize, options: PerspectiveOptions) -> CGRect? {
        guard let quad = keystoneQuad(source: source, options: options) else { return nil }
        let left = (max(quad.topLeft.x, quad.bottomLeft.x) + 1).rounded(.up)
        let right = (min(quad.topRight.x, quad.bottomRight.x) - 1).rounded(.down)
        let top = (max(quad.topLeft.y, quad.topRight.y) + 1).rounded(.up)
        let bottom = (min(quad.bottomLeft.y, quad.bottomRight.y) - 1).rounded(.down)
        return CGRect(x: left, y: top, width: max(1, right - left), height: max(1, bottom - top))
    }
}

/// Renders `PerspectiveOptions` with Core Image (and Vision for the automatic correction).
public enum Perspective {
    /// The note added when auto correction finds nothing to straighten.
    public static let noEdgesNote = "No document edges found"

    public static func apply(_ options: PerspectiveOptions, to image: CGImage) throws -> CGImage {
        var notes: [String] = []
        return try apply(options, to: image, notes: &notes)
    }

    /// As `apply(_:to:)`, adding `noEdgesNote` to `notes` when auto correction found no rectangle.
    public static func apply(_ options: PerspectiveOptions, to image: CGImage, notes: inout [String]) throws -> CGImage {
        var current = image
        if options.auto {
            // A Vision error is treated like "nothing found": the image is left as it is.
            if let quad = try? detectRectangle(in: current) {
                current = try correct(current, to: quad)
            } else {
                notes.append(noEdgesNote)
            }
        }
        return try keystone(current, options)
    }

    /// A slider value as applied: clamped, and 0 below 0.01 (no visible change).
    static func effective(_ value: Double) -> Double {
        let clean = PerspectiveOptions.clamped(value)
        return abs(clean) < 0.01 ? 0 : clean
    }

    /// True when the options change nothing (no auto, sliders effectively at 0).
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

    /// Straightens the `quad` part of `image` into a rectangle.
    private static func correct(_ image: CGImage, to quad: Quad) throws -> CGImage {
        let step = StepKind.perspective.displayName
        let high = CGFloat(image.height)
        let output = CIImage(cgImage: image).applyingFilter("CIPerspectiveCorrection",
                                                            parameters: vectors(quad, height: high))
        let extent = output.extent.integral
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return image }
        return try Adjustments.render(output, from: extent, like: image, step: step)
    }

    /// Maps the image corners onto the keystone quad, then keeps the inner rectangle.
    private static func keystone(_ image: CGImage, _ options: PerspectiveOptions) throws -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        guard let quad = Geometry.keystoneQuad(source: size, options: options),
              let crop = Geometry.perspectiveCrop(source: size, options: options) else { return image }
        let step = StepKind.perspective.displayName
        let output = CIImage(cgImage: image).applyingFilter("CIPerspectiveTransform",
                                                            parameters: vectors(quad, height: size.height))
        // Core Image is y-up.
        let rect = CGRect(x: crop.minX, y: size.height - crop.maxY, width: crop.width, height: crop.height)
        return try Adjustments.render(output, from: rect, like: image, step: step)
    }

    /// The filter's corner parameters (Core Image coordinates, y up) for `quad`.
    private static func vectors(_ quad: Quad, height: CGFloat) -> [String: Any] {
        let vector: (CGPoint) -> CIVector = { CIVector(x: $0.x, y: height - $0.y) }
        return ["inputTopLeft": vector(quad.topLeft), "inputTopRight": vector(quad.topRight),
                "inputBottomRight": vector(quad.bottomRight), "inputBottomLeft": vector(quad.bottomLeft)]
    }
}
