import SwiftUI
import ImageconverterCore

/// The Output panel's extra outputs: one collapsible row per output and "+ Add output".
struct OutputVariantsSection: View {
    @Bindable var model: AppModel
    @State private var expanded: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            ForEach(model.pipeline.extraOutputs) { variant in
                VariantRow(variant: binding(variant), isExpanded: expandedBinding(variant.id),
                           problem: model.variantProblems[variant.id],
                           remove: {
                               SidebarMotion.perform {
                                   expanded.remove(variant.id)
                                   model.removeVariant(variant.id)
                               }
                           })
            }
            Button("+ Add output") {
                SidebarMotion.perform {
                    if let added = model.addVariant() { expanded.insert(added.id) }
                }
            }
            .buttonStyle(.lg(.ghost))
            .disabled(!model.canAddVariant)
            .help(model.canAddVariant ? "Write another file for every image (e.g. a thumbnail)"
                  : OutputVariant.tooManyProblem)
            .accessibilityLabel("Add an extra output")
        }
        .disabled(model.isRunning)
        #if DEBUG
        // Screenshot aid: `-debugExpandSteps` opens every extra output's editor too.
        .onAppear {
            if CommandLine.arguments.contains("-debugExpandSteps") {
                expanded = Set(model.pipeline.extraOutputs.map(\.id))
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
        Binding(get: { expanded.contains(id) },
                set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }
}

/// One extra output: name, format and compression, size, suffix and subfolder.
private struct VariantRow: View {
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
        return parts.joined(separator: " · ")
    }

    var body: some View {
        AccordionCard(isExpanded: $isExpanded, canExpand: true, title: title) {
            HStack(spacing: LadaGlass.Spacing.s) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(LadaGlass.Typography.body)
                    Text(problem ?? summary)
                        .font(LadaGlass.Typography.label)
                        .foregroundStyle(problem == nil ? LadaGlass.Colors.muted : LadaGlass.Colors.badText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                RemoveStepButton(label: "extra output \(title)", action: remove)
            }
            .contentShape(Rectangle())
        } content: {
            VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
                TextField("Name", text: $variant.name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Extra output name")
                OutputFormatControls(output: $variant.settings)
                VariantSizeControls(resize: $variant.resize)
                suffixField
                TextField("Subfolder (optional)", text: subfolderBinding)
                    .textFieldStyle(.roundedBorder)
                    .help("Folder under the main output's folder; rename tokens allowed, e.g. thumbs/{date:yyyy}")
                    .accessibilityLabel("Extra output subfolder")
            }
        }
    }

    private var suffixField: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            HStack(spacing: LadaGlass.Spacing.xs) {
                Text("Suffix").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                TextField("_thumb", text: $variant.nameSuffix)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Extra output name suffix")
            }
            if let problem {
                Text(problem)
                    .font(LadaGlass.Typography.label)
                    .foregroundStyle(LadaGlass.Colors.badText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Problem: \(problem)")
            } else {
                Text("Saved as name\(variant.cleanSuffix).\(variant.settings.format.fileExtensions[0])")
                    .font(LadaGlass.Typography.label)
                    .foregroundStyle(LadaGlass.Colors.muted)
            }
        }
    }

    private var subfolderBinding: Binding<String> {
        Binding(get: { variant.subfolder ?? "" },
                set: { variant.subfolder = $0.isEmpty ? nil : String($0.prefix(RenameTemplate.maxLength)) })
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
