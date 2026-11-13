import SwiftUI
import ImageconverterCore

/// The pipeline: image steps (accordion rows) followed by the fixed Output row.
struct PipelineSection: View {
    @Bindable var model: AppModel
    var settings: AppSettings
    @Environment(\.openSettings) private var openSettings
    @State private var isCollapsed = false
    @State private var expanded: Set<PipelineStep.ID> = []

    private var enabledCount: Int { model.pipeline.steps.filter(\.isEnabled).count }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            header
            if !isCollapsed {
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
                addMenu.disabled(model.isRunning)
                Text("Always last").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                outputRow
            }
        }
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
            Button(isCollapsed ? "Expand" : "Collapse") { isCollapsed.toggle() }
                .buttonStyle(.lg(.ghost))
                .accessibilityLabel(isCollapsed ? "Expand the pipeline" : "Collapse the pipeline")
        }
    }

    private var addMenu: some View {
        Menu("+ Add step") {
            ForEach(StepKind.allCases, id: \.self) { kind in
                Button(kind.displayName) {
                    let step = model.addStep(kind)
                    expanded.insert(step.id)
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
            HStack {
                Text(settings.summary)
                    .font(LadaGlass.Typography.body)
                    .foregroundStyle(LadaGlass.Colors.muted)
                    .lineLimit(2)
                Spacer()
                Button("Change…") { openSettings() }
                    .buttonStyle(.lg(.ghost))
                    .accessibilityLabel("Change output settings")
            }
        }
        .padding(LadaGlass.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lgSurface()
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

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            StepEditor(operation: $step.operation)
                .padding(.top, LadaGlass.Spacing.s)
                .disabled(!step.isEnabled)
        } label: {
            HStack(spacing: LadaGlass.Spacing.s) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(LadaGlass.Colors.muted)
                    .draggable(step.id.uuidString)
                    .help("Drag to reorder")
                    .accessibilityHidden(true)
                Toggle("Enabled", isOn: $step.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .accessibilityLabel("\(step.operation.kind.displayName) enabled")
                VStack(alignment: .leading, spacing: 0) {
                    Text(step.operation.kind.displayName).font(LadaGlass.Typography.subtitle)
                    Text(step.operation.summary)
                        .font(LadaGlass.Typography.label)
                        .foregroundStyle(LadaGlass.Colors.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("\(step.operation.kind.displayName) actions")
            }
            .opacity(step.isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
            .contextMenu { actions }
        }
        .font(LadaGlass.Typography.body)
        .padding(LadaGlass.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lgSurface()
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first.flatMap(UUID.init(uuidString:)) else { return false }
            return dropped(id)
        }
    }

    @ViewBuilder private var actions: some View {
        Button("Move Up") { move(-1) }.disabled(!canMoveUp)
        Button("Move Down") { move(1) }.disabled(!canMoveDown)
        Divider()
        Button("Remove", role: .destructive, action: remove)
    }
}
