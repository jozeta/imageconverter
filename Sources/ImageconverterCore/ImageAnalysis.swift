import CoreGraphics
import Foundation
import Vision

/// One thing Vision's image classifier sees, by its identifier (`dog`, `musical_instrument`), with its confidence.
public struct ImageLabel: Equatable, Sendable {
    public var identifier: String
    public var confidence: Double

    public init(_ identifier: String, confidence: Double) {
        self.identifier = identifier
        self.confidence = confidence
    }

    /// Longest identifier accepted (from Vision or a saved preset).
    public static let maxIdentifierLength = 64

    /// Lower-case ASCII letters, digits, `_`, `-` and spaces, 1...64 characters: what Vision's identifiers use.
    /// Anything else (a hand-edited preset, an unexpected result) is refused, so a label can't carry odd text.
    public static func isValidIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.count <= maxIdentifierLength && text.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-" || $0 == " "
        }
    }

    /// The identifier as words: `musical_instrument` → `musical instrument`.
    public static func displayName(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ")
    }
}

/// What on-device image analysis found in one image. Each value is nil when it wasn't asked for, when the analysis
/// failed (`failure`), or when this Mac can't compute it (`needsNewerSystem`); a check whose value is nil doesn't
/// match, in either form.
public struct ImageAnalysis: Equatable, Sendable {
    /// Classification labels at or above `labelFloor`, most confident first, at most `maxLabels`.
    public var labels: [ImageLabel]?
    public var faceCount: Int?
    public var hasText: Bool?
    /// Vision's overall aesthetics score, −1...1 (macOS 15 and later).
    public var aestheticsScore: Double?
    /// A screenshot, document, receipt or similar rather than a photo (macOS 15 and later).
    public var isUtility: Bool?
    /// Why the analysis couldn't run (cleaned text); nil when it ran.
    public var failure: String?
    /// The aesthetics values were asked for, but this Mac's system doesn't have them.
    public var needsNewerSystem = false

    public init(labels: [ImageLabel]? = nil, faceCount: Int? = nil, hasText: Bool? = nil,
                aestheticsScore: Double? = nil, isUtility: Bool? = nil, failure: String? = nil,
                needsNewerSystem: Bool = false) {
        self.labels = labels
        self.faceCount = faceCount
        self.hasText = hasText
        self.aestheticsScore = aestheticsScore
        self.isUtility = isUtility
        self.failure = failure
        self.needsNewerSystem = needsNewerSystem
    }

    /// Labels below this confidence aren't kept (a "Shows" check can't ask for less).
    public static let labelFloor = 0.05
    public static let maxLabels = 100
    /// The confidence a "Shows" check asks for unless changed, and what `{labels}` lists.
    public static let defaultConfidence = 0.3
    /// At most this many labels go into `{labels}`.
    public static let maxTokenLabels = 10

    /// The report note when the analysis couldn't run.
    public static func unavailableNote(_ reason: String) -> String { "Image analysis unavailable: \(reason)" }
    /// The note (once per run) when a macOS 15 check meets an older system.
    public static let needsNewerSystemNote =
        "Aesthetics and screenshot checks need macOS 15 or later; they don't match on this Mac"

    /// `{labels}`: the labels at or above the default confidence, as words, most confident first, at most 10,
    /// repeats dropped.
    public var tokenLabels: [String] {
        var seen = Set<String>()
        return (labels ?? []).filter { $0.confidence >= Self.defaultConfidence }
            .map { ImageLabel.displayName($0.identifier) }
            .filter { seen.insert($0).inserted }
            .prefix(Self.maxTokenLabels).map { $0 }
    }

    /// The values of `self`, with those of `newer` where it has them (an earlier read asked for less).
    func merged(with newer: ImageAnalysis) -> ImageAnalysis {
        var result = self
        result.labels = newer.labels ?? labels
        result.faceCount = newer.faceCount ?? faceCount
        result.hasText = newer.hasText ?? hasText
        result.aestheticsScore = newer.aestheticsScore ?? aestheticsScore
        result.isUtility = newer.isUtility ?? isUtility
        result.needsNewerSystem = needsNewerSystem || newer.needsNewerSystem
        result.failure = newer.failure ?? failure
        return result
    }

    /// Untrusted error text made short and plain for a report note.
    static func reason(_ error: Error) -> String {
        let text = error.localizedDescription.unicodeScalars.filter {
            $0.properties.generalCategory != .control && $0.properties.generalCategory != .format
        }
        let clean = String(String.UnicodeScalarView(text)).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Vision failed" : String(clean.prefix(120))
    }
}

/// Runs on-device image analysis. Tests inject their own.
public protocol ImageAnalyzer: Sendable {
    /// What `needs` asks for (`.labels`, `.faces`, `.text`, `.aesthetics`), from one pass over `image` (already
    /// downsampled to at most `VisionInput.maxLongSide`). Throws when the analysis can't run.
    func analyze(_ image: CGImage, needs: FactNeeds) throws -> ImageAnalysis
}

/// Vision on this Mac: classification, face rectangles and fast text recognition (macOS 10.15+), and the aesthetics
/// scores (macOS 15+). Everything runs in one request handler.
public struct SystemImageAnalyzer: ImageAnalyzer {
    /// Whether the aesthetics request can run; a test seam for the macOS 14 behaviour.
    public let supportsAesthetics: Bool

    public init(supportsAesthetics: Bool = SystemImageAnalyzer.systemSupportsAesthetics) {
        self.supportsAesthetics = supportsAesthetics
    }

    /// True on macOS 15 and later.
    public static var systemSupportsAesthetics: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }

    public func analyze(_ image: CGImage, needs: FactNeeds) throws -> ImageAnalysis {
        guard let input = VisionInput.prepared(image) else {
            return ImageAnalysis(failure: "the image couldn't be prepared")
        }
        var requests: [VNRequest] = []
        let classify = needs.contains(.labels) ? VNClassifyImageRequest() : nil
        let faces = needs.contains(.faces) ? VNDetectFaceRectanglesRequest() : nil
        let text = needs.contains(.text) ? Self.textRequest() : nil
        requests += [classify, faces, text].compactMap { $0 }
        var aesthetics: VNRequest?
        if needs.contains(.aesthetics), supportsAesthetics, #available(macOS 15, *) {
            let request = VNCalculateImageAestheticsScoresRequest()
            aesthetics = request
            requests.append(request)
        }
        if !requests.isEmpty { try VNImageRequestHandler(cgImage: input, options: [:]).perform(requests) }
        var result = ImageAnalysis()
        if let classify { result.labels = Self.labels(classify.results ?? []) }
        if let faces { result.faceCount = faces.results?.count ?? 0 }
        if let text { result.hasText = !Self.textBoxes(text.results ?? []).isEmpty }
        if needs.contains(.aesthetics) {
            if #available(macOS 15, *), let request = aesthetics as? VNCalculateImageAestheticsScoresRequest {
                let observation = request.results?.first
                let score = observation.map { Double($0.overallScore) }
                result.aestheticsScore = score.flatMap { $0.isFinite ? min(max($0, -1), 1) : nil }
                result.isUtility = observation?.isUtility
            } else {
                result.needsNewerSystem = true
            }
        }
        return result
    }

    /// Fast recognition, no language correction: only whether there is text (and where) matters.
    static func textRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        return request
    }

    /// The boxes of the observations whose best reading has a letter or digit (bottom-left origin, as Vision).
    static func textBoxes(_ observations: [VNRecognizedTextObservation]) -> [CGRect] {
        observations.filter { observation in
            guard let best = observation.topCandidates(1).first else { return false }
            return best.string.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        }.map(\.boundingBox)
    }

    /// Valid identifiers at or above the floor, most confident first.
    static func labels(_ observations: [VNClassificationObservation]) -> [ImageLabel] {
        observations.filter { Double($0.confidence) >= ImageAnalysis.labelFloor && ImageLabel.isValidIdentifier($0.identifier) }
            .sorted { $0.confidence > $1.confidence }
            .prefix(ImageAnalysis.maxLabels)
            .map { ImageLabel($0.identifier, confidence: Double($0.confidence)) }
    }

    /// Every identifier the classifier can report, sorted (for the label picker); empty when Vision can't say.
    public static let knownLabels: [String] = {
        let identifiers = (try? VNClassifyImageRequest().supportedIdentifiers()) ?? []
        return Array(Set(identifiers.filter(ImageLabel.isValidIdentifier))).sorted()
    }()
}
