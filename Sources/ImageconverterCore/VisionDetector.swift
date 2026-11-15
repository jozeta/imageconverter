import CoreGraphics
import Foundation
import Vision

/// What Vision finds in an image, as rectangles normalised to 0...1 with a top-left origin (y down), so they
/// fit the image at any size. Smart crop and the Redact step use it. Tests inject their own.
public protocol VisionDetector: Sendable {
    /// Every face's bounding box.
    func faceRects(in image: CGImage) throws -> [CGRect]
    /// The most salient regions, most confident first.
    func subjectRects(in image: CGImage) throws -> [CGRect]
    /// Every line or block of text Vision finds: recognised lines with a letter or digit, plus text rectangles
    /// recognition drops (stylised or handwritten text).
    func textRects(in image: CGImage) throws -> [CGRect]
    /// Every face's bounding box, found on a copy at most `maxSide` long (Redact looks closer than smart crop).
    func faceRects(in image: CGImage, maxSide: Int) throws -> [CGRect]
}

extension VisionDetector {
    public func faceRects(in image: CGImage, maxSide: Int) throws -> [CGRect] { try faceRects(in: image) }
}

/// The working copy Vision looks at: an image is shrunk to `maxLongSide` first, so a 100 MP photo costs about
/// a megapixel to analyse.
public enum VisionInput {
    public static let maxLongSide = 1024

    /// `image` itself when it already fits, else a copy at most `maxSide` on the long side (8-bit sRGB).
    /// Nil only when the copy can't be made.
    public static func prepared(_ image: CGImage, maxSide: Int = maxLongSide) -> CGImage? {
        let longSide = max(image.width, image.height)
        guard longSide > maxSide else { return image }
        let scale = Double(maxSide) / Double(longSide)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}

/// Vision on this Mac (APIs available since macOS 10.15, so nothing here needs a newer SDK).
public struct SystemVisionDetector: VisionDetector {
    /// How many salient regions make up the subject.
    public static let maxSubjectRegions = 3

    public init() {}

    public func faceRects(in image: CGImage) throws -> [CGRect] {
        try faceRects(in: image, maxSide: VisionInput.maxLongSide)
    }

    public func faceRects(in image: CGImage, maxSide: Int) throws -> [CGRect] {
        guard let input = VisionInput.prepared(image, maxSide: maxSide) else { return [] }
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: input, options: [:]).perform([request])
        return (request.results ?? []).map { Self.topLeft($0.boundingBox) }
    }

    /// Attention-based and objectness-based saliency together; the most confident boxes of both.
    public func subjectRects(in image: CGImage) throws -> [CGRect] {
        guard let input = VisionInput.prepared(image) else { return [] }
        let attention = VNGenerateAttentionBasedSaliencyImageRequest()
        let objectness = VNGenerateObjectnessBasedSaliencyImageRequest()
        try VNImageRequestHandler(cgImage: input, options: [:]).perform([attention, objectness])
        let objects = (attention.results ?? []).flatMap { $0.salientObjects ?? [] }
            + (objectness.results ?? []).flatMap { $0.salientObjects ?? [] }
        return objects.sorted { $0.confidence > $1.confidence }
            .prefix(Self.maxSubjectRegions)
            .map { Self.topLeft($0.boundingBox) }
    }

    /// Read from a copy of up to `Redaction.textMaxLongSide` pixels: small text needs more than faces do.
    public func textRects(in image: CGImage) throws -> [CGRect] {
        guard let input = VisionInput.prepared(image, maxSide: Redaction.textMaxLongSide) else { return [] }
        let request = SystemImageAnalyzer.textRequest()
        let rectangles = VNDetectTextRectanglesRequest()
        try VNImageRequestHandler(cgImage: input, options: [:]).perform([request, rectangles])
        return TextBoxes.merged(recognized: SystemImageAnalyzer.textBoxes(request.results ?? []).map(Self.topLeft),
                                rectangles: (rectangles.results ?? []).map { Self.topLeft($0.boundingBox) })
    }

    /// Vision's normalised boxes have a bottom-left origin.
    static func topLeft(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }
}
