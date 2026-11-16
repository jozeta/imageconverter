import Foundation
import ImageconverterCore

extension AppModel {
    /// What is wrong with each extra output (by id); Run stays disabled while there is anything.
    var variantProblems: [UUID: String] { OutputVariant.problems(in: pipeline.extraOutputs) }

    /// Why Run is off: an extra output that can't run, or a condition that isn't finished (a Shows check without
    /// labels); nil when it can run.
    var runBlocker: String? { OutputVariant.runBlocker(in: pipeline.extraOutputs) ?? pipeline.conditionRunBlocker }

    var canAddVariant: Bool { pipeline.extraOutputs.count < OutputVariant.maxCount }

    /// Adds a thumbnail output (JPEG, longest edge 400 px) with a suffix no other output uses.
    @discardableResult
    func addVariant() -> OutputVariant? {
        guard canAddVariant else { return nil }
        let count = pipeline.extraOutputs.count
        let taken = Set(pipeline.extraOutputs.map { $0.cleanSuffix.lowercased() })
        let candidates = [OutputVariant.defaultSuffix] + (2...OutputVariant.maxCount + 1).map {
            "\(OutputVariant.defaultSuffix)\($0)"
        }
        let suffix = candidates.first { !taken.contains($0) } ?? "_\(count + 1)"
        let variant = OutputVariant(name: count == 0 ? "Thumbnail" : "Output \(count + 2)", nameSuffix: suffix)
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
