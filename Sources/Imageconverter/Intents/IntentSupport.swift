import AppIntents
import Foundation
import ImageconverterCore
import UniformTypeIdentifiers

/// An error Shortcuts shows with our own words.
struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    init(_ message: String) { self.message = message }
    init(_ error: Error) { message = Automation.message(for: error) }

    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// What the Shortcuts actions share: the app's presets and jobs, files handed over by Shortcuts, and the run
/// itself (`Automation` in Core, tested there). The actions run inside the app (sandboxed) without showing it.
enum IntentContext {
    /// Built-in and saved presets, read from the presets folder each time (another window may have just saved one).
    static func presets() async -> [Preset] {
        let directory = await MainActor.run { AppDefaults.presetsDirectory }
        return PresetStore(directory: directory).loadAll().presets
    }

    static func preset(named name: String) async throws -> Preset {
        let presets = await presets()
        do { return try ExternalRequests.preset(named: name, in: presets) } catch { throw IntentFailure(error) }
    }

    static func jobs() async -> [Job] {
        await MainActor.run { JobsController.shared.store.load().jobs }
    }

    /// Runs `request` over the files (or folders) Shortcuts passed and returns the written files. Without an
    /// output folder they are written to a scratch folder in the app's temporary folder and only returned (a
    /// "Save File" action after this one puts them somewhere); with one, they are written there (it must be a
    /// folder the app may use) and returned too.
    static func convert(_ files: [IntentFile], request: AutomationRequest, outputFolder: IntentFile?) async throws
        -> [IntentFile] {
        do {
            guard !files.isEmpty else { throw AutomationError.noFiles }
            let scratch = try Automation.newScratchFolder(in: Automation.scratchBase)
            let inputs = try IntentInputs(files, copiesIn: scratch.appendingPathComponent("in", isDirectory: true))
            defer { inputs.release() }
            let output: URL
            var folderGrant: FolderAccess.Grant?
            if let outputFolder {
                (output, folderGrant) = try folder(outputFolder) { ExternalRequests.isWritableDirectory($0) }
            } else {
                output = scratch.appendingPathComponent("out", isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            }
            defer { folderGrant?.release() }
            let directory = await MainActor.run { AppDefaults.presetsDirectory }
            let result = try await Automation.run(inputs.urls, request: request, output: output,
                                                  presets: PresetLibrary.folder(directory))
            return result.written.map(returnedFile)
        } catch let error as IntentFailure {
            throw error
        } catch {
            throw IntentFailure(error)
        }
    }

    /// A folder Shortcuts passed: its location, with any security scope Shortcuts gave started. It must be usable
    /// (`isUsable`), which in the sandbox needs that scope or a folder allowed in Help ▸ Folder Access.
    static func folder(_ file: IntentFile, isUsable: (URL) -> Bool) throws -> (URL, FolderAccess.Grant) {
        guard let url = file.fileURL else { throw AutomationError.folderNotAllowed(path: file.filename) }
        let grant = FolderAccess.Grant([url])
        do {
            return (try Automation.checkedFolder(url, isUsable: isUsable), grant)
        } catch {
            grant.release()
            throw error
        }
    }

    static func returnedFile(_ url: URL) -> IntentFile {
        IntentFile(fileURL: url, filename: url.lastPathComponent, type: UTType(filenameExtension: url.pathExtension))
    }
}

/// The files of one action: Shortcuts' own file locations when the app can read them (security scope started
/// for the length of the action), otherwise a copy of the data Shortcuts passed, in the action's scratch folder.
final class IntentInputs {
    let urls: [URL]
    private let grants: [FolderAccess.Grant]

    init(_ files: [IntentFile], copiesIn copies: URL) throws {
        var urls: [URL] = []
        var grants: [FolderAccess.Grant] = []
        for file in files {
            if let url = file.fileURL {
                let grant = FolderAccess.Grant([url])
                if FileManager.default.isReadableFile(atPath: url.path) {
                    urls.append(url)
                    grants.append(grant)
                    continue
                }
                grant.release()
            }
            urls.append(try Self.copy(file, into: copies))
        }
        self.urls = urls
        self.grants = grants
    }

    func release() { grants.forEach { $0.release() } }

    /// Each copy in its own folder, so two files with the same name keep it.
    private static func copy(_ file: IntentFile, into copies: URL) throws -> URL {
        let name = URL(fileURLWithPath: file.filename).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", name != "/" else {
            throw AutomationError.unreadableFile(name: file.filename)
        }
        let data = file.data
        guard !data.isEmpty else { throw AutomationError.unreadableFile(name: name) }
        let folder = copies.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }
}
