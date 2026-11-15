import Foundation
import ImageconverterCore

extension AppModel {
    /// What is wrong with each extra output (by id); Run stays disabled while there is anything.
    var variantProblems: [UUID: String] { OutputVariant.problems(in: pipeline.extraOutputs) }

    var hasVariantProblems: Bool { !variantProblems.isEmpty }

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

    /// False (with a toast) while an extra output can't run.
    func variantsCanRun() -> Bool {
        guard hasVariantProblems else { return true }
        toasts.show("Fix the extra outputs in the Output panel first", type: .bad)
        return false
    }

    func removeVariant(_ id: UUID) {
        pipeline.extraOutputs.removeAll { $0.id == id }
    }
}
