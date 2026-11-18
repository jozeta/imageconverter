import AppKit
import SwiftUI
import ImageconverterCore

/// The Output panel's extra outputs (Johan, round 3), the cards under "Output 1" (`MainOutputCard`): each one is a
/// full output panel of its own (format, compression, size, name suffix and its own Save to), collapsible like a
/// step, with a remove button. The "+" that adds one sits at the top right of the Output panel (`AddOutputButton`).
struct OutputVariantsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            ForEach(model.pipeline.extraOutputs) { variant in
                VariantPanel(variant: binding(variant), isExpanded: expandedBinding(variant.id),
                             problem: model.variantProblems[variant.id],
                             remove: {
                                 SidebarMotion.perform {
                                     model.outputPanel.expandedVariants.remove(variant.id)
                                     model.removeVariant(variant.id)
                                 }
                             })
                    .id(variant.id)
            }
        }
        .disabled(model.isRunning)
        #if DEBUG
        // Screenshot aid: `-debugExpandSteps` opens every extra output's editor too.
        .onAppear {
            if CommandLine.arguments.contains("-debugExpandSteps") {
                model.outputPanel.expandedVariants = Set(model.pipeline.extraOutputs.map(\.id))
            }
        }
        #endif
    }

    /// Looks the output up by id on every access, so a row that outlives its output cannot index out of range.
    private func binding(_ variant: OutputVariant) -> Binding<OutputVariant> {
        let id = variant.id
        return Binding(
            get: { model.pipeline.extraOutputs.first { $0.id == id } ?? variant },
            set: { new in
                if let index = model.pipeline.extraOutputs.firstIndex(where: { $0.id == id }) {
                    model.pipeline.extraOutputs[index] = new
                }
            })
    }

    private func expandedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { model.outputPanel.expandedVariants.contains(id) },
                set: { if $0 { model.outputPanel.expandedVariants.insert(id) } else { model.outputPanel.expandedVariants.remove(id) } })
    }
}

/// The "+" at the top right of the Output panel: adds an output panel (a copy of the main output's settings).
struct AddOutputButton: View {
    var model: AppModel
    @State private var hovered = false

    var body: some View {
        Button {
            SidebarMotion.perform {
                if let added = model.addVariant() { model.outputPanel.expandedVariants.insert(added.id) }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovered ? LadaGlass.Colors.text : LadaGlass.Colors.muted)
        .onHover { hovered = $0 }
        .disabled(!model.canAddVariant || model.isRunning)
        .help(model.canAddVariant
              ? "Add output: another file for every image, with its own format, settings and Save to"
              : OutputVariant.tooManyProblem)
        .accessibilityLabel("Add output")
        .accessibilityHint(model.canAddVariant ? "Adds an output panel with its own format and Save to"
                           : OutputVariant.tooManyProblem)
    }
}

/// One extra output as a panel: its name, the same format and compression controls as the main output, its size,
/// name suffix and Save to.
private struct VariantPanel: View {
    @Binding var variant: OutputVariant
    @Binding var isExpanded: Bool
    let problem: String?
    let remove: () -> Void

    private var title: String { variant.displayName }

    private var summary: String {
        var parts = [variant.settings.format.displayName]
        if variant.settings.format.supportsQuality, variant.settings.compression == .quality {
            parts.append("\(Int((variant.settings.clampedQuality * 100).rounded())) %")
        }
        parts.append(variant.resize?.summary ?? "same size")
        parts.append("name\(variant.cleanSuffix)")
        parts.append(variant.destination?.summary ?? "beside the main output")
        return parts.joined(separator: " · ")
    }

    /// A folder this app can't confirm (a preset from someone else, a moved or deleted folder): Run asks for it.
    private var needsFolder: Bool {
        variant.chosenFolder.map { VariantFolderTrust.shared.needsChoosing($0) } ?? false
    }

    /// The line under the title: a problem, the folder warning, or the summary.
    private var statusLine: String {
        problem ?? (needsFolder ? "\(OutputVariant.chooseFolderAgainProblem) · \(summary)" : summary)
    }

    var body: some View {
        AccordionCard(isExpanded: $isExpanded, canExpand: true, title: title) {
            HStack(spacing: LadaGlass.Spacing.s) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(LadaGlass.Typography.subtitle)
                    Text(statusLine)
                        .font(LadaGlass.Typography.label)
                        .foregroundStyle(problem == nil && !needsFolder ? LadaGlass.Colors.muted
                                         : LadaGlass.Colors.badText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(statusLine)
                        .accessibilityLabel(statusLine)
                }
                Spacer(minLength: 0)
                RemoveStepButton(label: "output \(title)", action: remove)
            }
            .contentShape(Rectangle())
        } content: {
            VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
                labelled("Name") {
                    TextField("Output 2", text: $variant.name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Output name")
                }
                OutputFormatControls(output: $variant.settings)
                VariantSizeControls(resize: $variant.resize)
                suffixField
                VariantSaveToControl(destination: $variant.destination, subfolder: $variant.subfolder)
            }
        }
    }

    private var suffixField: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            labelled("Suffix") {
                TextField("_out2", text: $variant.nameSuffix)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Output name suffix")
            }
            if let problem {
                Text(problem)
                    .font(LadaGlass.Typography.label)
                    .foregroundStyle(LadaGlass.Colors.badText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Problem: \(problem)")
            } else {
                Text("Saved as name\(variant.cleanSuffix).\(variant.settings.format.fileExtensions[0]); "
                     + "every output needs its own suffix, also in another folder")
                    .font(LadaGlass.Typography.label)
                    .foregroundStyle(LadaGlass.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func labelled<Field: View>(_ title: String, @ViewBuilder field: () -> Field) -> some View {
        HStack(spacing: LadaGlass.Spacing.xs) {
            Text(title).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                .frame(width: 64, alignment: .leading)
            field()
        }
    }
}

/// An extra output's Save to: beside the main output (the default), the original's folder, a subfolder next to the
/// original, or a folder of its own. Never "overwrite": an extra output is always a new file.
private struct VariantSaveToControl: View {
    @Binding var destination: OutputDestination?
    /// The output's subfolder template under the main output's folder or the chosen folder.
    @Binding var subfolder: String?
    /// The last folder and subfolder name, so switching away and back keeps them.
    @State private var lastFolder = VariantFolder()
    @State private var lastName = "thumbs"

    enum Choice: String, CaseIterable {
        case besideMain = "Beside the main output"
        case sameFolder = "Same folder as original"
        case subfolder = "Subfolder next to original"
        case newFolder = "New folder"
    }

    private var choice: Choice {
        switch destination {
        case nil: return .besideMain
        case .sameFolder?: return .sameFolder
        case .subfolder?: return .subfolder
        case .folder?: return .newFolder
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            Picker("Save to", selection: choiceBinding.sidebarAnimated) {
                ForEach(Choice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .accessibilityLabel("Output save to")
            switch destination {
            case nil:
                note("Into the main output's folder (next to the originals when they are overwritten)")
                subfolderField
            case .sameFolder?:
                note("Next to each original, as a new file; the original is never replaced")
                if let subfolder, !SubfolderTemplate.isBlank(subfolder) {
                    // Kept for switching back, but not used here.
                    note("Subfolder \u{201C}\(subfolder)\u{201D} isn't used with this option")
                }
            case .subfolder(let name)?:
                TextField("thumbs", text: Binding(
                    get: { name },
                    set: { destination = .subfolder(String($0.prefix(RenameTemplate.maxLength))) }))
                    .textFieldStyle(.roundedBorder)
                    .help("A folder inside each original's folder; rename tokens allowed, e.g. thumbs/{date:yyyy}")
                    .accessibilityLabel("Subfolder name")
            case .folder(let folder)?:
                HStack {
                    Text(folder.isChosen ? folder.path : "No folder chosen")
                        .font(LadaGlass.Typography.mono)
                        .foregroundStyle(LadaGlass.Colors.muted)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Choose folder…", action: chooseFolder)
                        .buttonStyle(.lg(.secondary))
                        .accessibilityLabel("Choose this output's folder")
                }
                if VariantFolderTrust.shared.needsChoosing(folder) {
                    Text("\(OutputVariant.chooseFolderAgainProblem): it wasn't chosen in imageconverter on this Mac "
                         + "(or it moved or is gone). Run asks for it before writing anything there.")
                        .font(LadaGlass.Typography.label)
                        .foregroundStyle(LadaGlass.Colors.badText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                subfolderField
            }
        }
    }

    private var subfolderField: some View {
        HStack(spacing: LadaGlass.Spacing.xs) {
            Text("Subfolder").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                .frame(width: 64, alignment: .leading)
            TextField("none", text: Binding(
                get: { subfolder ?? "" },
                set: { subfolder = $0.isEmpty ? nil : String($0.prefix(RenameTemplate.maxLength)) }))
                .textFieldStyle(.roundedBorder)
                .help("Folder under that folder; rename tokens allowed, e.g. thumbs/{date:yyyy}")
                .accessibilityLabel("Output subfolder")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var choiceBinding: Binding<Choice> {
        Binding(get: { choice }, set: { set($0) })
    }

    private func set(_ new: Choice) {
        guard new != choice else { return }
        if case .folder(let folder)? = destination { lastFolder = folder }
        if case .subfolder(let name)? = destination, !SubfolderTemplate.isBlank(name) { lastName = name }
        switch new {
        case .besideMain: destination = nil
        case .sameFolder:
            // The subfolder stays (for switching back); this option doesn't use it and says so.
            destination = .sameFolder
        case .subfolder:
            // A subfolder template already set becomes the subfolder's name.
            destination = .subfolder(subfolder ?? lastName)
            subfolder = nil
        case .newFolder:
            destination = .folder(lastFolder)
            if !lastFolder.isChosen { DispatchQueue.main.async(execute: chooseFolder) }
        }
    }

    /// The folder is remembered as a folder grant too, so a sandboxed run doesn't ask for it again.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder for this output"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AccessStore.shared.remember(url)
        let folder = VariantFolder.chosen(url)
        lastFolder = folder
        SidebarMotion.perform { destination = .folder(folder) }
    }
}

/// The extra output's size: the main output's, or shrunk to a longest edge, width or height, or scaled.
private struct VariantSizeControls: View {
    @Binding var resize: VariantResize?

    enum Kind: String, CaseIterable {
        case same = "Same as main output", longestEdge = "Longest edge", maxWidth = "Max width"
        case maxHeight = "Max height", percent = "Percentage"
    }

    private var kind: Kind {
        switch resize {
        case nil: return .same
        case .longestEdge: return .longestEdge
        case .maxWidth: return .maxWidth
        case .maxHeight: return .maxHeight
        case .percent: return .percent
        }
    }

    private var pixels: Int {
        switch resize {
        case .longestEdge(let value), .maxWidth(let value), .maxHeight(let value): return value
        default: return 400
        }
    }

    var body: some View {
        Picker("Size", selection: kindBinding.sidebarAnimated) {
            ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .accessibilityLabel("Extra output size")
        switch resize {
        case .longestEdge, .maxWidth, .maxHeight:
            NumberField(title: kind.rawValue, value: Binding(get: { pixels }, set: { set(kind, pixels: $0) }),
                        maximum: VariantResize.pixelRange.upperBound)
            Text("Shrinks only; smaller images keep their size")
                .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
        case .percent(let value):
            HStack(spacing: LadaGlass.Spacing.xs) {
                Text("Scale").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                DecimalField(title: "Percentage", value: Binding(
                    get: { value },
                    set: { resize = .percent(min(max($0, VariantResize.percentRange.lowerBound),
                                                 VariantResize.percentRange.upperBound)) }),
                             suffix: "%")
            }
        case nil:
            EmptyView()
        }
    }

    private var kindBinding: Binding<Kind> {
        Binding(get: { kind }, set: { set($0, pixels: pixels) })
    }

    private func set(_ kind: Kind, pixels: Int) {
        switch kind {
        case .same: resize = nil
        case .longestEdge: resize = .longestEdge(pixels)
        case .maxWidth: resize = .maxWidth(pixels)
        case .maxHeight: resize = .maxHeight(pixels)
        case .percent:
            if case .percent = resize { return }
            resize = .percent(50)
        }
    }
}
