import AppKit
import ImageconverterCore

// AppleScript commands (Cocoa scripting). `Resources/imageconverter.sdef` names these classes; the
// `@objc` names must match its `cocoa class` attributes. Checks live in `ExternalRequests` (tested in Core).
//
//   convert {alias "…" or "/posix/path"} using preset "Web export" [to folder alias "…"]   → list of written files
//   add files {alias "…"}
//   run batch                                                             → list of written files
//   presets                                                               → list of preset names

/// Shared error reporting and suspension for the commands.
class ImageconverterScriptCommand: NSScriptCommand {
    /// errOSAGeneralError: AppleScript shows `scriptErrorString` as the error message.
    static let failure = -2700

    func fail(_ error: Error) {
        scriptErrorNumber = Self.failure
        scriptErrorString = (error as? ExternalRequestError)?.message ?? error.localizedDescription
    }

    /// Suspends the script, runs `work` on the main actor and returns its result (or its error) to the script.
    func runSuspended(_ work: @escaping @MainActor () async throws -> Any?) -> Any? {
        suspendExecution()
        Task { @MainActor in
            do {
                resumeExecution(withResult: try await work())
            } catch {
                fail(error)
                resumeExecution(withResult: nil)
            }
        }
        return nil
    }

    /// The model, or nil (with a script error) while the app is still starting up.
    @MainActor func attached() -> (AppModel, AppSettings)? {
        guard let model = ExternalActions.shared.model, let settings = ExternalActions.shared.settings else {
            scriptErrorNumber = Self.failure
            scriptErrorString = "imageconverter is still starting. Try again in a moment."
            return nil
        }
        return (model, settings)
    }
}

@objc(ICConvertCommand)
final class ConvertScriptCommand: ImageconverterScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            guard let (model, settings) = attached() else { return nil }
            let arguments = evaluatedArguments ?? [:]
            do {
                let files = try ExternalRequests.fileURLs(fromScriptValue: directParameter)
                let presetName = arguments["preset"] as? String ?? ""
                // Like the files, the folder may be an alias, a POSIX file or a full POSIX path.
                let folder: URL? = try arguments["folder"].map {
                    guard let url = try ExternalRequests.fileURLs(fromScriptValue: $0).first else {
                        throw ExternalRequestError.notAFolder(path: "\($0)")
                    }
                    return url
                }
                let plan = try ExternalRequests.convertPlan(files: files, presetName: presetName, folder: folder,
                                                            presets: model.allPresets, globalMode: settings.outputMode)
                return runSuspended { try await ExternalActions.shared.convert(plan, model: model, interactive: false) }
            } catch {
                fail(error)
                return nil
            }
        }
    }
}

@objc(ICAddFilesCommand)
final class AddFilesScriptCommand: ImageconverterScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            guard let (model, _) = attached() else { return nil }
            do {
                let files = try ExternalRequests.validatedFiles(
                    ExternalRequests.fileURLs(fromScriptValue: directParameter))
                guard !model.isRunning else { throw ExternalRequestError.busy }
                ExternalActions.shared.add(files)
            } catch {
                fail(error)
            }
            return nil
        }
    }
}

/// "run batch" rather than "run": `run` is AppleScript's own launch command, which every `tell` may send.
@objc(ICRunBatchCommand)
final class RunBatchScriptCommand: ImageconverterScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            guard let (model, settings) = attached() else { return nil }
            return runSuspended {
                guard !model.isRunning else { throw ExternalRequestError.busy }
                // Adding is asynchronous; a run straight after `add files` waits for the scan.
                while model.isAdding { try await Task.sleep(for: .milliseconds(100)) }
                guard !model.items.isEmpty else { throw ExternalRequestError.nothingToRun }
                guard let mode = settings.outputMode else { throw ExternalRequestError.noOutputFolder }
                let actions = ExternalActions.shared
                // Scripts are refused while an interrupted batch waits (they can't answer the question).
                _ = try actions.interruptedRunQuestion(model: model, interactive: false)
                // Captured once: the confirmation lists exactly the images that then run.
                let batch = model.items
                let pipeline = model.pipeline
                let presetName = model.session.selected?.name
                if mode.kind == .overwrite {
                    let count = batch.count
                    let pipelineName = model.session.selected.map {
                        model.session.isModified ? "the preset \($0.name) (with unsaved changes)" : "the preset \($0.name)"
                    } ?? "the current pipeline (no preset)"
                    guard await actions.confirm(
                        title: "Replace \(count) original \(count == 1 ? "image" : "images")?",
                        message: "A script asks to run the batch. It "
                            + ExternalRequests.runSummary(files: batch.map(\.source), pipelineName: pipelineName,
                                                          mode: mode).replacingOccurrences(of: "Converts", with: "converts",
                                                                                           options: .anchored),
                        confirm: "Replace Originals", destructive: true) else { throw ExternalRequestError.cancelled }
                }
                return try await withCheckedThrowingContinuation { continuation in
                    let started = model.startRun(batch, pipeline: pipeline, mode: mode, presetName: presetName) {
                        continuation.resume(returning: $0.written)
                    }
                    switch started {
                    case .started: break
                    case .busy: continuation.resume(throwing: ExternalRequestError.busy)
                    case .noAccess: continuation.resume(throwing: ExternalRequestError.noFolderAccess)
                    }
                }
            }
        }
    }
}

@objc(ICPresetsCommand)
final class PresetsScriptCommand: ImageconverterScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            guard let (model, _) = attached() else { return nil }
            return model.allPresets.map(\.name)
        }
    }
}
