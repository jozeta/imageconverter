import AppKit
import SwiftUI
import ImageconverterCore

/// The pipeline's steps: "+ Add step", the image steps (accordion rows) and the always-last file steps.
/// The sidebar puts it in a scroll view above the Output panel (`OutputPanel`).
struct PipelineSection: View {
    @Bindable var model: AppModel
    @State private var expanded: Set<PipelineStep.ID> = []
    /// Set when a drag starts, so rows can show the slot a drop will land in.
    @State private var draggedID: PipelineStep.ID?
    @State fileprivate var metadataExpanded = false
    @State fileprivate var renameExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            addMenu.disabled(model.isRunning)
            ForEach(model.pipeline.steps) { step in
                StepRow(
                    step: stepBinding(step),
                    isExpanded: expandedBinding(step.id),
                    canMoveUp: step.id != model.pipeline.steps.first?.id,
                    canMoveDown: step.id != model.pipeline.steps.last?.id,
                    move: { model.moveStep(step.id, by: $0) },
                    remove: {
                        SidebarMotion.perform {
                            expanded.remove(step.id)
                            model.removeStep(step.id)
                        }
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
        .task { await debugStepCycle() }
        #endif
    }

    #if DEBUG
    /// `-debugStepCycle <seconds>`: adds a Resize step, opens its editor, closes it and removes it again,
    /// one action every `seconds`, over and over (animation checks).
    private func debugStepCycle() async {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-debugStepCycle"), index + 1 < arguments.count,
              let seconds = Double(arguments[index + 1]), seconds > 0 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(seconds))
            let step = SidebarMotion.perform { model.addStep(.resize) }
            try? await Task.sleep(for: .seconds(seconds))
            SidebarMotion.perform { _ = expanded.insert(step.id) }
            try? await Task.sleep(for: .seconds(seconds))
            SidebarMotion.perform { _ = expanded.remove(step.id) }
            try? await Task.sleep(for: .seconds(seconds))
            SidebarMotion.perform { model.removeStep(step.id) }
        }
    }
    #endif

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
        BranchDefaults(output: model.pipeline.output, metadata: model.pipeline.metadata, rename: model.pipeline.rename)
    }

    private var addMenu: some View {
        Menu("+ Add step") {
            ForEach(StepKind.allCases.filter { $0 != .condition }, id: \.self) { kind in
                // New steps start collapsed.
                Button(kind.displayName) { _ = SidebarMotion.perform { model.addStep(kind) } }
            }
            Divider()
            Button("If … then … else") { _ = SidebarMotion.perform { model.addStep(.condition) } }
            if !model.pipeline.metadata.isIncluded || !model.pipeline.rename.isIncluded {
                Divider()
                Section("Always last") {
                    if !model.pipeline.metadata.isIncluded {
                        Button("Metadata") {
                            SidebarMotion.perform {
                                model.pipeline.metadata.isIncluded = true
                                model.pipeline.metadata.isEnabled = true
                                metadataExpanded = false
                            }
                        }
                    }
                    if !model.pipeline.rename.isIncluded {
                        Button("Rename") {
                            SidebarMotion.perform {
                                model.pipeline.rename.isIncluded = true
                                model.pipeline.rename.isEnabled = true
                                renameExpanded = false
                            }
                        }
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
                    remove: removeRename) {
                    RenameEditor(options: $model.pipeline.rename, example: model.renameExample)
                        .task(id: model.renameExampleKey) { await model.refreshRenameExample() }
                }
            }
        }
        .disabled(model.isRunning)
    }

    private func removeMetadata() {
        SidebarMotion.perform {
            metadataExpanded = false
            model.pipeline.metadata.isIncluded = false
            model.pipeline.metadata.isEnabled = false
        }
    }

    private func removeRename() {
        SidebarMotion.perform {
            renameExpanded = false
            model.pipeline.rename.isIncluded = false
            model.pipeline.rename.isEnabled = false
        }
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
    @Environment(\.addDroppedFiles) private var addDroppedFiles
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
                .stepHelp(.step(step.operation.kind))
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
            // Only a step id reorders; file locations offered as text go to the window's file drop.
            guard let id = ids.first.flatMap(UUID.init(uuidString:)) else { return addDroppedFiles(ids) }
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

/// "Pipeline · n steps", above the steps (and alone while the pipeline is collapsed).
struct PipelineHeader: View {
    var model: AppModel

    private var enabledCount: Int { model.pipeline.steps.filter(\.isEnabled).count }

    var body: some View {
        Text("Pipeline · \(enabledCount) \(enabledCount == 1 ? "step" : "steps")")
            .font(LadaGlass.Typography.label)
            .foregroundStyle(LadaGlass.Colors.muted)
    }
}

/// The fixed Output panel under the steps (Johan, 2026-11-17): the "Output" heading with the "+" that adds an output,
/// then every output as a card of its own: "Output 1" (the main output: format and compression, the ⓘ with every
/// output's size estimate, Save to), then the extra outputs ("Output 2", "Output 3", …), and When finished (for the
/// whole run) under the cards.
struct OutputPanel: View {
    @Bindable var model: AppModel
    var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            HStack(spacing: LadaGlass.Spacing.s) {
                Text("Output").font(LadaGlass.Typography.subtitle)
                    .stepHelp(.output)
                Spacer(minLength: 0)
                AddOutputButton(model: model)
            }
            MainOutputCard(model: model, settings: settings)
            OutputVariantsSection(model: model)
            afterRunControls
        }
        .padding(.horizontal, LadaGlass.Spacing.m)
        .padding(.vertical, LadaGlass.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The surface is drawn by `CollapsibleOutputPanel`, around its scroll view, so a shorter panel keeps its edge.
    }

    // MARK: When finished

    private var afterRunControls: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            Picker("When finished", selection: $settings.afterRun) {
                ForEach(AfterRunAction.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .accessibilityLabel("When finished")
            if settings.afterRun.notifies && settings.notificationsDenied {
                Text("Notifications are off for imageconverter. Turn them on in System Settings ▸ Notifications.")
                    .font(LadaGlass.Typography.label)
                    .foregroundStyle(LadaGlass.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
