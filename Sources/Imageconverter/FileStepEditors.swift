import SwiftUI
import ImageconverterCore

// MARK: - Row

/// An accordion row for a file step (Metadata, Rename): toggle, title and summary like an image step,
/// but fixed in place, so no drag handle and no actions menu.
struct FileStepRow<Content: View>: View {
    let title: String
    let summary: String
    @Binding var isEnabled: Bool
    @Binding var isExpanded: Bool
    /// When set, the row is greyed out, its toggle shows off and it can't be expanded. The stored
    /// `isEnabled` is left alone so unlocking restores it.
    var lockedHelp: String?
    let remove: () -> Void
    @ViewBuilder var content: Content

    private var locked: Bool { lockedHelp != nil }
    private var shownEnabled: Bool { isEnabled && !locked }

    var body: some View {
        AccordionCard(isExpanded: $isExpanded, canExpand: shownEnabled, title: title) {
            HStack(spacing: LadaGlass.Spacing.s) {
                Toggle("Enabled", isOn: locked ? .constant(false) : $isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(locked)
                    .accessibilityLabel("\(title) enabled")
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(LadaGlass.Typography.subtitle)
                    Text(lockedHelp ?? summary)
                        .font(LadaGlass.Typography.label)
                        .foregroundStyle(LadaGlass.Colors.muted)
                        .lineLimit(1)
                }
                .help(lockedHelp ?? "")
                Spacer(minLength: 0)
                RemoveStepButton(label: title, action: remove)
            }
            .opacity(shownEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
            .contextMenu { Button("Remove", role: .destructive, action: remove) }
        } content: {
            VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) { content }
        }
    }
}

// MARK: - Metadata

struct MetadataEditor: View {
    @Binding var options: MetadataOptions

    var body: some View {
        Toggle("Remove all metadata", isOn: $options.removeAll)
            .accessibilityLabel("Remove all metadata")
        Toggle("Remove location (GPS)", isOn: options.removeAll ? .constant(true) : $options.removeLocation)
            .disabled(options.removeAll)
            .accessibilityLabel("Remove location (GPS)")
        Toggle("Remove camera details", isOn: options.removeAll ? .constant(true) : $options.removeCamera)
            .disabled(options.removeAll)
            .accessibilityLabel("Remove camera details")
        Divider()
        SetFieldRow(title: "Artist", text: $options.artist)
        SetFieldRow(title: "Copyright", text: $options.copyright)
        SetFieldRow(title: "Description", text: $options.description)
        Text("The color profile is always kept.")
            .font(LadaGlass.Typography.label)
            .foregroundStyle(LadaGlass.Colors.muted)
    }
}

/// "Set <field>": a toggle and a text field. Ticked with empty text removes the field; the typed
/// text is kept in a draft so unticking and reticking does not lose it.
private struct SetFieldRow: View {
    let title: String
    @Binding var text: String?
    @State private var draft = ""

    var body: some View {
        FieldRow {
            Toggle("Set \(title.lowercased())", isOn: Binding(
                get: { text != nil },
                set: { text = $0 ? draft : nil }))
                .accessibilityLabel("Set \(title.lowercased())")
            TextField(title, text: Binding(get: { text ?? draft }, set: { draft = $0; text = $0 }),
                      prompt: Text("Leave empty to remove"))
                .textFieldStyle(.roundedBorder)
                .disabled(text == nil)
                .accessibilityLabel(title)
        }
        .onAppear { draft = text ?? "" }
        // A preset switch or reset can set the text from outside; keep the draft in step.
        .onChange(of: text) { _, new in
            if let new, new != draft { draft = new }
        }
    }
}

// MARK: - Rename

struct RenameEditor: View {
    @Binding var options: RenameOptions
    let example: String

    private var unknown: [String] { RenameTemplate(options.pattern).unknownTokens }

    var body: some View {
        FieldRow {
            TextField("Pattern", text: $options.pattern)
                .textFieldStyle(.roundedBorder)
                .font(LadaGlass.Typography.mono)
                .accessibilityLabel("Rename pattern")
            Menu("Insert token") {
                ForEach(RenameTemplate.tokenExamples, id: \.self) { token in
                    Button(token) { options.pattern += token }
                }
            }
            .fixedSize()
            .accessibilityLabel("Insert token")
        }
        FieldRow {
            TextField("Find", text: $options.findText)
                .textFieldStyle(.roundedBorder)
                .font(LadaGlass.Typography.mono)
                .accessibilityLabel("Find in name")
            TextField("Replace with", text: $options.replaceText)
                .textFieldStyle(.roundedBorder)
                .font(LadaGlass.Typography.mono)
                .accessibilityLabel("Replace with")
        }
        Toggle("Regular expression", isOn: $options.useRegex)
            .accessibilityLabel("Regular expression")
        if options.useRegex, !options.findText.isEmpty, let error = NameReplacement.regexError(options.findText) {
            Text(error)
                .font(LadaGlass.Typography.label)
                .foregroundStyle(LadaGlass.Colors.badText)
        }
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
}
