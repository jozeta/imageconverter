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
    let remove: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        AccordionCard(isExpanded: $isExpanded, canExpand: isEnabled, title: title) {
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
                .stepHelp(title == "Rename" ? .rename : .metadata)
                Spacer(minLength: 0)
                RemoveStepButton(label: title, action: remove)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
            .contextMenu { Button("Remove", role: .destructive, action: remove) }
        } content: {
            VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) { content }
        }
    }
}
