import SwiftUI
import ImageconverterCore

struct SidebarView: View {
    @Bindable var model: AppModel
    var settings: AppSettings
    @State private var targeted = false
    #if DEBUG
    /// `-debugShowReport` starts with the Report section open (screenshots).
    @State private var showReport = CommandLine.arguments.contains("-debugShowReport")
    #else
    @State private var showReport = false
    #endif
    @State private var showErrorLog = false
    /// The measured natural content height (panel plus paddings), for the scroller decision.
    @State private var contentHeight: CGFloat = 0

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
                // While the window animates to a new height (or at the minimum height) the panel fills it.
                .frame(minHeight: max(viewport.size.height - Self.verticalChrome, 0), alignment: .top)
                .lgPanel()
                .padding(LadaGlass.Spacing.m)
            }
            // The window is as tall as the content, so a scroller only belongs when the content is taller
            // than the screen allows; never while the window animates (it would flash in and out).
            .scrollIndicators(showsScroller(viewport: viewport.size.height) ? .automatic : .never)
            .scrollBounceBehavior(.basedOnSize)
        }
        .onPreferenceChange(SidebarContentHeightKey.self) {
            contentHeight = $0
            model.windowSizer.contentHeightChanged($0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .lgBackdrop()
        .lgCompact()
        .lgToasts(model.toasts)
    }

    private func showsScroller(viewport: CGFloat) -> Bool {
        !model.windowSizer.isAnimating && contentHeight > viewport + 0.5
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
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            HStack {
                LGChip("\(model.items.count) \(model.items.count == 1 ? "image" : "images")", status: .neutral)
                Spacer()
                Button("Clear") { model.clear() }
                    .buttonStyle(.lg(.ghost))
                    .disabled(model.items.isEmpty || model.isRunning)
                    .accessibilityLabel("Clear the image list")
            }
            PrivacyChip(model: model)
        }
    }

    @ViewBuilder private var runSection: some View {
        if model.isRunning {
            // With the preview open, the progress area sits in the pane instead.
            if model.previewCollapsed { RunProgressArea(model: model) }
        } else {
            Button("Run on \(model.items.count) \(model.items.count == 1 ? "image" : "images")") {
                model.run(settings: settings)
            }
            .buttonStyle(.lg(.primary))
            .disabled(model.items.isEmpty || model.isAdding)
            .accessibilityLabel("Run the conversion")
            // The last run's numbers stay here when the preview is hidden.
            if model.previewCollapsed, model.monitor.hasResults { PerformancePanel(model: model) }
        }
    }

    /// Totals, then failures, notes and one row per written file. Stays until the next run or Clear.
    @ViewBuilder private var reportSection: some View {
        if let report = model.runReport {
            let summary = report.summary
            DisclosureGroup(reportTitle(summary, report), isExpanded: $showReport) {
                ReportCards(summary: summary)
                HStack {
                    ReportExportMenu(report: report)
                    Button("Show error log") { showErrorLog = true }
                        .buttonStyle(.lg(.ghost))
                        .accessibilityLabel("Show the error log")
                    Spacer()
                }
                LazyVStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
                    ForEach(Array(report.entries.enumerated()), id: \.offset) { _, entry in
                        reportRow(entry)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(LadaGlass.Typography.body)
            .accessibilityLabel("Report")
            .sheet(isPresented: $showErrorLog) { ErrorLogView() }
        }
    }

    private func reportTitle(_ summary: RunSummary, _ report: ProcessingReport) -> String {
        var parts = ["\(summary.succeeded) written"]
        if summary.skipped > 0 { parts.append("\(summary.skipped) skipped by \(summary.skipped == 1 ? "a condition" : "conditions")") }
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        let notes = report.entries.filter { $0.status == .succeeded && $0.note != nil }.count
        if notes > 0 { parts.append("\(notes) \(notes == 1 ? "note" : "notes")") }
        return "Report · " + parts.joined(separator: ", ")
    }

    private func reportRow(_ entry: ReportEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entry.name).font(LadaGlass.Typography.body).lineLimit(1).truncationMode(.middle)
            if entry.status == .failed {
                Text(entry.note ?? "Failed").font(LadaGlass.Typography.label)
                    .foregroundStyle(LadaGlass.Colors.badText)
            } else if entry.status == .skipped {
                // Left alone on purpose: not a failure, so not red.
                Text(entry.note ?? ConditionalStep.skippedReason).font(LadaGlass.Typography.label)
                    .foregroundStyle(LadaGlass.Colors.muted)
            } else {
                let change = entry.inputBytes.flatMap { input in
                    entry.outputBytes.flatMap { SizeFormat.percentChange(from: input, to: $0) }
                }
                Text("\(entry.inputBytes.map(SizeFormat.bytes) ?? "—") → \(entry.outputBytes.map(SizeFormat.bytes) ?? "—")"
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
