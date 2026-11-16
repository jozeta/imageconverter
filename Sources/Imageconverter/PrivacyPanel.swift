import SwiftUI
import ImageconverterCore

extension PrivacySeverity {
    var chipStatus: LGChip.Status {
        switch self {
        case .high: return .bad
        case .medium: return .warn
        case .low: return .neutral
        }
    }

    var label: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    var color: Color {
        switch self {
        case .high: return LadaGlass.Colors.badText
        case .medium: return LadaGlass.Colors.warnText
        case .low: return LadaGlass.Colors.muted
        }
    }
}

/// The shield chip in the count row; it opens the panel with what the scan found.
struct PrivacyChip: View {
    let model: AppModel
    @Bindable private var state: PrivacyState

    init(model: AppModel) {
        self.model = model
        state = model.privacy
    }

    var body: some View {
        if !model.items.isEmpty, let chip = model.privacyChip {
            Button { model.privacy.showsPanel.toggle() } label: {
                HStack(spacing: LadaGlass.Spacing.xs) {
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundStyle(chip.severity.color)
                        .accessibilityHidden(true)
                    LGChip(chip.text, status: chip.severity.chipStatus)
                }
            }
            .buttonStyle(.plain)
            .help("Show what the privacy scan found")
            .accessibilityLabel("Privacy: \(chip.text). Show details")
            #if DEBUG
            .onAppear { if CommandLine.arguments.contains("-debugShowPrivacyPanel") { model.privacy.showsPanel = true } }
            #endif
            .popover(isPresented: $state.showsPanel, arrowEdge: .bottom) {
                PrivacyPanel(model: model)
            }
        }
    }
}

/// Findings per image with a one-click way to switch the Metadata step to removing them.
struct PrivacyPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
            Text("Privacy scan").font(LadaGlass.Typography.subtitle)
            Text(model.privacy.looksForContent ? ContentPrivacySummary.headerWithContent
                                               : ContentPrivacySummary.headerMetadataOnly)
                .font(LadaGlass.Typography.label)
                .foregroundStyle(LadaGlass.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
                    ForEach(model.privacyRows) { row in
                        PrivacyRowView(model: model, row: row)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            PrivacyContentSection(model: model)
            HStack {
                Button("Remove these from the output") {
                    model.removeFoundPrivacyData()
                    model.privacy.showsPanel = false
                }
                .buttonStyle(.lg(.primary))
                .disabled(model.isRunning || model.privacyRows.isEmpty)
                .accessibilityLabel("Remove these from the output")
                .help("Turns on the Metadata step with the matching removals; removals you already set stay on")
                Spacer()
            }
        }
        .padding(LadaGlass.Spacing.l)
        .frame(width: 420)
    }
}

/// The opt-in content check: a toggle, then what it found with a button that adds a Redact step for it.
private struct PrivacyContentSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            Toggle(ContentPrivacySummary.toggleTitle, isOn: Binding(
                get: { model.privacy.looksForContent }, set: { model.setLooksForContent($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(ContentPrivacySummary.toggleHelp)
                .accessibilityHint(ContentPrivacySummary.toggleHelp)
            ForEach(model.privacyContentLines, id: \.text) { line in
                // Two rows, so neither the finding nor the button is cut off in the narrow panel.
                VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
                    HStack(spacing: LadaGlass.Spacing.s) {
                        LGChip(line.target == nil ? "Unchecked" : "Medium", status: .warn)
                        Text(line.text).font(LadaGlass.Typography.label)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let target = line.target {
                        Button("Add a Redact step") { model.addSuggestedRedaction(target) }
                            .buttonStyle(.lg(.secondary))
                            .controlSize(.small)
                            .disabled(model.isRunning)
                            .help("Adds a Redact step for \(target.displayName.lowercased()); nothing runs until you press Run")
                            .accessibilityLabel("Add a Redact step for \(line.text)")
                    }
                }
            }
        }
    }
}

/// One image's findings: the image name links to its metadata (selects it, shows it in the preview and opens the
/// metadata panel at the first finding), and each value found links to its own row there.
private struct PrivacyRowView: View {
    let model: AppModel
    let row: AppModel.PrivacyRow

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            Button { show(firstPath) } label: {
                Label(row.item.source.lastPathComponent, systemImage: "arrow.up.forward.square")
                    .font(LadaGlass.Typography.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.link)
            .help("Select this image and show its metadata")
            .accessibilityLabel("Show the metadata of \(row.item.source.lastPathComponent)")
            ForEach(row.findings.findings, id: \.kind) { finding in
                HStack(alignment: .firstTextBaseline, spacing: LadaGlass.Spacing.s) {
                    LGChip(finding.severity.label, status: finding.severity.chipStatus)
                    VStack(alignment: .leading, spacing: LadaGlass.Spacing.xxs) {
                        Text(finding.kind.title).font(LadaGlass.Typography.label)
                        if finding.details.isEmpty {
                            Text(finding.fields.joined(separator: ", "))
                                .font(LadaGlass.Typography.label)
                                .foregroundStyle(LadaGlass.Colors.muted)
                        }
                        ForEach(finding.details, id: \.self) { detail in detailRow(detail) }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(finding.severity.label): \(finding.kind.title)")
            }
        }
    }

    private var firstPath: MetadataPath? {
        row.findings.findings.lazy.flatMap(\.details).compactMap(\.path).first
    }

    private func show(_ path: MetadataPath?) { model.showMetadata(of: row.item.source, at: path) }

    /// "Body serial number: SN 123…": the value is untrusted text (escaped and shortened by Core), in full on hover.
    @ViewBuilder private func detailRow(_ detail: PrivacyDetail) -> some View {
        let line = Text(detail.field + ": ").foregroundStyle(LadaGlass.Colors.muted) + Text(detail.value)
        if let path = detail.path {
            Button { show(path) } label: {
                line.font(LadaGlass.Typography.label).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help(detail.value + " — click to show it in the metadata panel")
            .accessibilityLabel("\(detail.field): \(detail.value)")
            .accessibilityHint("Shows it in the metadata panel")
        } else {
            line.font(LadaGlass.Typography.label).lineLimit(1).truncationMode(.tail)
                .help(detail.value)
        }
    }
}

/// Help ▸ Privacy…: what the app does with your files, and the limits it enforces on untrusted input.
struct PrivacyWindow: View {
    static let windowID = "privacy"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
                Text("Privacy").font(LadaGlass.Typography.title)
                Text(PrivacyStatement.offline).font(LadaGlass.Typography.body)
                Text(PrivacyStatement.updates).font(LadaGlass.Typography.body)
                    .fixedSize(horizontal: false, vertical: true)
                Text(PrivacyStatement.enlargeModel).font(LadaGlass.Typography.body)
                    .fixedSize(horizontal: false, vertical: true)
                Text(PrivacyStatement.altText).font(LadaGlass.Typography.body)
                    .fixedSize(horizontal: false, vertical: true)
                Text(PrivacyStatement.frameworks).font(LadaGlass.Typography.body)
                section("What the privacy scan looks for") {
                    ForEach(PrivacyStatement.scanLooks, id: \.self) { Text("• \($0)") }
                }
                section("Limits in force") {
                    Grid(alignment: .leading, horizontalSpacing: LadaGlass.Spacing.l, verticalSpacing: LadaGlass.Spacing.xs) {
                        ForEach(PrivacyStatement.limits(), id: \.name) { limit in
                            GridRow {
                                Text(limit.name).foregroundStyle(LadaGlass.Colors.muted)
                                Text(limit.value).font(LadaGlass.Typography.mono)
                            }
                        }
                    }
                }
                section("Temporary files") { Text(PrivacyStatement.tempFiles) }
            }
            .font(LadaGlass.Typography.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(LadaGlass.Spacing.l)
        }
        .frame(minWidth: 420, minHeight: 360)
        .lgBackdrop()
        .lgCompact()
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            Text(title).font(LadaGlass.Typography.subtitle)
            content()
        }
    }
}

struct PrivacyCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Privacy…") { openWindow(id: PrivacyWindow.windowID) }
        }
    }
}
