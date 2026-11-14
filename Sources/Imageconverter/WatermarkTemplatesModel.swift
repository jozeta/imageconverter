import Foundation
import Observation
import ImageconverterCore

/// The built-in and saved watermark templates behind the Watermark editor's Templates menu.
@MainActor @Observable
final class WatermarkTemplatesModel {
    private(set) var templates: [WatermarkTemplate] = WatermarkTemplates.builtIns
    @ObservationIgnored private let store: WatermarkTemplateStore
    @ObservationIgnored private var loaded = false

    init(store: WatermarkTemplateStore) {
        self.store = store
    }

    var builtIns: [WatermarkTemplate] { templates.filter(\.isBuiltIn) }
    var saved: [WatermarkTemplate] { templates.filter { !$0.isBuiltIn } }

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

    func save(name: String, options: WatermarkOptions) throws {
        try store.save(WatermarkTemplate(name: name, options: options))
        reload()
    }

    func delete(_ template: WatermarkTemplate) throws {
        try store.delete(id: template.id)
        reload()
    }
}
