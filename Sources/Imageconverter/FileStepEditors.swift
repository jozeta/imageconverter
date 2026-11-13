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
    @ViewBuilder var content: Content

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) { content }
                .padding(.top, LadaGlass.Spacing.s)
        } label: {
            HStack(spacing: LadaGlass.Spacing.s) {
                Toggle("Enabled", isOn: $isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .accessibilityLabel("\(title) enabled")
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(LadaGlass.Typography.subtitle)
                    Text(summary)
                        .font(LadaGlass.Typography.label)
                        .foregroundStyle(LadaGlass.Colors.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .font(LadaGlass.Typography.body)
        .padding(LadaGlass.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lgSurface()
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
            .accessibilityLabel("Remove location")
        Toggle("Remove camera details", isOn: options.removeAll ? .constant(true) : $options.removeCamera)
            .disabled(options.removeAll)
            .accessibilityLabel("Remove camera details")
        Divider()
        setRow("Artist", text: $options.artist)
        setRow("Copyright", text: $options.copyright)
        setRow("Description", text: $options.description)
        Text("The color profile is always kept.")
            .font(LadaGlass.Typography.label)
            .foregroundStyle(LadaGlass.Colors.muted)
    }

    private func setRow(_ title: String, text: Binding<String?>) -> some View {
        FieldRow {
            Toggle("Set \(title.lowercased())", isOn: Binding(
                get: { text.wrappedValue != nil },
                set: { text.wrappedValue = $0 ? (text.wrappedValue ?? "") : nil }))
                .accessibilityLabel("Set \(title.lowercased())")
            TextField(title, text: Binding(get: { text.wrappedValue ?? "" }, set: { text.wrappedValue = $0 }))
                .textFieldStyle(.roundedBorder)
                .disabled(text.wrappedValue == nil)
                .accessibilityLabel(title)
        }
    }
}

// MARK: - Rename

struct RenameEditor: View {
    @Binding var options: RenameOptions
    let example: String

    /// The insert-token menu entries; formatted tokens show an example format.
    static let tokens = [
        "{name}", "{ext}", "{date:yyyy-MM-dd}", "{time:HHmmss}", "{camera}", "{make}", "{lens}", "{iso}",
        "{width}", "{height}", "{format}", "{folder}", "{counter:000}",
    ]

    private var unknown: [String] { RenameTemplate(options.pattern).unknownTokens }

    var body: some View {
        FieldRow {
            TextField("Pattern", text: $options.pattern)
                .textFieldStyle(.roundedBorder)
                .font(LadaGlass.Typography.mono)
                .accessibilityLabel("Rename pattern")
            Menu("Insert token") {
                ForEach(Self.tokens, id: \.self) { token in
                    Button(token) { options.pattern += token }
                }
            }
            .fixedSize()
            .accessibilityLabel("Insert token")
        }
        NumberField(title: "Counter starts at", value: $options.counterStart, minimum: 0, suffix: "")
        if !unknown.isEmpty {
            Text(unknown.map { "Unknown token: {\($0)}" }.joined(separator: " · "))
                .font(LadaGlass.Typography.label)
                .foregroundStyle(LadaGlass.Colors.warnText)
        }
        Text(example)
            .font(LadaGlass.Typography.mono)
            .foregroundStyle(LadaGlass.Colors.muted)
            .lineLimit(2)
            .textSelection(.enabled)
            .accessibilityLabel(example)
    }
}
