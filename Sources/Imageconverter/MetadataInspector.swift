import SwiftUI
import ImageconverterCore

/// What the panel's read depends on: the image, its file version and the model's `filesRevision` (bumped after a
/// run, which may have rewritten the file in place).
private struct InspectedFile: Equatable {
    let url: URL?
    let version: FileVersion?
    let revision: Int

    init(_ url: URL?, revision: Int) {
        self.url = url
        version = url.map(FileVersion.init)
        self.revision = revision
    }
}

/// The metadata panel right of the preview: the selected image's metadata by group, searchable, read from the
/// file's header only. Edits, removals and additions are this image's metadata overrides: they apply to its
/// outputs (after the Metadata step), never to the original.
struct MetadataInspector: View {
    @Bindable var model: AppModel
    @State private var inspection: MetadataInspection?
    @State private var query = ""
    @State private var editing: String?
    @State private var highlighted: String?
    @State private var adding: AddingField?

    static let headerNote = "Changes apply to this image's outputs. The original isn't changed."
    /// In Overwrite mode the outputs are the originals: the amber `overwriteNote` says so instead.
    static let overwriteHeaderNote = "Changes apply to this image's outputs."
    static func headerNote(overwrites: Bool) -> String { overwrites ? overwriteHeaderNote : headerNote }
    /// Shown (amber) while Save to is Overwrite originals: the output, with these changes, replaces the original.
    static let overwriteNote = "Overwrite originals is on: these changes end up in the original file when the batch runs."
    @Environment(\.overwritesOriginals) private var overwritesOriginals
    /// The image the shown inspection was read from (a privacy link waits for its own image's rows).
    @State private var inspectedURL: URL?
    static let precedenceHelp = "Your changes are applied after the Metadata step: a field you set here is written "
        + "even when the step removes it, and a field you remove here is left out even when the step keeps or sets "
        + "it. Everything else the step removes stays removed. With the step off, the image's metadata is written "
        + "as it is, with your changes. XMP-only fields and the rating can't be written when the step removes XMP. "
        + "Changes last for this session only; jobs and the command line don't use them."

    private var selected: InputItem? { model.selectedItemIndex.map { model.items[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            header
            if let item = selected {
                content(for: item)
            } else {
                Spacer()
                Text("Select an image to see its metadata").font(LadaGlass.Typography.body)
                    .foregroundStyle(LadaGlass.Colors.muted).frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .lgPanel()
        .padding([.vertical, .trailing], LadaGlass.Spacing.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .lgBackdrop()
        .lgCompact()
        .task(id: InspectedFile(selected?.source, revision: model.filesRevision)) {
            editing = nil
            guard let url = selected?.source else { return inspection = nil }
            inspection = nil
            let read = await Task.detached(priority: .userInitiated) { MetadataInspection.read(url) }.value
            if !Task.isCancelled { (inspection, inspectedURL) = (read, url) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Metadata")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            HStack {
                Text("Metadata").font(LadaGlass.Typography.subtitle)
                Spacer()
                Button { model.setInspectorOpen(false) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.lg(.ghost)).controlSize(.small)
                    .help("Hide the metadata panel (⌥⌘I)").accessibilityLabel("Hide metadata panel")
            }
            Text(Self.headerNote(overwrites: overwritesOriginals))
                .font(LadaGlass.Typography.label)
                .foregroundStyle(LadaGlass.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .help(Self.precedenceHelp)
            if overwritesOriginals {
                Label(Self.overwriteNote, systemImage: "exclamationmark.triangle.fill")
                    .font(LadaGlass.Typography.label)
                    .foregroundStyle(LadaGlass.Colors.warnText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func content(for item: InputItem) -> some View {
        HStack(spacing: LadaGlass.Spacing.xs) {
            Text(item.source.lastPathComponent).font(LadaGlass.Typography.body).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if !item.metadataOverrides.isEmpty {
                Button("Revert All") { model.revertAllMetadata() }
                    .buttonStyle(.lg(.secondary)).controlSize(.small)
                    .disabled(model.isRunning)
                    .help("Undo every metadata change for this image")
            }
        }
        TextField("Search metadata", text: $query).textFieldStyle(.roundedBorder)
            .accessibilityLabel("Search metadata")
        if let inspection {
            if let failure = inspection.failure {
                Text(failure).font(LadaGlass.Typography.body).foregroundStyle(LadaGlass.Colors.muted)
            }
            list(inspection, overrides: item.metadataOverrides)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            Spacer()
        }
    }

    private func list(_ inspection: MetadataInspection, overrides: MetadataOverrides) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
                    added(inspection, overrides: overrides)
                    ForEach(MetadataGroup.allCases, id: \.self) { group in
                        let entries = inspection.entries(in: group, matching: query)
                        if !entries.isEmpty {
                            Text(group.title).font(LadaGlass.Typography.subtitle).padding(.top, LadaGlass.Spacing.xs)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(entries) { entry in
                                MetadataInspectorRow(model: model, entry: entry, highlighted: highlighted == entry.id,
                                                     editing: $editing)
                                    .id(entry.id)
                            }
                        }
                    }
                    addMenu(inspection, overrides: overrides).padding(.top, LadaGlass.Spacing.s)
                    Text(Self.precedenceHelp).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, LadaGlass.Spacing.s)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.inspector.focusToken, initial: true) { _, _ in focus(in: inspection, proxy: proxy) }
            .onChange(of: inspection.entries.count) { _, _ in focus(in: inspection, proxy: proxy) }
        }
    }

    /// Fields added for this image that the file doesn't have.
    @ViewBuilder private func added(_ inspection: MetadataInspection, overrides: MetadataOverrides) -> some View {
        let present = Set(inspection.entries.compactMap(\.field))
        let fields = MetadataOverrideField.all.filter { field in
            guard let value = overrides.fields[field], value != .removed else { return false }
            return !present.contains(field)
        }
        if !fields.isEmpty {
            Text("Added").font(LadaGlass.Typography.subtitle)
            ForEach(fields, id: \.self) { field in
                if let value = overrides.fields[field] {
                    MetadataAddedRow(model: model, field: field, value: value, editing: $editing)
                }
            }
        }
    }

    private func addMenu(_ inspection: MetadataInspection, overrides: MetadataOverrides) -> some View {
        let addable = inspection.addableFields.filter { overrides.fields[$0] == nil }
        return Menu("Add Field") {
            ForEach(addable, id: \.self) { field in
                Button(field.label) { addDraft(field) }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.lg(.secondary))
        .fixedSize()
        .disabled(model.isRunning || addable.isEmpty)
        .help("Adds a field to this image's outputs")
        .sheet(item: $adding) { field in
            AddFieldSheet(field: field.field) { value in
                if model.setMetadataOverride(field.field, to: value) { adding = nil }
            } cancel: { adding = nil }
        }
    }

    private func addDraft(_ field: MetadataOverrideField) {
        editing = nil
        adding = AddingField(field: field)
    }

    /// Scrolls to and highlights the row the privacy link asked for (its field's row when the path isn't shown).
    /// Used once: the request is cleared, so later selections don't scroll, highlight or clear the search again.
    private func focus(in inspection: MetadataInspection, proxy: ScrollViewProxy) {
        guard let path = model.inspector.focus, model.inspector.focusSource == inspectedURL else { return }
        model.inspector.focus = nil
        guard let entry = inspection.entry(for: path) else { return }
        query = ""
        withAnimation(LadaGlass.Motion.standard) { proxy.scrollTo(entry.id, anchor: .center) }
        highlighted = entry.id
        let token = model.inspector.focusToken
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if model.inspector.focusToken == token { withAnimation(LadaGlass.Motion.quick) { highlighted = nil } }
        }
    }
}

private struct AddingField: Identifiable {
    let field: MetadataOverrideField
    var id: String { field.label }
}

/// The sheet for adding a field to this image's outputs.
private struct AddFieldSheet: View {
    @Environment(\.overwritesOriginals) private var overwritesOriginals
    let field: MetadataOverrideField
    let save: (MetadataOverrideValue) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
            Text("Add \(field.label)").font(LadaGlass.Typography.subtitle)
            Text(MetadataInspector.headerNote(overwrites: overwritesOriginals))
                .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
            if overwritesOriginals {
                Text(MetadataInspector.overwriteNote).font(LadaGlass.Typography.label)
                    .foregroundStyle(LadaGlass.Colors.warnText)
            }
            MetadataValueEditor(field: field, initial: nil, save: save, cancel: cancel)
        }
        .padding(LadaGlass.Spacing.l)
        .frame(width: 360)
        .lgSheetSurface()
        .lgCompact()
    }
}

/// The metadata panel's leading edge: drag (or ← →) to change its width, click the handle to hide the panel.
struct InspectorEdge: View {
    let sizer: WindowSizer
    let close: () -> Void
    @State private var dragStart: CGFloat?
    @State private var cursorPushed = false
    static let step: CGFloat = 20

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { setCursor($0) }
            .onDisappear { setCursor(false) }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = dragStart ?? sizer.inspectorWidth
                    dragStart = start
                    sizer.setInspectorWidth(start - value.translation.width)
                }
                .onEnded { _ in dragStart = nil })
            .overlay {
                EdgeHandle(edge: .trailing, pointsOutward: true, label: "Hide metadata panel", action: close)
                    .onKeyPress(.leftArrow) {
                        sizer.setInspectorWidth(sizer.inspectorWidth + Self.step)
                        return .handled
                    }
                    .onKeyPress(.rightArrow) {
                        sizer.setInspectorWidth(sizer.inspectorWidth - Self.step)
                        return .handled
                    }
                    .accessibilityValue("\(Int(sizer.inspectorWidth)) points wide")
                    .accessibilityAdjustableAction { direction in
                        sizer.setInspectorWidth(sizer.inspectorWidth + (direction == .increment ? Self.step : -Self.step))
                    }
            }
            .help("Drag to change the metadata panel's width")
    }

    /// Push and pop stay paired even when the edge goes away under the pointer.
    private func setCursor(_ inside: Bool) {
        guard inside != cursorPushed else { return }
        cursorPushed = inside
        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
    }
}

/// The preview header's button that shows or hides the metadata panel (View ▸ Show Metadata, ⌥⌘I).
struct InspectorToggle: View {
    let model: AppModel

    var body: some View {
        let open = model.inspector.isOpen
        Button { model.toggleInspector() } label: {
            Image(systemName: "sidebar.right")
                .foregroundStyle(open ? LadaGlass.accent.color : LadaGlass.Colors.text)
        }
        .buttonStyle(.lg(.ghost))
        .help(open ? "Hide the metadata panel (⌥⌘I)" : "Show the selected image's metadata (⌥⌘I)")
        .accessibilityLabel(open ? "Hide metadata panel" : "Show metadata panel")
        .accessibilityAddTraits(open ? .isSelected : [])
    }
}

extension EnvironmentValues {
    /// True while Save to is Overwrite originals (the metadata panel then says the changes reach the original).
    @Entry var overwritesOriginals = false
}
