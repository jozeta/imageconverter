import CoreGraphics
import Foundation
// Image attachments for the language model are in the macOS 27 SDK (Swift 6.4, Xcode 27) and later; the macOS 26
// SDKs (Swift 6.2/6.3) have FoundationModels but no image input, and CI's Xcode 16 (Swift 6.1) has neither. Below
// that the generator is compiled out and reports `.unsupportedOS`. `-Xswiftc -DNO_MACOS27_SDK` compiles that same
// fallback on a newer toolchain.
#if compiler(>=6.4) && !NO_MACOS27_SDK
import FoundationModels
#endif

/// Apple's on-device system language model (`SystemLanguageModel.default`), macOS 27 and later. Only this model
/// is used: never a server model, so images and text stay on the Mac. It never asks macOS to download anything;
/// when the model isn't ready it reports why and generates nothing.
public struct SystemAltTextGenerator: AltTextGenerator {
    public static let shared = SystemAltTextGenerator()

    public init() {}

    /// True when this build contains the model call (built with the macOS 27 SDK or later).
    public static var isCompiledIn: Bool {
        #if compiler(>=6.4) && !NO_MACOS27_SDK
        return true
        #else
        return false
        #endif
    }

    public var availability: AltTextAvailability {
        if let simulated = Self.simulatedStatus { return simulated }
        #if compiler(>=6.4) && !NO_MACOS27_SDK
        if #available(macOS 27, *) { return FoundationModelsAltText.availability() }
        #endif
        return .unsupportedOS
    }

    public func generate(for image: CGImage) async throws -> String {
        #if DEBUG
        if let simulated = Self.simulatedStatus {
            // A simulated status never reaches the model: "available" answers with a fixed sample (screenshots).
            guard simulated == .available else { throw AltTextError(simulated.reason ?? "unavailable") }
            return Self.simulatedText
        }
        #endif
        #if compiler(>=6.4) && !NO_MACOS27_SDK
        if #available(macOS 27, *) { return try await FoundationModelsAltText.generate(for: image) }
        #endif
        throw AltTextError(AltTextAvailability.unsupportedOS.reason ?? "unavailable")
    }

    static let simulatedText = "Simulated alt text: a sunset over calm water with a wooden pier in the foreground."

    /// DEBUG builds accept `-debugAltTextStatus available|unsupportedOS|deviceNotEligible|appleIntelligenceNotEnabled|
    /// modelNotReady|noImageSupport` (screenshots). The editor, preview and batch all see it; a simulated status never
    /// calls the model ("available" gives `simulatedText`).
    public static let simulatedStatus: AltTextAvailability? = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-debugAltTextStatus"), index + 1 < args.count else { return nil }
        let all: [String: AltTextAvailability] = [
            "available": .available, "unsupportedOS": .unsupportedOS, "deviceNotEligible": .deviceNotEligible,
            "appleIntelligenceNotEnabled": .appleIntelligenceNotEnabled, "modelNotReady": .modelNotReady,
            "noImageSupport": .noImageSupport,
        ]
        return all[args[index + 1]]
        #else
        return nil
        #endif
    }()
}

#if compiler(>=6.4) && !NO_MACOS27_SDK
@available(macOS 27, *)
enum FoundationModelsAltText {
    static func availability() -> AltTextAvailability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.capabilities.contains(.vision) ? .available : .noImageSupport
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .modelNotReady
            }
        }
    }

    /// One new session per image (no history between images), greedy sampling so the same image gives the same
    /// text, and a short answer. Checked again here: nothing is sent to a model that isn't ready.
    static func generate(for image: CGImage) async throws -> String {
        if let reason = availability().reason { throw AltTextError(reason) }
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: AltText.instructions)
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 120)
        do {
            let response = try await session.respond(options: options) {
                AltText.prompt
                Attachment(image)
            }
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            throw AltTextError(reason(for: error))
        }
    }

    static func reason(for error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .guardrailViolation, .refusal: return "the model declined to describe this image"
        case .exceededContextWindowSize: return "the image needed more than the model can take"
        case .assetsUnavailable: return AltTextAvailability.modelNotReady.reason ?? "the model isn't ready"
        case .rateLimited, .concurrentRequests: return "the model was busy"
        case .unsupportedLanguageOrLocale: return "the model doesn't support the language settings"
        default: return "the model failed"
        }
    }
}
#endif
