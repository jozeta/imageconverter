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
                .stepHelp(title == "Rename" ? .rename : .metadata)
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
