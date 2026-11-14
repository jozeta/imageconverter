import AppKit
import SwiftUI
import ImageconverterCore

/// The pipeline: image steps (accordion rows) followed by the fixed Output row.
struct PipelineSection: View {
    @Bindable var model: AppModel
    var settings: AppSettings
    private var isCollapsed: Bool { model.pipelineCollapsed }
    @State private var expanded: Set<PipelineStep.ID> = []
    /// Set when a drag starts, so rows can show the slot a drop will land in.
    @State private var draggedID: PipelineStep.ID?
    @State fileprivate var metadataExpanded = false
    @State fileprivate var renameExpanded = false
    @State private var pendingOverwrite = false
    /// Bumped when the overwrite dialog is cancelled, so the menu picker redraws the real mode.
    @State private var pickerID = 0

    fileprivate static let overwriteHelp = "Not available when overwriting originals"

    private var enabledCount: Int { model.pipeline.steps.filter(\.isEnabled).count }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            header
            if !isCollapsed {
                addMenu.disabled(model.isRunning)
                ForEach(model.pipeline.steps) { step in
                    StepRow(
                        step: stepBinding(step),
                        isExpanded: expandedBinding(step.id),
                        canMoveUp: step.id != model.pipeline.steps.first?.id,
                        canMoveDown: step.id != model.pipeline.steps.last?.id,
                        move: { model.moveStep(step.id, by: $0) },
                        remove: {
                            expanded.remove(step.id)
                            model.removeStep(step.id)
                        },
                        dropEdge: { dropEdge(for: step.id) },
                        dragStarted: { draggedID = step.id },
                        dropped: { model.moveStep($0, to: step.id) },
                        branchDefaults: branchDefaults)
                    .disabled(model.isRunning)
                }
                if model.pipeline.metadata.isIncluded || model.pipeline.rename.isIncluded {
                    Text("Always last").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                }
                fileSteps
                outputRow
            }
        }
        #if DEBUG
        // Screenshot aid: `-debugExpandSteps` opens every step's editor at launch.
        .onAppear {
            if CommandLine.arguments.contains("-debugExpandSteps") {
                expanded = Set(model.pipeline.steps.map(\.id))
                metadataExpanded = true
                renameExpanded = true
            }
        }
        #endif
    }

    /// moveStep(_:to:) puts the dragged step at the target's index: above it when coming from below,
    /// below it when coming from above. Nil on the dragged row itself.
    private func dropEdge(for id: PipelineStep.ID) -> VerticalEdge? {
        let steps = model.pipeline.steps
        guard let dragged = draggedID, dragged != id,
              let from = steps.firstIndex(where: { $0.id == dragged }),
              let target = steps.firstIndex(where: { $0.id == id }) else { return nil }
        return from > target ? .top : .bottom
    }

    /// Looks the step up by id on every access, so a row that outlives its step cannot index out of range.
    private func stepBinding(_ step: PipelineStep) -> Binding<PipelineStep> {
        let id = step.id
        return Binding(
            get: { model.pipeline.steps.first { $0.id == id } ?? step },
            set: { new in
                if let index = model.pipeline.steps.firstIndex(where: { $0.id == id }) {
                    model.pipeline.steps[index] = new
                }
            })
    }

    private var branchDefaults: BranchDefaults {
        BranchDefaults(output: model.pipeline.output, metadata: model.pipeline.metadata, rename: model.pipeline.rename,
                       renameLockedHelp: settings.modeKind == .overwrite ? Self.overwriteHelp : nil)
    }

    private var header: some View {
        Text("Pipeline · \(enabledCount) \(enabledCount == 1 ? "step" : "steps")")
            .font(LadaGlass.Typography.label)
            .foregroundStyle(LadaGlass.Colors.muted)
    }

    private var addMenu: some View {
        Menu("+ Add step") {
            ForEach(StepKind.allCases.filter { $0 != .condition }, id: \.self) { kind in
                // New steps start collapsed.
                Button(kind.displayName) { _ = model.addStep(kind) }
            }
            Divider()
            Button("If … then … else") { _ = model.addStep(.condition) }
            if !model.pipeline.metadata.isIncluded || !model.pipeline.rename.isIncluded {
                Divider()
                Section("Always last") {
                    if !model.pipeline.metadata.isIncluded {
                        Button("Metadata") {
                            model.pipeline.metadata.isIncluded = true
                            model.pipeline.metadata.isEnabled = true
                            metadataExpanded = false
                        }
                    }
                    if !model.pipeline.rename.isIncluded {
                        Button("Rename") {
                            model.pipeline.rename.isIncluded = true
                            model.pipeline.rename.isEnabled = true
                            renameExpanded = false
                        }
                        .disabled(settings.modeKind == .overwrite)
                        .help(settings.modeKind == .overwrite ? Self.overwriteHelp : "")
                    }
                }
            }
        }
        .accessibilityLabel("Add a pipeline step")
    }

    private func expandedBinding(_ id: PipelineStep.ID) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    private var outputRow: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            Text("Output").font(LadaGlass.Typography.subtitle)
            OutputFormatControls(output: $model.pipeline.output)
                .disabled(model.isRunning)
            estimateLine
            saveToControls
        }
        .padding(.horizontal, LadaGlass.Spacing.m)
        .padding(.vertical, LadaGlass.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lgSurface()
        .onChange(of: pendingOverwrite) { _, pending in
            if !pending, settings.modeKind != .overwrite { pickerID += 1 }
        }
        .confirmationDialog("Overwrite originals?", isPresented: $pendingOverwrite) {
            Button("Use overwrite") { settings.modeKind = .overwrite }
            Button("Cancel", role: .cancel) { pickerID += 1 }
        } message: {
            Text("Converted images will replace the originals. When the format or name changes, "
                + "the original is moved to the Trash. You won't be asked again when running.")
        }
    }

    // MARK: Size estimate

    private var estimateLine: some View {
        Text(estimateText)
            .font(LadaGlass.Typography.label)
            .foregroundStyle(LadaGlass.Colors.muted)
            .accessibilityLabel(estimateText)
    }

    private var estimateText: String {
        if model.items.isEmpty { return "Add images to see the file size" }
        if let reason = model.estimateFailure { return reason }
        if model.estimateFailed { return "—" }
        guard !model.isEstimating, let estimate = model.sizeEstimate, let output = estimate.output else { return "Estimating…" }
        let original = estimate.original.map(Self.bytes) ?? "—"
        let change = estimate.original.flatMap { SizeFormat.percentChange(from: $0, to: output) }.map { " (\($0))" } ?? ""
        let quality = qualitySuffix(estimate.quality, mode: model.pipeline.output.compression)
        let note = estimate.note.map { ". \($0)" } ?? ""
        return "Original \(original) → about \(Self.bytes(output))\(quality)\(change)\(note)"
    }

    private static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    // MARK: Save to

    private var saveToControls: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            Picker("Save to", selection: modeBinding) {
                Text("Overwrite original files").tag(OutputModeKind.overwrite)
                Text("Same folder as original").tag(OutputModeKind.sameFolder)
                Text("New folder").tag(OutputModeKind.newFolder)
            }
            .id(pickerID)
            .accessibilityLabel("Save to")
            switch settings.modeKind {
            case .overwrite:
                note("Converted images replace the originals. The Rename step is off while overwriting.")
            case .sameFolder:
                @Bindable var settings = settings
                note("Added when the name is unchanged")
                TextField("Added when the name is unchanged", text: $settings.sameFolderSuffix)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .accessibilityLabel("Added when the name is unchanged")
            case .newFolder:
                HStack {
                    Text(settings.outputFolder?.path ?? "No folder chosen")
                        .font(LadaGlass.Typography.mono)
                        .foregroundStyle(LadaGlass.Colors.muted)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Choose folder…", action: chooseFolder)
                        .buttonStyle(.lg(.secondary))
                        .accessibilityLabel("Choose output folder")
                }
            }
        }
        .disabled(model.isRunning)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
    }

    /// Reads the stored kind; writing asks first when the change needs the overwrite warning.
    private var modeBinding: Binding<OutputModeKind> {
        Binding(
            get: { settings.modeKind },
            set: { new in
                if needsOverwriteWarning(from: settings.modeKind, to: new) {
                    pendingOverwrite = true
                } else {
                    settings.modeKind = new
                }
            })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose output folder"
        panel.prompt = "Choose"
        if panel.runModal() == .OK { settings.outputFolder = panel.url }
    }
}

extension PipelineSection {
    var fileSteps: some View {
        Group {
            if model.pipeline.metadata.isIncluded {
                FileStepRow(
                    title: "Metadata", summary: model.pipeline.metadata.summary,
                    isEnabled: $model.pipeline.metadata.isEnabled, isExpanded: $metadataExpanded,
                    remove: removeMetadata) {
                    MetadataEditor(options: $model.pipeline.metadata)
                }
            }
            if model.pipeline.rename.isIncluded {
                FileStepRow(
                    title: "Rename", summary: model.pipeline.rename.summary,
                    isEnabled: $model.pipeline.rename.isEnabled, isExpanded: $renameExpanded,
                    lockedHelp: settings.modeKind == .overwrite ? Self.overwriteHelp : nil,
                    remove: removeRename) {
                    RenameEditor(options: $model.pipeline.rename, example: model.renameExample)
                        .task(id: model.renameExampleKey) { await model.refreshRenameExample() }
                }
            }
        }
        .disabled(model.isRunning)
    }

    private func removeMetadata() {
        metadataExpanded = false
        model.pipeline.metadata.isIncluded = false
        model.pipeline.metadata.isEnabled = false
    }

    private func removeRename() {
        renameExpanded = false
        model.pipeline.rename.isIncluded = false
        model.pipeline.rename.isEnabled = false
    }
}

private struct StepRow: View {
    @Binding var step: PipelineStep
    @Binding var isExpanded: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let remove: () -> Void
    let dropEdge: () -> VerticalEdge?
    let dragStarted: () -> Void
    let dropped: (PipelineStep.ID) -> Bool
    let branchDefaults: BranchDefaults
    @State private var isTargeted = false
    @State private var handleHovered = false

    private var name: String { step.operation.kind.displayName }

    var body: some View {
        AccordionCard(isExpanded: $isExpanded, canExpand: step.isEnabled, title: name) {
            HStack(spacing: LadaGlass.Spacing.s) {
                handle
                Toggle("Enabled", isOn: $step.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .accessibilityLabel("\(name) enabled")
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(LadaGlass.Typography.subtitle)
                    Text(step.operation.summary)
                        .font(LadaGlass.Typography.label)
                        .foregroundStyle(LadaGlass.Colors.muted)
                        .lineLimit(1)
                }
                .opacity(step.isEnabled ? 1 : 0.5)
                Spacer(minLength: 0)
                RemoveStepButton(label: name, action: remove)
            }
            .contentShape(Rectangle())
            .contextMenu { actions }
        } content: {
            StepEditor(operation: $step.operation, branchDefaults: branchDefaults)
        }
        .overlay(alignment: dropEdge() == .bottom ? .bottom : .top) {
            if isTargeted, let edge = dropEdge() {
                Capsule().fill(LadaGlass.accent.color).frame(height: 2)
                    .offset(y: edge == .bottom ? 1 : -1)
            }
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first.flatMap(UUID.init(uuidString:)) else { return false }
            return dropped(id)
        } isTargeted: { isTargeted = $0 }
        .accessibilityAction(named: "Move up") { if canMoveUp { move(-1) } }
        .accessibilityAction(named: "Move down") { if canMoveDown { move(1) } }
    }

    private var handle: some View {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(LadaGlass.Colors.muted)
            .frame(width: 20, height: 24)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    handleHovered = true
                    NSCursor.openHand.set()
                case .ended:
                    handleHovered = false
                    NSCursor.arrow.set()
                }
            }
            .onDisappear { if handleHovered { NSCursor.arrow.set() } }
            .draggable(step.id.uuidString) {
                dragPreview.onAppear(perform: dragStarted)
            }
            .help("Drag to reorder")
            .accessibilityHidden(true)
    }

    private var dragPreview: some View {
                Text(name)
                    .font(LadaGlass.Typography.subtitle)
                    .padding(.horizontal, LadaGlass.Spacing.m)
                    .padding(.vertical, LadaGlass.Spacing.s)
                    .lgSurface()
    }

    @ViewBuilder private var actions: some View {
        Button("Move Up") { move(-1) }.disabled(!canMoveUp)
        Button("Move Down") { move(1) }.disabled(!canMoveDown)
        Divider()
        Button("Remove", role: .destructive, action: remove)
    }
}
