import SwiftUI
import ImageconverterCore

/// What a branch's "Set output…", "Set metadata…" and "Set rename…" start from: the pipeline's own settings.
struct BranchDefaults {
    var output = OutputSettings()
    var metadata = MetadataOptions()
    var rename = RenameOptions()
}

/// The if/then/else step: "Match all/any of:" with the conditions, then a Then and an Else list of actions.
struct ConditionEditor: View {
    @Binding var step: ConditionalStep
    let defaults: BranchDefaults
    /// One stable id per condition, so a row's controls follow it when another row is removed.
    @State private var ids: RowIDs

    init(step: Binding<ConditionalStep>, defaults: BranchDefaults) {
        _step = step
        self.defaults = defaults
        _ids = State(initialValue: RowIDs(count: step.wrappedValue.conditions.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            HStack(spacing: LadaGlass.Spacing.xs) {
                Picker("Match", selection: $step.match) {
                    Text("Match all of these").tag(ConditionalStep.Match.all)
                    Text("Match any of these").tag(ConditionalStep.Match.any)
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Match all or any of the conditions")
            }
            ForEach(ids.rows(count: step.conditions.count), id: \.id) { _, index in
                ConditionRow(condition: conditionBinding(index), number: index + 1,
                             canRemove: step.conditions.count > 1) {
                    guard step.conditions.indices.contains(index), step.conditions.count > 1 else { return }
                    ids.sync(count: step.conditions.count)
                    ids.remove(at: index)
                    step.conditions.remove(at: index)
                }
            }
            Button("+ Add condition") {
                ids.sync(count: step.conditions.count)
                step.conditions.append(Condition(ConditionKind.orientation.defaultCheck))
                ids.append()
            }
            .buttonStyle(.lg(.ghost))
            .disabled(step.conditions.count >= ConditionalStep.maxConditions)
            .help(step.conditions.count >= ConditionalStep.maxConditions ? "At most 10 conditions" : "")
            .accessibilityLabel("Add a condition")
            Divider()
            ActionList(title: "Then", actions: $step.then, defaults: defaults)
            ActionList(title: "Else", actions: $step.otherwise, defaults: defaults)
        }
        .onChange(of: step.conditions.count) { _, count in ids.sync(count: count) }
    }

    /// Reads by index on every access, so a row that outlives its condition cannot index out of range.
    private func conditionBinding(_ index: Int) -> Binding<Condition> {
        Binding(
            get: { step.conditions.indices.contains(index) ? step.conditions[index] : Condition(ConditionKind.longestEdge.defaultCheck) },
            set: { if step.conditions.indices.contains(index) { step.conditions[index] = $0 } })
    }
}

/// One condition: its kind (grouped) and a "not" switch on the first line, its own controls below.
private struct ConditionRow: View {
    @Binding var condition: Condition
    let number: Int
    let canRemove: Bool
    let remove: () -> Void

    private var kind: ConditionKind { ConditionKind(condition.check) }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            HStack(spacing: LadaGlass.Spacing.xs) {
                Picker("Condition \(number)", selection: Binding(
                    get: { kind },
                    set: { if $0 != kind { condition.check = $0.converted(from: condition.check) } })) {
                    ForEach(ConditionKind.Group.allCases, id: \.self) { group in
                        Section(group.title) {
                            ForEach(group.kinds, id: \.self) { kind in
                                Text(kind.displayName + (kind.unavailableReason.map { " (\($0.lowercased()))" } ?? ""))
                                    .tag(kind)
                                    // Can't be picked on a Mac that can't run it (a loaded preset may still have it).
                                    .selectionDisabled(kind.unavailableReason != nil && kind != self.kind)
                            }
                        }
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Condition \(number) kind")
                Toggle("Not", isOn: $condition.negated)
                    .toggleStyle(.checkbox)
                    .help("Matches when this check is false: “is not”, “does not contain”, “has no”")
                    .accessibilityLabel("Condition \(number): not")
                    .accessibilityHint("Turns the check around")
                Spacer(minLength: 0)
                RemoveStepButton(label: "condition \(number)", action: remove)
                    .disabled(!canRemove)
                    .opacity(canRemove ? 1 : 0.35)
            }
            ConditionControls(check: $condition.check, number: number)
            if condition.negated {
                Text(condition.summary)
                    .font(LadaGlass.Typography.label)
                    .foregroundStyle(LadaGlass.Colors.muted)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Condition \(number): \(condition.summary)")
    }
}
