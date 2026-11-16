import SwiftUI
import ImageconverterCore

/// The value controls of the content checks (on-device image analysis): Shows, face count, contains text,
/// aesthetics score and screenshot or document.
struct ContentConditionControls: View {
    @Binding var check: ConditionCheck
    let number: Int

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            controls
            if let reason = ConditionKind(check).unavailableReason {
                Text("\(reason): this check never matches on this Mac, and the report says so once per run.")
                    .font(LadaGlass.Typography.label)
                    .foregroundStyle(LadaGlass.Colors.warnText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        switch check {
        case .shows(let match):
            LabelMatchControls(match: match, number: number) { check = .shows($0) }
        case .faceCount(let comparison, let count):
            HStack(spacing: LadaGlass.Spacing.xs) {
                ComparisonPicker(comparison: Binding(get: { comparison }, set: { check = .faceCount($0, count) }),
                                 number: number)
                NumberField(title: "Condition \(number) faces", value: Binding(get: { count }, set: {
                    check = .faceCount(comparison, $0)
                }), minimum: 0, maximum: ConditionCheck.maxFaceCount, suffix: count == 1 ? "face" : "faces",
                            showsTitle: false)
            }
        case .containsText(let wanted):
            Picker("Condition \(number)", selection: Binding(get: { wanted }, set: { check = .containsText($0) })) {
                Text("contains text").tag(true)
                Text("contains no text").tag(false)
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Condition \(number)")
        case .aesthetics(let comparison, let score):
            HStack(spacing: LadaGlass.Spacing.xs) {
                ComparisonPicker(comparison: Binding(get: { comparison }, set: { check = .aesthetics($0, score) }),
                                 number: number)
                DecimalField(title: "Condition \(number) aesthetics score", value: Binding(get: { score }, set: {
                    check = .aesthetics(comparison, min(max($0, -1), 1))
                }), minimum: -1)
            }
            caption("From −1 (poor) to 1 (excellent), as Vision rates the photo.")
        case .isUtility:
            caption("Vision rates it a screenshot, document, receipt or similar rather than a photo.")
        default:
            EmptyView()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(LadaGlass.Typography.label)
            .foregroundStyle(LadaGlass.Colors.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Shows any of / all of the chosen labels, the label picker and the confidence.
private struct LabelMatchControls: View {
    let match: LabelMatch
    let number: Int
    let set: (LabelMatch) -> Void
    @State private var choosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            HStack(spacing: LadaGlass.Spacing.xs) {
                Picker("Match", selection: Binding(get: { match.requiresAll }, set: { update(requiresAll: $0) })) {
                    Text("any of").tag(false)
                    Text("all of").tag(true)
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Condition \(number): shows any or all of the labels")
                Button("Choose Labels…") { choosing = true }
                    .accessibilityHint("Opens a searchable list of what Vision can recognise")
                    .popover(isPresented: $choosing, arrowEdge: .bottom) {
                        LabelPickerList(chosen: match.labels) { update(labels: $0) }
                    }
            }
            if match.labels.isEmpty {
                Text("No labels chosen. Choose at least one: Run stays off until you do.")
                    .font(LadaGlass.Typography.label)
                    .foregroundStyle(LadaGlass.Colors.badText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(match.labels.map(ImageLabel.displayName).joined(separator: ", "))
                    .font(LadaGlass.Typography.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Chosen labels: \(match.labels.map(ImageLabel.displayName).joined(separator: ", "))")
            }
            HStack(spacing: LadaGlass.Spacing.xs) {
                Text("Confidence at least").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                DecimalField(title: "Condition \(number) confidence", value: Binding(get: { match.minimumConfidence }, set: {
                    update(confidence: min(max($0, LabelMatch.confidenceRange.lowerBound), 1))
                }), minimum: LabelMatch.confidenceRange.lowerBound)
            }
            .help("How sure Vision must be, from 0.05 to 1 (default 0.3). Higher finds fewer images, with fewer mistakes.")
        }
    }

    private func update(labels: [String]? = nil, requiresAll: Bool? = nil, confidence: Double? = nil) {
        set(LabelMatch(labels ?? match.labels, requiresAll: requiresAll ?? match.requiresAll,
                       minimumConfidence: confidence ?? match.minimumConfidence))
    }
}

/// A searchable list of the classifier's labels with a checkbox each; the chosen ones first. Saves identifiers.
private struct LabelPickerList: View {
    let chosen: [String]
    let set: ([String]) -> Void
    @State private var search = ""

    private var matching: [String] {
        let text = search.trimmingCharacters(in: .whitespaces).lowercased()
        return SystemImageAnalyzer.knownLabels.filter { label in
            !chosen.contains(label) && (text.isEmpty || ImageLabel.displayName(label).contains(text))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            TextField("Search labels", text: $search, prompt: Text("Search, e.g. dog, beach, food"))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search labels")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: LadaGlass.Spacing.xxs) {
                    ForEach(chosen, id: \.self) { row($0, isOn: true) }
                    if !chosen.isEmpty, !matching.isEmpty { Divider() }
                    ForEach(matching, id: \.self) { row($0, isOn: false) }
                }
            }
            .frame(height: 260)
            footer
        }
        .padding(LadaGlass.Spacing.m)
        .frame(width: 260)
    }

    private func row(_ label: String, isOn: Bool) -> some View {
        Toggle(ImageLabel.displayName(label), isOn: Binding(get: { isOn }, set: { selected in
            set(selected ? chosen + [label] : chosen.filter { $0 != label })
        }))
        .toggleStyle(.checkbox)
        .disabled(!isOn && chosen.count >= LabelMatch.maxLabels)
    }

    @ViewBuilder private var footer: some View {
        if SystemImageAnalyzer.knownLabels.isEmpty {
            Text("Vision on this Mac lists no labels.")
                .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.warnText)
        } else {
            Text("\(chosen.count) of at most \(LabelMatch.maxLabels) chosen")
                .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
        }
    }
}
