import Foundation

/// Where one extra output of an item goes.
public struct PlannedVariant: Equatable, Sendable {
    public let variant: OutputVariant
    public let destination: URL
    /// How the name was built, for a commit that finds it taken (`PlannedOutput.naming`).
    public var naming: OutputNaming?

    public init(variant: OutputVariant, destination: URL, naming: OutputNaming? = nil) {
        self.variant = variant
        self.destination = destination
        self.naming = naming
    }

    /// The commit plan: always a new file, never replacing or trashing anything.
    func plan(for item: InputItem) -> PlannedOutput {
        var plan = PlannedOutput(item: item, destination: destination, replacesSource: false, trashesSource: false)
        plan.naming = naming
        return plan
    }
}

/// One item's extra outputs to plan.
public struct VariantTarget: Equatable, Sendable {
    public let variants: [OutputVariant]
    /// The rendered base name (nil keeps the source's name), as the primary output's.
    public let baseName: String?
    /// Each variant's own folder names (outermost first), under its base folder (`OutputVariant.baseFolder`): a
    /// `.subfolder` destination's folders first, then its `subfolder`.
    public let subfolders: [[String]]

    public init(variants: [OutputVariant], baseName: String? = nil, subfolders: [[String]]? = nil) {
        self.variants = variants
        self.baseName = baseName
        self.subfolders = subfolders?.count == variants.count ? subfolders ?? [] : variants.map { _ in [] }
    }
}

extension OutputPlanner {
    /// Plans every item's extra outputs, after its primary output was planned (`primaries`, the same order as
    /// `targets`). Each goes into its base folder (`OutputVariant.baseFolder`: the primary output's folder, which in
    /// overwrite mode is the source's own folder; its chosen folder, `folders` saying where each chosen path is
    /// now; or the source's folder), under its own subfolders if it has any, as `<base name><suffix>.<ext>`:
    /// always a new file, in every destination. A name is taken
    /// when any item's source, a reserved source, a primary output, an earlier extra output or an existing file
    /// has it (`_2`, `_3`, ...), so an extra output never replaces anything. Items whose primary plan was refused
    /// get none, and an output with no free name is left out (`failures` lists it).
    public static func planVariants(
        _ targets: [VariantTarget], primaries: [PlannedOutput], reservedSources: [URL] = [],
        folders: [String: URL] = [:], fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        claim: (URL) -> Bool = { _ in true }
    ) -> (plans: [[PlannedVariant]], failures: [[OutputVariant]]) {
        var claimed = Set(primaries.map { key($0.item.source) })
        claimed.formUnion(reservedSources.map(key))
        claimed.formUnion(primaries.filter { !$0.isRefused }.map { key($0.destination) })
        var plans: [[PlannedVariant]] = []
        var failures: [[OutputVariant]] = []
        for (target, primary) in zip(targets, primaries) {
            guard !primary.isRefused else {
                plans.append([])
                failures.append([])
                continue
            }
            let sourceName = primary.item.source.deletingPathExtension().lastPathComponent
            var planned: [PlannedVariant] = []
            var missing: [OutputVariant] = []
            for (variant, subfolders) in zip(target.variants, target.subfolders) {
                let suffix = variant.cleanSuffix
                guard !suffix.isEmpty else {
                    missing.append(variant)
                    continue
                }
                let base = variant.baseFolder(primary: primary.destination, source: primary.item.source,
                                              folders: folders)
                let directory = within(base, Array(subfolders.filter(SubfolderTemplate.isSafeName)
                    .prefix(SubfolderTemplate.maxDepth)))
                let name = fitted(target.baseName ?? sourceName, suffix: suffix)
                let dotExt = ".\(variant.settings.format.fileExtensions[0])"
                let naming = OutputNaming(name: name, suffix: suffix, dotExtension: dotExt)
                let candidate = (1...maxNameAttempts).lazy.map { number -> URL in
                    directory.appendingPathComponent(naming.fileName(number))
                }.first { !claimed.contains(key($0)) && !fileExists($0) && claim($0) }
                guard let candidate else {
                    missing.append(variant)
                    continue
                }
                claimed.insert(key(candidate))
                planned.append(PlannedVariant(variant: variant, destination: candidate, naming: naming))
            }
            plans.append(planned)
            failures.append(missing)
        }
        return (plans, failures)
    }

    /// `name` shortened (by characters) so `name + suffix` stays within `limit` UTF-8 bytes.
    static func fitted(_ name: String, suffix: String, limit: Int = RenameTemplate.maxBytes) -> String {
        var name = name
        while !name.isEmpty, name.utf8.count + suffix.utf8.count > limit { name.removeLast() }
        return name
    }
}
