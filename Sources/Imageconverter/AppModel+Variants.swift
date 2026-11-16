import AppKit
import Foundation
import ImageconverterCore

extension AppModel {
    /// What is wrong with each extra output (by id); Run stays disabled while there is anything.
    var variantProblems: [UUID: String] { OutputVariant.problems(in: pipeline.extraOutputs) }

    /// Why Run is off: an extra output that can't run, or a condition that isn't finished (a Shows check without
    /// labels); nil when it can run.
    var runBlocker: String? { OutputVariant.runBlocker(in: pipeline.extraOutputs) ?? pipeline.conditionRunBlocker }

    var canAddVariant: Bool { pipeline.extraOutputs.count < OutputVariant.maxCount }

    /// Adds an output panel: a copy of the main output's settings with a free name ("Output 2") and suffix, saved
    /// beside the main output until its own Save to is changed (`OutputVariant.added`).
    @discardableResult
    func addVariant() -> OutputVariant? {
        guard canAddVariant else { return nil }
        let variant = OutputVariant.added(after: pipeline.extraOutputs, main: pipeline.output)
        pipeline.extraOutputs.append(variant)
        return variant
    }

    /// Says once what loading `pipeline` left out (extra outputs that couldn't be read or run).
    func announceLoadNotes(_ pipeline: Pipeline) {
        let notes = pipeline.loadNotes.notes
        guard let first = notes.first else { return }
        toasts.show(first, type: .info, description: notes.count > 1 ? notes.dropFirst().joined(separator: "\n") : nil)
    }

    /// False (with a toast) while an extra output or a condition can't run (`runBlocker`).
    func variantsCanRun() -> Bool {
        guard let blocker = runBlocker else { return true }
        toasts.show(blocker, type: .bad)
        return false
    }

    func removeVariant(_ id: UUID) {
        pipeline.extraOutputs.removeAll { $0.id == id }
    }
}

extension AppModel {
    /// Resolves the extra outputs' chosen folders once for a run (`Pipeline.checkingVariantFolders`): a moved
    /// folder is followed and a stale bookmark renewed (also in the edited pipeline, when it is the one running).
    /// A folder this app can't confirm (a preset from someone else, a folder that is gone) is asked for again with
    /// an open panel; nothing is written there until the user chooses it. `name`: the preset the run uses (for
    /// `{preset}`). Nil when the user cancels.
    func confirmVariantFolders(_ base: Pipeline, named name: String?) -> Pipeline? {
        let pipeline = name.map { base.named($0) } ?? base
        let check = pipeline.checkingVariantFolders()
        var result = check.pipeline
        for variant in check.unconfirmed {
            guard let folder = variant.chosenFolder, let index = result.extraOutputs.firstIndex(where: { $0.id == variant.id })
            else { continue }
            guard let url = askForVariantFolder(folder, name: variant.displayName) else {
                toasts.show("Not run: choose the folder of \u{201C}\(variant.displayName)\u{201D} again", type: .info,
                            description: "That output's folder wasn't chosen in imageconverter on this Mac.")
                return nil
            }
            AccessStore.shared.remember(url)
            result.extraOutputs[index].destination = .folder(VariantFolder.chosen(url))
            VariantFolderTrust.shared.forget()
        }
        if result.extraOutputs != pipeline.extraOutputs,
           self.pipeline.extraOutputs.map(\.id) == pipeline.extraOutputs.map(\.id) {
            self.pipeline.extraOutputs = result.extraOutputs
        }
        return result
    }

    private func askForVariantFolder(_ folder: VariantFolder, name: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        var isFolder: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue
        panel.directoryURL = exists ? folder.url : folder.url.deletingLastPathComponent()
        panel.message = "Choose the folder again for the output \u{201C}\(name)\u{201D}. It was saved as "
            + "\u{201C}\(folder.path)\u{201D}, but imageconverter can't confirm it on this Mac."
        panel.prompt = "Use Folder"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Follows moved extra-output folders and renews stale bookmarks in the edited pipeline (launch, preset load).
    func refreshVariantFolders() {
        let check = pipeline.checkingVariantFolders()
        if check.changed { pipeline = check.pipeline }
    }
}

/// Whether each chosen extra-output folder is confirmed (`VariantFolder.resolution`), cached per folder value so
/// the panel doesn't resolve bookmarks on every redraw.
@MainActor
final class VariantFolderTrust {
    static let shared = VariantFolderTrust()
    private var cache: [VariantFolder: Bool] = [:]

    func needsChoosing(_ folder: VariantFolder) -> Bool {
        guard folder.isChosen else { return false }
        if let known = cache[folder] { return !known }
        let confirmed = folder.resolution().isConfirmed
        cache[folder] = confirmed
        return !confirmed
    }

    func forget() { cache = [:] }
}
