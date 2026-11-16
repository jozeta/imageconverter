import Foundation
import Observation
import ImageconverterCore

/// The metadata panel right of the preview: open or closed (closed by default, remembered), the row to scroll to
/// and highlight (set by the privacy panel's links), and the images whose outputs get metadata changes.
@MainActor @Observable
final class InspectorState {
    var isOpen: Bool {
        didSet { defaults.set(isOpen, forKey: Self.openKey) }
    }
    /// The path the privacy link pointed at; the panel turns it into its row.
    var focus: MetadataPath?
    /// Bumped by every link, so the same row can be shown again.
    var focusToken = 0
    /// Sources with metadata panel changes (the badge in the filmstrip, grid and list).
    var editedSources: Set<URL> = []
    @ObservationIgnored private let defaults: UserDefaults
    static let openKey = "inspectorOpen"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        isOpen = defaults.bool(forKey: Self.openKey)
    }
}

extension AppModel {
    /// The selected image's metadata panel changes (empty without a selection).
    var selectedOverrides: MetadataOverrides {
        selectedItemIndex.map { items[$0].metadataOverrides } ?? MetadataOverrides()
    }

    /// Whether `source` has metadata panel changes (the badge).
    func hasMetadataEdits(_ source: URL) -> Bool { inspector.editedSources.contains(source) }

    /// Changes the selected image's overrides (never during a run: the batch has its copy). They live in the item,
    /// so they go when the image leaves the batch, and every preview, estimate and run of it uses them.
    func editSelectedMetadata(_ change: (inout MetadataOverrides) -> Void) {
        guard !isRunning, let index = selectedItemIndex else { return }
        var overrides = items[index].metadataOverrides
        change(&overrides)
        guard overrides != items[index].metadataOverrides else { return }
        items[index].metadataOverrides = overrides
        let source = items[index].source
        if overrides.isEmpty { inspector.editedSources.remove(source) } else { inspector.editedSources.insert(source) }
    }

    /// Sets a field on the selected image's outputs; false (and a toast) when the value can't be written.
    @discardableResult
    func setMetadataOverride(_ field: MetadataOverrideField, to value: MetadataOverrideValue) -> Bool {
        guard value.validated != nil else {
            toasts.show("That value can't be written to \(field.label.lowercased())", type: .info)
            return false
        }
        editSelectedMetadata { $0.set(field, to: value) }
        return true
    }

    func removeMetadata(_ path: MetadataPath) { editSelectedMetadata { $0.remove(path) } }
    func revertMetadata(_ path: MetadataPath) { editSelectedMetadata { $0.revert(path) } }
    func revertMetadata(_ field: MetadataOverrideField) { editSelectedMetadata { $0.revert(field) } }
    func revertAllMetadata() { editSelectedMetadata { $0 = MetadataOverrides() } }

    /// After `items` changed: the privacy scan looks at new images; images that left took their changes with them.
    func itemsChanged(from old: [InputItem]) {
        schedulePrivacyScan()
        if items.count < old.count { pruneMetadataEdited() }
    }

    /// Drops sources that left the batch from the badge set (only when there are any, so adding images stays cheap).
    func pruneMetadataEdited() {
        guard !inspector.editedSources.isEmpty else { return }
        let current = Set(items.filter { !$0.metadataOverrides.isEmpty }.map(\.source))
        if current != inspector.editedSources { inspector.editedSources = current }
    }

    // MARK: Panel

    func toggleInspector() { setInspectorOpen(!inspector.isOpen || previewCollapsed) }

    /// Opens or closes the metadata panel. It shows with the preview, so opening it opens a collapsed preview too
    /// (the window widens once for both).
    func setInspectorOpen(_ open: Bool) {
        inspector.isOpen = open
        windowSizer.setInspectorShown(open)
        if open, previewCollapsed { togglePreview() }
    }

    /// The privacy panel's link: selects the image, shows it in the preview (opening the preview when collapsed),
    /// opens the metadata panel and scrolls to and highlights the row at `path`.
    func showMetadata(of source: URL, at path: MetadataPath?) {
        guard let index = items.firstIndex(where: { $0.source == source }) else { return }
        selectedIndex = index
        privacy.showsPanel = false
        setInspectorOpen(true)
        inspector.focus = path
        inspector.focusToken += 1
    }
}
