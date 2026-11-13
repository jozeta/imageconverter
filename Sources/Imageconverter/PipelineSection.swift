import AppKit
import SwiftUI
import ImageconverterCore

/// The pipeline: image steps (accordion rows) followed by the fixed Output row.
struct PipelineSection: View {
    @Bindable var model: AppModel
    var settings: AppSettings
    private var isCollapsed: Bool { model.pipelineCollapsed }
    @State private var expanded: Set<PipelineStep.ID> = []
    @State private var metadataExpanded = false
    @State private var renameExpanded = false
    @State private var pendingOverwrite = false
    /// Bumped when the overwrite dialog is cancelled, so the menu picker redraws the real mode.
    @State private var pickerID = 0

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
                        dropped: { model.moveStep($0, to: step.id) })
                    .disabled(model.isRunning)
                }
                Text("Always last").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                fileSteps
                outputRow
            }
        }
    }

    private var fileSteps: some View {
        Group {
            FileStepRow(
                title: "Metadata", summary: model.pipeline.metadata.summary,
                isEnabled: $model.pipeline.metadata.isEnabled, isExpanded: $metadataExpanded) {
                MetadataEditor(options: $model.pipeline.metadata)
            }
            FileStepRow(
                title: "Rename", summary: model.pipeline.rename.summary,
                isEnabled: $model.pipeline.rename.isEnabled, isExpanded: $renameExpanded,
                lockedHelp: settings.modeKind == .overwrite ? "Not available when overwriting originals" : nil) {
                RenameEditor(options: $model.pipeline.rename, example: model.renameExample)
                    .task(id: model.renameExampleKey) { await model.refreshRenameExample() }
            }
        }
        .disabled(model.isRunning)
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

    private var header: some View {
        HStack {
            Text("Pipeline · \(enabledCount) \(enabledCount == 1 ? "step" : "steps")")
                .font(LadaGlass.Typography.label)
                .foregroundStyle(LadaGlass.Colors.muted)
            Spacer()
            Button(isCollapsed ? "Expand" : "Collapse") { model.pipelineCollapsed.toggle() }
                .buttonStyle(.lg(.ghost))
                .accessibilityLabel(isCollapsed ? "Expand the pipeline" : "Collapse the pipeline")
        }
    }

    private var addMenu: some View {
        Menu("+ Add step") {
            ForEach(StepKind.allCases, id: \.self) { kind in
                // New steps start collapsed.
                Button(kind.displayName) { _ = model.addStep(kind) }
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
            Group {
            Picker("Format", selection: $model.pipeline.output.format) {
                ForEach(OutputFormat.available(), id: \.self) { Text($0.displayName).tag($0) }
            }
            .accessibilityLabel("Output format")
            if model.pipeline.output.format.supportsQuality {
                HStack {
                    Slider(value: $model.pipeline.output.quality, in: 0.1...1, step: 0.01)
                        .accessibilityLabel("Quality")
                        .accessibilityValue("\(Int((model.pipeline.output.quality * 100).rounded())) percent")
                    Text("\(Int((model.pipeline.output.quality * 100).rounded())) %")
                        .font(LadaGlass.Typography.mono)
                        .frame(minWidth: 44, alignment: .trailing)
                }
            }
            if model.pipeline.output.format == .tiff {
                Picker("Compression", selection: $model.pipeline.output.tiffCompression) {
                    Text("None").tag(TIFFCompression.none)
                    Text("LZW").tag(TIFFCompression.lzw)
                }
                .accessibilityLabel("TIFF compression")
            }
            }
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
        if model.estimateFailed { return "—" }
        guard !model.isEstimating, let estimate = model.sizeEstimate, let output = estimate.output else { return "Estimating…" }
        let original = estimate.original.map(Self.bytes) ?? "—"
        return "Original \(original) → about \(Self.bytes(output))"
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

private struct StepRow: View {
    @Binding var step: PipelineStep
    @Binding var isExpanded: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let remove: () -> Void
    let dropped: (PipelineStep.ID) -> Bool
    @State private var isTargeted = false

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
                Button(action: remove) { Image(systemName: "xmark") }
                    .buttonStyle(.lg(.ghost))
                    .accessibilityLabel("Remove \(name)")
                    .help("Remove \(name)")
            }
            .contentShape(Rectangle())
            .contextMenu { actions }
        } content: {
            StepEditor(operation: $step.operation)
        }
        .overlay(alignment: .top) {
            if isTargeted {
                Capsule().fill(LadaGlass.accent.color).frame(height: 2).offset(y: -1)
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
            .onHover { inside in
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .draggable(step.id.uuidString) {
                Text(name)
                    .font(LadaGlass.Typography.subtitle)
                    .padding(.horizontal, LadaGlass.Spacing.m)
                    .padding(.vertical, LadaGlass.Spacing.s)
                    .lgSurface()
            }
            .help("Drag to reorder")
            .accessibilityHidden(true)
    }

    @ViewBuilder private var actions: some View {
        Button("Move Up") { move(-1) }.disabled(!canMoveUp)
        Button("Move Down") { move(1) }.disabled(!canMoveDown)
        Divider()
        Button("Remove", role: .destructive, action: remove)
    }
}
