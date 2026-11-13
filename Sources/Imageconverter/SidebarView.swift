import SwiftUI
import ImageconverterCore

struct SidebarView: View {
    @Bindable var model: AppModel
    var settings: AppSettings
    @State private var targeted = false
    @State private var showReport = false

    /// Panel padding plus the outer padding, top and bottom.
    private static let verticalChrome = 2 * LadaGlass.Spacing.l * LadaGlass.Density.paddingScale
        + 2 * LadaGlass.Spacing.m

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
                    PresetBar(model: model)
                    dropZone
                    pipelineHandle
                    countRow
                    PipelineSection(model: model, settings: settings)
                    runSection
                    reportSection
                }
                // The natural height (not the stretched one), so the measurement never feeds back on the window.
                .background {
                    GeometryReader {
                        Color.clear.preference(key: SidebarContentHeightKey.self,
                                               value: $0.size.height + Self.verticalChrome)
                    }
                }
                // With the preview open the window can be taller than the content: the panel fills it.
                .frame(minHeight: max(viewport.size.height - Self.verticalChrome, 0), alignment: .top)
                .lgPanel()
                .padding(LadaGlass.Spacing.m)
            }
        }
        .onPreferenceChange(SidebarContentHeightKey.self) { model.windowSizer.contentHeightChanged($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .lgBackdrop()
        .lgCompact()
        .lgToasts(model.toasts)
    }

    /// Collapses or expands the pipeline (Johan: between the drop zone and the image count).
    private var pipelineHandle: some View {
        let collapsed = model.pipelineCollapsed
        return EdgeHandle(edge: .bottom, pointsOutward: collapsed,
                          label: collapsed ? "Expand pipeline" : "Collapse pipeline") { model.togglePipeline() }
            .frame(maxWidth: .infinity)
    }

    private var dropZone: some View {
        VStack(spacing: LadaGlass.Spacing.s) {
            Text(model.isAdding ? "Adding…" : "Drop images or folders here")
                .font(LadaGlass.Typography.body)
                .foregroundStyle(LadaGlass.Colors.muted)
                .multilineTextAlignment(.center)
            Button("Add…") { model.chooseInputs() }
                .buttonStyle(.lg(.secondary))
                .accessibilityLabel("Add images or folders")
        }
        .frame(maxWidth: .infinity)
        .padding(LadaGlass.Spacing.l)
        .lgSurface()
        .overlay(
            RoundedRectangle(cornerRadius: LadaGlass.Radius.card)
                .strokeBorder(targeted ? LadaGlass.accent.color : LadaGlass.Colors.border,
                              style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return !urls.isEmpty
        } isTargeted: { targeted = $0 }
    }

    private var countRow: some View {
        HStack {
            LGChip("\(model.items.count) \(model.items.count == 1 ? "image" : "images")", status: .neutral)
            Spacer()
            Button("Clear") { model.clear() }
                .buttonStyle(.lg(.ghost))
                .disabled(model.items.isEmpty || model.isRunning)
                .accessibilityLabel("Clear the image list")
        }
    }

    @ViewBuilder private var runSection: some View {
        if model.isRunning {
            VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
                if model.previewCollapsed, let progress = model.progress {
                    ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                        .accessibilityLabel("Conversion progress")
                    Text("\(progress.completed) / \(progress.total)")
                        .font(LadaGlass.Typography.mono)
                }
                // With the preview open, Cancel sits next to the progress bar in the pane instead.
                if model.previewCollapsed {
                    Button("Cancel") { model.cancel() }
                        .buttonStyle(.lg(.secondary))
                        .accessibilityLabel("Cancel the conversion")
                }
            }
        } else {
            Button("Run on \(model.items.count) \(model.items.count == 1 ? "image" : "images")") {
                model.run(settings: settings)
            }
            .buttonStyle(.lg(.primary))
            .disabled(model.items.isEmpty || model.isAdding)
            .accessibilityLabel("Run the conversion")
        }
    }

    /// Totals, then failures, notes and one row per written file. Stays until the next run or Clear.
    @ViewBuilder private var reportSection: some View {
        if let report = model.runReport {
            let summary = report.summary
            DisclosureGroup("Report", isExpanded: $showReport) {
                VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
                    Text(reportTotals(summary)).font(LadaGlass.Typography.label)
                        .foregroundStyle(LadaGlass.Colors.muted)
                    ForEach(Array(report.entries.enumerated()), id: \.offset) { _, entry in
                        reportRow(entry)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(LadaGlass.Typography.body)
            .accessibilityLabel("Report")
        }
    }

    private func reportTotals(_ summary: RunSummary) -> String {
        var parts = ["\(summary.succeeded) converted"]
        if summary.failed > 0 { parts.append("\(summary.failed) skipped") }
        if summary.cancelled > 0 { parts.append("\(summary.cancelled) not run") }
        if summary.succeeded > 0 {
            let change = SizeFormat.percentChange(from: summary.inputBytes, to: summary.outputBytes).map { " (\($0))" } ?? ""
            parts.append("\(SizeFormat.bytes(summary.inputBytes)) → \(SizeFormat.bytes(summary.outputBytes))\(change)")
        }
        return parts.joined(separator: " · ")
    }

    private func reportRow(_ entry: ReportEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entry.name).font(LadaGlass.Typography.body).lineLimit(1).truncationMode(.middle)
            if entry.status == .failed {
                Text(entry.note ?? "Skipped").font(LadaGlass.Typography.label)
                    .foregroundStyle(LadaGlass.Colors.badText)
            } else {
                let change = entry.outputBytes.flatMap { SizeFormat.percentChange(from: entry.inputBytes, to: $0) }
                Text("\(SizeFormat.bytes(entry.inputBytes)) → \(SizeFormat.bytes(entry.outputBytes ?? 0))"
                     + (change.map { " (\($0))" } ?? ""))
                    .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                if let note = entry.note {
                    Text(note).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.warnText)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The natural height of the sidebar's content plus its paddings; the window height follows it.
private struct SidebarContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
