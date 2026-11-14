import Foundation
import Observation
import ImageconverterCore

/// The built-in and saved metadata templates behind the Metadata editor's Templates menu.
@MainActor @Observable
final class MetadataTemplatesModel {
    private(set) var templates: [MetadataTemplate] = MetadataTemplates.builtIns
    @ObservationIgnored private let store: MetadataTemplateStore
    @ObservationIgnored private var loaded = false

    init(store: MetadataTemplateStore) {
        self.store = store
    }

    var builtIns: [MetadataTemplate] { templates.filter(\.isBuiltIn) }
    var saved: [MetadataTemplate] { templates.filter { !$0.isBuiltIn } }

    /// Reads the folder once (on the first editor that appears); returns the files that were skipped and why.
    func loadIfNeeded() -> [(file: String, reason: String)] {
        guard !loaded else { return [] }
        loaded = true
        return reload()
    }

    @discardableResult
    private func reload() -> [(file: String, reason: String)] {
        let result = store.load()
        templates = result.templates
        return result.skipped
    }

    /// Throws when `name` can't be used for a new template (the same rules `save` applies).
    func validate(_ name: String) throws {
        _ = try store.validatedName(name, existing: templates, excluding: nil)
    }

    func save(name: String, options: MetadataOptions) throws {
        try store.save(MetadataTemplate(name: name, options: options))
        reload()
    }

    func delete(_ template: MetadataTemplate) throws {
        try store.delete(id: template.id)
        reload()
    }
}
