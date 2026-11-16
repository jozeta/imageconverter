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

/// The working copy for Vision couldn't be made: a detection that can't look must say so, never report nothing
/// found (the Redact step would then write the image unredacted).
public struct VisionInputError: LocalizedError {
    public var errorDescription: String? { "the image couldn't be prepared for Vision" }
}

/// The full-resolution tiles text detection reads in a large image: `side` pixels square (smaller images: none),
/// overlapping by `overlap` so a glyph cut by one tile's edge is whole in its neighbour; the last tile on each
/// side ends at the image's edge, so every tile is full size. Chosen by measurement on 20-line grids of 20 and 24 px
/// text on a busy 8000 × 6000 image at four grid offsets: 2048 px tiles found 7 of 20 lines, 1024/192 and 1024/256
/// missed one line at some offsets, 896/192 found 20 of 20 at every offset (24 MP: about 1.3 s).
public enum TextTiles {
    public static let side = 896
    public static let overlap = 192
    /// How many images read their tiles at once, process-wide. Measured with the command line on 8 large images
    /// (6000 and 8000 px): every batch worker reading tiles at once took 41 s, at most 1, 2 or 3 images at a time
    /// 17–22 s (Vision's accurate recognition contends with itself).
    public static let concurrentImages = 2
    private static let gate = DispatchSemaphore(value: concurrentImages)

    /// Runs `body` once fewer than `concurrentImages` images are reading tiles. A task cancelled while it waited
    /// throws `CancellationError` instead of reading (a cancelled batch item, not an unchecked one).
    static func gated<T>(_ body: () throws -> T) throws -> T {
        gate.wait()
        defer { gate.signal() }
        if Task.isCancelled { throw CancellationError() }
        return try body()
    }

    /// Top-left-origin pixel rects; empty when the image fits one Vision copy (`Redaction.textMaxLongSide`).
    public static func tiles(width: Int, height: Int, side: Int = side, overlap: Int = overlap) -> [CGRect] {
        guard max(width, height) > Redaction.textMaxLongSide, side > overlap, overlap >= 0 else { return [] }
        let columns = origins(length: width, side: side, overlap: overlap)
        let rows = origins(length: height, side: side, overlap: overlap)
        return rows.flatMap { top in
            columns.map { left in
                CGRect(x: left, y: top, width: min(side, width - left), height: min(side, height - top))
            }
        }
    }

    /// 0, side − overlap, …, and `length − side` last (one tile from 0 when `length` fits).
    static func origins(length: Int, side: Int, overlap: Int) -> [Int] {
        guard length > side else { return [0] }
        let stride = side - overlap
        var result = Array(Swift.stride(from: 0, to: length - side, by: stride))
        result.append(length - side)
        return result
    }

    /// A box normalised to `tile` (top-left origin) as a box normalised to the whole image.
    static func imageBox(_ box: CGRect, tile: CGRect, width: Int, height: Int) -> CGRect {
        let imageWidth = Double(width)
        let imageHeight = Double(height)
        return CGRect(x: (Double(tile.minX) + Double(box.minX) * Double(tile.width)) / imageWidth,
                      y: (Double(tile.minY) + Double(box.minY) * Double(tile.height)) / imageHeight,
                      width: Double(box.width) * Double(tile.width) / imageWidth,
                      height: Double(box.height) * Double(tile.height) / imageHeight)
    }

    /// The smallest rect holding `points`; nil when there are none or one isn't finite.
    static func bounds(of points: [CGPoint]) -> CGRect? {
        guard !points.isEmpty, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let horizontal = points.map(\.x)
        let vertical = points.map(\.y)
        guard let minX = horizontal.min(), let maxX = horizontal.max(), let minY = vertical.min(),
              let maxY = vertical.max() else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
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
        guard let input = VisionInput.prepared(image, maxSide: maxSide) else { throw VisionInputError() }
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: input, options: [:]).perform([request])
        return (request.results ?? []).map { Self.topLeft($0.boundingBox) }
    }

    /// Attention-based and objectness-based saliency together; the most confident boxes of both.
    public func subjectRects(in image: CGImage) throws -> [CGRect] {
        guard let input = VisionInput.prepared(image) else { throw VisionInputError() }
        let attention = VNGenerateAttentionBasedSaliencyImageRequest()
        let objectness = VNGenerateObjectnessBasedSaliencyImageRequest()
        try VNImageRequestHandler(cgImage: input, options: [:]).perform([attention, objectness])
        let objects = (attention.results ?? []).flatMap { $0.salientObjects ?? [] }
            + (objectness.results ?? []).flatMap { $0.salientObjects ?? [] }
        return objects.sorted { $0.confidence > $1.confidence }
            .prefix(Self.maxSubjectRegions)
            .map { Self.topLeft($0.boundingBox) }
    }

    /// Text for Redact: the whole image on a copy of up to `Redaction.textMaxLongSide` pixels (recognised lines and
    /// text rectangles), and, when the image is larger, recognised lines in full-resolution tiles
    /// (`TextTiles`): small text shrunk onto the copy is lost, and handing Vision the whole full-resolution image
    /// found none of it either (measured; `minimumTextHeight` made no difference), while small tiles did. Accurate
    /// recognition: fast recognition misses single digits, text turned 30° or more and text cut
    /// by an edge. Throws when the image or a tile can't be prepared, so the step fails closed.
    public func textRects(in image: CGImage) throws -> [CGRect] {
        guard let input = VisionInput.prepared(image, maxSide: Redaction.textMaxLongSide) else {
            throw VisionInputError()
        }
        let request = Self.redactTextRequest()
        let rectangles = VNDetectTextRectanglesRequest()
        try VNImageRequestHandler(cgImage: input, options: [:]).perform([request, rectangles])
        var recognized = Self.textBoxes(request.results ?? [])
        let tiles = TextTiles.tiles(width: image.width, height: image.height)
        if !tiles.isEmpty {
            recognized += try TextTiles.gated { try Self.tileBoxes(tiles, in: image) }
        }
        return TextBoxes.combined(recognized: recognized,
                                  rectangles: (rectangles.results ?? []).map { Self.topLeft($0.boundingBox) })
    }

    /// Recognised lines in each of `tiles` of `image`, as boxes normalised to the whole image.
    private static func tileBoxes(_ tiles: [CGRect], in image: CGImage) throws -> [CGRect] {
        var boxes: [CGRect] = []
        for tile in tiles {
            if Task.isCancelled { throw CancellationError() }
            try autoreleasepool {
                guard let crop = image.cropping(to: tile) else { throw VisionInputError() }
                let request = redactTextRequest()
                try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
                boxes += textBoxes(request.results ?? []).map {
                    TextTiles.imageBox($0, tile: tile, width: image.width, height: image.height)
                }
            }
        }
        return boxes
    }

    /// Accurate recognition without language correction (which only changes the words read, never where).
    static func redactTextRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        return request
    }

    /// Lines whose best reading has a letter or digit, top-left origin: each the box around both the bounding box
    /// and the four corners of its quad, so turned text is covered whole.
    static func textBoxes(_ observations: [VNRecognizedTextObservation]) -> [CGRect] {
        observations.filter { observation in
            guard let best = observation.topCandidates(1).first else { return false }
            return best.string.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        }.map { observation in
            let corners = [observation.topLeft, observation.topRight, observation.bottomLeft, observation.bottomRight]
            let quad = TextTiles.bounds(of: corners)
            return topLeft(quad.map { observation.boundingBox.union($0) } ?? observation.boundingBox)
        }
    }

    /// Vision's normalised boxes have a bottom-left origin.
    static func topLeft(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }
}
