import CoreGraphics
import Foundation

/// Whether this Mac can write alt text with Apple's on-device language model (macOS 27 and later, Apple
/// Intelligence on, the model downloaded by macOS, and a model that takes images).
public enum AltTextAvailability: Equatable, Sendable {
    case available
    /// Below macOS 27.
    case unsupportedOS
    /// macOS 27 or later, but this build was made without the macOS 27 SDK (no image input compiled in).
    case notInThisBuild
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    /// Apple Intelligence is on but macOS hasn't finished getting the model (the app never asks it to).
    case modelNotReady
    /// The system model on this Mac doesn't take images.
    case noImageSupport

    public var isAvailable: Bool { self == .available }

    /// Plain English for the editor and the report note; nil when available.
    public var reason: String? {
        switch self {
        case .available: return nil
        case .unsupportedOS: return "needs macOS 27 or later"
        case .notInThisBuild: return "this build of imageconverter can't generate alt text"
        case .deviceNotEligible: return "this Mac doesn't support Apple Intelligence"
        case .appleIntelligenceNotEnabled: return "Apple Intelligence is turned off in System Settings"
        case .modelNotReady: return "Apple Intelligence isn't ready yet (macOS may still be downloading its model)"
        case .noImageSupport: return "the Apple Intelligence model on this Mac doesn't describe images"
        }
    }
}

/// What generating one image's alt text gave.
public enum AltTextOutcome: Equatable, Sendable {
    /// Sanitised text, 1…250 characters.
    case text(String)
    /// Why there is none (the words after "Alt text not generated: ").
    case failed(String)

    public var text: String? {
        if case .text(let text) = self { return text }
        return nil
    }

    /// The report note: "Alt text generated on this Mac" (marks machine-generated text) or "Alt text not
    /// generated: …".
    public var note: String {
        switch self {
        case .text: return AltText.generatedNote
        case .failed(let reason): return AltText.notGeneratedNote(reason)
        }
    }
}

/// Writes one image's alt text. The system one uses Apple's on-device model only; tests inject a fake.
/// `generate` is only called when `availability` is `.available`.
public protocol AltTextGenerator: Sendable {
    var availability: AltTextAvailability { get }
    /// The model's raw answer for `image` (already ≤ 1024 px, 8-bit sRGB); untrusted, sanitised by the caller.
    func generate(for image: CGImage) async throws -> String
}

/// Alt text for the Metadata step: the fixed prompt, the image the model sees, and the sanitiser for its answer.
public enum AltText {
    /// The longest alt text written, in characters.
    public static let maxLength = 250
    /// The longest side of the copy the model sees.
    public static let maxSide = 1024
    /// How long one image may take.
    public static let timeout: TimeInterval = 30

    /// The session's instructions (English, fixed).
    public static let instructions = "You write alt text for images, for people who use screen readers. "
        + "Answer with the alt text only: one plain sentence in English, at most 250 characters."
    /// The prompt sent with the image (English, fixed).
    public static let prompt = "Write one sentence of alt text for this image, at most 250 characters. Describe what "
        + "is visible: the main subject and the setting. If the image contains text, say that text is there and what "
        + "kind it is (a sign, a document, a screen, a licence plate), but don't copy it: no names, numbers, addresses "
        + "or licence plates. Don't start with \"image of\", \"picture of\" or \"photo of\". Don't guess who people "
        + "are or name them; describe them only by what can be seen."

    public static func notGeneratedNote(_ reason: String) -> String { "Alt text not generated: \(reason)" }
    /// The report note on every item that got alt text (it is machine-generated; review it).
    public static let generatedNote = "Alt text generated on this Mac"

    static let emptyAnswer = "the model gave no usable text"
    static let timedOut = "no answer within 30 seconds"
    /// After three timeouts in a row, or a call still running a minute after it started (`AltTextModelGate`).
    static let notResponding = "the on-device model stopped responding"
    static let unreadable = "the image couldn't be read"
    static let removeXMPReason = "Remove XMP is on, and alt text is stored in XMP"

    // MARK: Sanitising

    /// Leading phrases the prompt asks the model to avoid; removed when it uses them anyway.
    private static let leadIns = ["an image of ", "a picture of ", "a photo of ", "a photograph of ", "image of ",
                                  "picture of ", "photo of ", "photograph of ", "an image showing ",
                                  "a picture showing ", "a photo showing ", "image showing "]
    private static let quotes: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}"), ("'", "'"),
                                                           ("\u{2018}", "\u{2019}")]

    /// The model's answer made safe to write: control, format (bidi overrides and isolates, zero-width spaces, BOM),
    /// private-use and unassigned characters removed, except a zero-width joiner between two emoji and the tag
    /// characters of a flag (variation selectors are marks, so they stay); every run of whitespace one space; wrapping
    /// quotes and an "Image of" lead-in dropped; at most `maxLength` characters, cut at a word boundary. Nil when
    /// nothing is left.
    public static func sanitized(_ raw: String) -> String? {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        let input = Array(raw.unicodeScalars)
        for (index, scalar) in input.enumerated() {
            let category = scalar.properties.generalCategory
            if scalar.properties.isWhitespace || category == .lineSeparator || category == .paragraphSeparator
                || scalar == "\n" || scalar == "\r" || scalar == "\t" {
                pendingSpace = !scalars.isEmpty
                continue
            }
            switch category {
            case .format where keepsFormat(scalar, after: index > 0 ? input[index - 1] : nil,
                                           before: index + 1 < input.count ? input[index + 1] : nil):
                break
            case .control, .format, .privateUse, .surrogate, .unassigned: continue
            default: break
            }
            if pendingSpace { scalars.append(" ") }
            pendingSpace = false
            scalars.append(scalar)
        }
        var text = String(scalars)
        text = unquoted(text)
        for leadIn in leadIns where text.lowercased().hasPrefix(leadIn) {
            text = String(text.dropFirst(leadIn.count))
            text = text.prefix(1).uppercased() + text.dropFirst()
            break
        }
        text = capped(text.trimmingCharacters(in: .whitespaces))
        return text.isEmpty ? nil : text
    }

    /// A format character that belongs to an emoji: a zero-width joiner between two emoji (👩‍💻), or a tag
    /// character continuing a flag (🏴 + tags, e.g. Scotland). Bidi controls and every other one are dropped.
    private static func keepsFormat(_ scalar: Unicode.Scalar, after previous: Unicode.Scalar?,
                                    before next: Unicode.Scalar?) -> Bool {
        guard let previous else { return false }
        if scalar == "\u{200D}", let next {
            return isEmojiPart(previous) && isEmoji(next)
        }
        if (0xE0020...0xE007F).contains(scalar.value) {
            return previous == "\u{1F3F4}" || (0xE0020...0xE007E).contains(previous.value)
        }
        return false
    }

    /// An emoji scalar (not the digits, `#` and `*` that are also emoji bases).
    private static func isEmoji(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isEmoji && scalar.value > 0x7F
    }

    /// An emoji, or what may end one before a joiner: a variation selector or a skin-tone modifier.
    private static func isEmojiPart(_ scalar: Unicode.Scalar) -> Bool {
        isEmoji(scalar) || scalar == "\u{FE0F}" || scalar.properties.isEmojiModifier
    }

    private static func unquoted(_ text: String) -> String {
        for (open, close) in quotes where text.count >= 2 && text.first == open && text.last == close {
            return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// At most `maxLength` characters, ending at a word boundary when the text is longer.
    static func capped(_ text: String) -> String {
        guard text.count > maxLength else { return text }
        let cut = String(text.prefix(maxLength))
        // The next character is a space: the cut is already at a word boundary.
        if text[text.index(text.startIndex, offsetBy: maxLength)] == " " { return cut }
        guard let space = cut.lastIndex(of: " "), space > cut.startIndex else { return cut }
        let word = String(cut[..<space])
        return word.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-\u{2013}\u{2014}"))
    }

    // MARK: The image the model sees

    /// `image` drawn into 8-bit sRGB on white, at most `maxSide` px on the long side (HDR, wide colour, 16-bit and
    /// transparent images all reach the model the same way).
    public static func modelImage(_ image: CGImage) -> CGImage? {
        let longSide = max(image.width, image.height)
        let scale = longSide > maxSide ? Double(maxSide) / Double(longSide) : 1
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        return context.makeImage()
    }
}

extension MetadataOptions {
    /// Whether the batch asks for alt text (the step is on and the option ticked).
    public var generatesAltText: Bool { isActive && generateAltText }

    /// Why the batch asks for alt text but won't ask the model (nothing could store it); nil otherwise. Shared by the
    /// batch (`AltTextSlot`) and the preview.
    public var altTextSkipReason: String? {
        generatesAltText && removeXMP && !altTextAsDescription ? AltText.removeXMPReason : nil
    }

    /// These options with `text` as the generated alt text (and as the description when asked); nil changes nothing.
    func withGeneratedAltText(_ text: String?) -> MetadataOptions {
        guard let text, generatesAltText else { return self }
        var options = self
        options.generatedAltText = text
        if altTextAsDescription { options.description = text }
        return options
    }
}

extension Pipeline {
    /// This pipeline writing `text` as the generated alt text (see `MetadataOptions.withGeneratedAltText`).
    func withGeneratedAltText(_ text: String?) -> Pipeline {
        guard text != nil else { return self }
        var pipeline = self
        pipeline.metadata = metadata.withGeneratedAltText(text)
        return pipeline
    }
}
