import Foundation
import Observation
import ImageconverterCore
// See `MLEnlarge+System.swift`: the VideoToolbox scaler exists only in the macOS 26 SDK and later.
#if compiler(>=6.2) && !NO_MACOS26_SDK
import VideoToolbox
#endif

/// The state of Apple's enlargement model for the Resize editor, and the one place that can download it: only
/// after the person presses Download… and agrees (once; remembered in `mlEnlargeDownloadConsent`), and every
/// download still starts from that button. The batch, jobs, the command line, services, scripts and links never
/// download; their items fail with `MLEnlargeAvailability.refusal`.
@MainActor @Observable
final class MLEnlargeModel {
    static let shared = MLEnlargeModel()
    static let consentKey = "mlEnlargeDownloadConsent"

    private(set) var availability: MLEnlargeAvailability
    /// Why the last download failed, if it did.
    private(set) var downloadError: String?
    @ObservationIgnored private var polling: Task<Void, Never>?

    init() {
        availability = Self.current()
    }

    /// True once the person agreed to the download (they are not asked again).
    var hasConsent: Bool { AppDefaults.store.bool(forKey: Self.consentKey) }

    func recordConsent() { AppDefaults.store.set(true, forKey: Self.consentKey) }

    /// Reads the system's status again (it never downloads).
    func refresh() {
        guard polling == nil else { return }
        availability = Self.current()
    }

    /// The system's status (`SystemSuperResolution` also applies DEBUG's `-debugMLEnlargeStatus`).
    private static func current() -> MLEnlargeAvailability {
        SystemSuperResolution.shared.availability()
    }

    /// Asks macOS to download the model. Call only from the Download… button, after consent.
    func download() {
        // A simulated status (DEBUG screenshots) never downloads.
        guard availability == .downloadRequired, SystemSuperResolution.simulatedStatus == nil else { return }
        downloadError = nil
        #if compiler(>=6.2) && !NO_MACOS26_SDK
        if #available(macOS 26, *) { startSystemDownload() }
        #endif
    }

    #if compiler(>=6.2) && !NO_MACOS26_SDK
    @available(macOS 26, *)
    private func startSystemDownload() {
        guard let configuration = VTSuperResolutionScalerConfiguration(
            frameWidth: 1920, frameHeight: 1920, scaleFactor: 4, inputType: .image, usePrecomputedFlow: false,
            qualityPrioritization: .normal, revision: VTSuperResolutionScalerConfiguration.defaultRevision) else {
            availability = .unsupportedHardware
            return
        }
        availability = .downloading(progress: Double(configuration.configurationModelPercentageAvailable))
        configuration.downloadConfigurationModel { [weak self] error in
            let message = error?.localizedDescription
            Task { @MainActor in self?.finished(error: message) }
        }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.polling != nil else { return }
                if configuration.configurationModelStatus == .downloading {
                    self.availability = .downloading(progress: Double(configuration.configurationModelPercentageAvailable))
                }
            }
        }
    }
    #endif

    private func finished(error: String?) {
        polling?.cancel()
        polling = nil
        downloadError = error.map { "The download didn't finish: \($0)" }
        availability = Self.current()
    }
}
