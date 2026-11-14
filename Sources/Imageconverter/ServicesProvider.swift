import AppKit
import ImageconverterCore

/// Finder services (Quick Actions). The menu titles and messages are declared in Info.plist (`NSServices`, see
/// `Resources/Info-fragments.plist`), so the pinned-preset services are fixed slots: "Convert with Preset n"
/// runs the preset whose `serviceSlot` is n (kept from pinning until unpinning; see `ServicePins`).
final class ServicesProvider: NSObject {
    /// "Convert with imageconverter": adds the selected files and folders and shows the window.
    @objc func convertWithImageconverter(_ pasteboard: NSPasteboard, userData: String?,
                                         error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let files = checkedFiles(pasteboard, error: error) else { return }
        MainActor.assumeIsolated { ExternalActions.shared.add(files) }
    }

    @objc func convertWithPinnedPreset1(_ pasteboard: NSPasteboard, userData: String?,
                                        error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        convertPinned(slot: 1, pasteboard, error: error)
    }

    @objc func convertWithPinnedPreset2(_ pasteboard: NSPasteboard, userData: String?,
                                        error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        convertPinned(slot: 2, pasteboard, error: error)
    }

    @objc func convertWithPinnedPreset3(_ pasteboard: NSPasteboard, userData: String?,
                                        error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        convertPinned(slot: 3, pasteboard, error: error)
    }

    @objc func convertWithPinnedPreset4(_ pasteboard: NSPasteboard, userData: String?,
                                        error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        convertPinned(slot: 4, pasteboard, error: error)
    }

    @objc func convertWithPinnedPreset5(_ pasteboard: NSPasteboard, userData: String?,
                                        error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        convertPinned(slot: 5, pasteboard, error: error)
    }

    /// The pasteboard's file URLs, checked like every external request; sets `error` when there are none.
    private func checkedFiles(_ pasteboard: NSPasteboard,
                              error: AutoreleasingUnsafeMutablePointer<NSString?>) -> [URL]? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        do {
            return try ExternalRequests.validatedFiles(urls)
        } catch let problem {
            // The pasteboard is another process's data: say what's wrong, never read further.
            error.pointee = ((problem as? ExternalRequestError)?.message ?? "The selected files couldn't be read.") as NSString
            MainActor.assumeIsolated { ExternalActions.shared.reportProblem(problem, title: "Couldn't convert") }
            return nil
        }
    }

    /// Runs right away with the pinned preset and the global output mode; overwrite mode asks first.
    private func convertPinned(slot: Int, _ pasteboard: NSPasteboard,
                               error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let files = checkedFiles(pasteboard, error: error) else { return }
        MainActor.assumeIsolated {
            let actions = ExternalActions.shared
            actions.withModel { model, settings in
                guard let preset = ServicePins.preset(forSlot: slot, in: model.userPresets) else {
                    actions.showWindow()
                    model.toasts.show("No preset for Convert with Preset \(slot)", type: .info,
                                      description: "Choose a preset, then More ▸ Show in Finder Quick Actions.")
                    return
                }
                Task {
                    do {
                        let plan = try ExternalRequests.convertPlan(
                            files: files, presetName: preset.name, folder: nil, presets: model.userPresets,
                            globalMode: settings.outputMode)
                        model.toasts.show("Converting \(plan.files.count) with \(preset.name)…", type: .info)
                        _ = try await actions.convert(plan, model: model)
                    } catch ExternalRequestError.cancelled {
                        model.toasts.show("Nothing was converted", type: .info)
                    } catch {
                        actions.reportProblem(error, title: "Couldn't convert with \(preset.name)")
                    }
                }
            }
        }
    }
}
