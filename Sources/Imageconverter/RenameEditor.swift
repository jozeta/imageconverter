import SwiftUI
import ImageconverterCore

// MARK: - Rename

struct RenameEditor: View {
    @Binding var options: RenameOptions
    let example: String

    @FocusState private var focusedRule: UUID?
    /// The first row while there are no rules: edits stay here and nothing is saved until Find has text.
    @State private var placeholder = ReplacementRule()

    private var rows: [ReplacementRule] {
        options.replacements.isEmpty ? [placeholder] : options.replacements
    }

    private var unknown: [String] { RenameTemplate(options.pattern).unknownTokens }

    var body: some View {
        FieldRow {
            TextField("Pattern", text: $options.pattern)
                .textFieldStyle(.roundedBorder)
                .font(LadaGlass.Typography.mono)
                .accessibilityLabel("Rename pattern")
            Menu("Insert") {
                ForEach(RenameTemplate.tokenExamples, id: \.self) { token in
                    Button(token) { options.pattern += token }
                }
                Divider()
                ForEach(Self.quickPatterns, id: \.name) { quick in
                    Button("\(quick.name): \(quick.pattern)") { options.pattern = quick.pattern }
                }
            }
            .fixedSize()
            .accessibilityLabel("Insert token or pattern")
        }
        // The first row is always shown so "+" has a home; with no rules it is a placeholder that becomes
        // the first real rule (same id, so focus survives) when typed into.
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, rule in
            replacementRow(index: index, id: rule.id)
        }
        cleanupFields
        NumberField(title: "Counter starts at", value: $options.counterStart, minimum: RenameOptions.counterRange.lowerBound,
                    maximum: RenameOptions.counterRange.upperBound, suffix: "")
        if !unknown.isEmpty {
            Text(unknown.map { "Unknown token: {\($0)}" }.joined(separator: " · "))
                .font(LadaGlass.Typography.label)
                .foregroundStyle(LadaGlass.Colors.warnText)
        }
        if !example.isEmpty {
            Text(example)
            .font(LadaGlass.Typography.mono)
            .foregroundStyle(LadaGlass.Colors.muted)
            .lineLimit(2)
            .textSelection(.enabled)
            .accessibilityLabel(example)
        }
    }

    /// Whole patterns that replace the current one (the tokens above are appended).
    static let quickPatterns: [(name: String, pattern: String)] = [
        ("Date + counter", "{date:yyyy-MM-dd}_{counter:000}"),
        ("Camera + date", "{camera}_{datetime}"),
        ("Name + size", "{name}_{width}x{height}"),
    ]

    private static let caseLabels: [CaseStyle: String] = [
        .keep: "Keep", .lower: "lowercase", .upper: "UPPERCASE", .camel: "camelCase",
        .pascal: "PascalCase", .snake: "snake_case", .kebab: "kebab-case", .title: "Title Case",
    ]

    @ViewBuilder
    private var cleanupFields: some View {
        FieldRow {
            Text("Prefix").font(LadaGlass.Typography.label)
            TextField("Prefix", text: $options.prefix)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Prefix")
            Text("Suffix").font(LadaGlass.Typography.label)
            TextField("Suffix", text: $options.suffix)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Suffix")
        }
        Toggle("Remove spaces", isOn: $options.removeSpaces)
            .accessibilityLabel("Remove spaces")
        Picker("Special characters", selection: $options.specialCharacters) {
            Text("Keep").tag(SpecialCharacters.keep)
            Text("Replace").tag(SpecialCharacters.replace)
            Text("Remove").tag(SpecialCharacters.remove)
        }
        .accessibilityLabel("Special characters")
        if options.specialCharacters == .replace {
            Picker("Replace with", selection: $options.replacement) {
                Text("-").tag("-")
                Text("_").tag("_")
                Text(".").tag(".")
                Text("nothing").tag("")
            }
            .accessibilityLabel("Replace special characters with")
        }
        Picker("Case", selection: $options.caseStyle) {
            ForEach(CaseStyle.allCases, id: \.self) { Text(Self.caseLabels[$0] ?? $0.rawValue).tag($0) }
        }
        .accessibilityLabel("Case")
    }

    private func ruleBinding(_ id: UUID) -> Binding<ReplacementRule> {
        Binding(
            get: { options.replacements.first { $0.id == id } ?? placeholder },
            set: { new in
                if let slot = options.replacements.firstIndex(where: { $0.id == id }) {
                    options.replacements[slot] = new
                } else if options.replacements.isEmpty {
                    placeholder = new
                    // Same id, so the row and its focus survive the switch from placeholder to real rule.
                    if !new.find.isEmpty { options.replacements = [new] }
                }
            })
    }

    private func replacementRow(index: Int, id: UUID) -> some View {
        let number = index == 0 ? "" : " \(index + 1)"
        let binding = ruleBinding(id)
        return VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            replacementFields(index: index, id: id, number: number, binding: binding)
        }
    }

    @ViewBuilder
    private func replacementFields(index: Int, id: UUID, number: String, binding: Binding<ReplacementRule>) -> some View {
        FieldRow {
            TextField("Find", text: binding.find)
                .textFieldStyle(.roundedBorder)
                .font(LadaGlass.Typography.mono)
                .focused($focusedRule, equals: id)
                .accessibilityLabel("Find\(number)")
            TextField("Replace with", text: binding.replace)
                .textFieldStyle(.roundedBorder)
                .font(LadaGlass.Typography.mono)
                .accessibilityLabel("Replace with\(number)")
            if index == 0 {
                Button { addRule(after: index) } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .padding(LadaGlass.Spacing.xs)
                    .contentShape(Rectangle())
                    .disabled(options.replacements.count >= RenameOptions.maxReplacements
                              || (options.replacements.isEmpty && placeholder.find.isEmpty))
                    .help("Add another find and replace")
                    .accessibilityLabel("Add another find and replace")
            } else {
                RemoveStepButton(label: "find and replace") { options.replacements.remove(at: index) }
            }
        }
        Toggle("Regular expression", isOn: binding.useRegex)
            .accessibilityLabel("Regular expression\(number)")
        if binding.wrappedValue.useRegex, let error = NameReplacement.regexError(binding.wrappedValue.find) {
            Text(error)
                .font(LadaGlass.Typography.label)
                .foregroundStyle(LadaGlass.Colors.badText)
        }
    }

    private func addRule(after index: Int) {
        let new = ReplacementRule()
        options.replacements.insert(new, at: min(index + 1, options.replacements.count))
        focusedRule = new.id
    }
}
