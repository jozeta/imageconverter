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
    /// The natural heights of the sidebar's parts, as last measured.
    @State private var parts: [SidebarPart: CGFloat] = [:]
    /// The window content height on screen: animated towards `WindowSizer.targetHeight` with
    /// `SidebarMotion`; the window follows it frame by frame. Nil before the first measurement.
    @State private var shownHeight: CGFloat?

    private static let panelPadding = LadaGlass.Spacing.l * LadaGlass.Density.paddingScale
    private static let outerPadding = LadaGlass.Spacing.m
    /// Panel padding plus the outer padding, top and bottom.
    private static let verticalChrome = 2 * panelPadding + 2 * outerPadding

    private var sizer: WindowSizer { model.windowSizer }

    var body: some View {
        GeometryReader { viewport in
            let inner = viewport.size.height - Self.verticalChrome
            // Below this the sidebar scrolls as a whole (only when even the collapsed content doesn't fit).
            let minimum = (parts[.top] ?? 0) + LadaGlass.Spacing.m + (parts[.bottom] ?? 0)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
                        PresetBar(model: model)
                        dropZone
                        pipelineHandle
                        countRow
                        PipelineHeader(model: model)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .measured(.top)
                    if !model.pipelineCollapsed || sizer.pipelineReveal > 0 { pipelineArea }
                    VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
                        runSection
                        reportSection
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .measured(.bottom)
                    .padding(.top, LadaGlass.Spacing.m)
                }
                // Laid out in the window as it is at this frame: Output and Run at the bottom.
                .frame(height: max(inner, minimum), alignment: .top)
                .padding(Self.panelPadding)
                .lgPanel(padding: 0)
                .padding(Self.outerPadding)
            }
            .scrollIndicators(!sizer.isAnimating && minimum > inner + 0.5 ? .automatic : .never)
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color.clear.modifier(SidebarHeightReporter(height: shownHeight ?? 0)))
        .onPreferenceChange(SidebarPartHeightsKey.self) { heights in
            parts = heights
            sizer.sidebarMeasured(sidebarParts(heights), collapsed: model.pipelineCollapsed)
        }
        .onChange(of: model.pipelineCollapsed) { _, collapsed in
            // Expanding mounts the steps and Output: their measurement (just above) carries the change.
            // Collapsing (or expanding again mid-collapse) changes no measured height, so tell the sizer here.
            guard collapsed || parts[.output] != nil else { return }
            sizer.sidebarMeasured(sidebarParts(parts), collapsed: collapsed)
        }
        .onChange(of: sizer.targetHeight) { _, height in
            guard let height else { return }
            if sizer.targetAnimates, let animation = SidebarMotion.animation {
                withAnimation(animation) { shownHeight = height }
            } else {
                shownHeight = height
            }
        }
        .onPreferenceChange(SidebarShownHeightKey.self) { height in
            if height > 0 { sizer.sidebarShown(height) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .lgBackdrop()
        .lgCompact()
        .lgToasts(model.toasts)
        #if DEBUG
        .task { await debugTogglePipelineLoop() }
        .task { debugWindowHeight() }
        #endif
    }

    /// The pipeline steps (scrolling when the window is shorter than them, with any extra height as empty
    /// room under them), a fixed gap, and Output. Shrinks to nothing from the bottom up while the
    /// pipeline collapses, and grows back while it expands, with the window edge.
    private var pipelineArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                PipelineSection(model: model)
                    .fixedSize(horizontal: false, vertical: true)
                    .measured(.steps)
                    // Room for the rows' focus rings and shadows, which the scroll view would clip.
                    .padding(.horizontal, Self.panelPadding)
            }
            .padding(.horizontal, -Self.panelPadding)
            .scrollIndicators(sizer.isAnimating ? .never : .automatic)
            .scrollBounceBehavior(.basedOnSize)
            // All the room between the header and Output, so rows that animate out (an editor closing, a
            // step removed) are never cut off by a list that already has its new, smaller height.
            .frame(maxHeight: .infinity)
            // The fixed gap above Output (Johan); extra window height shows as empty list space above it.
            .padding(.bottom, LadaGlass.Spacing.m)
            OutputPanel(model: model, settings: settings)
                .fixedSize(horizontal: false, vertical: true)
                .measured(.output)
        }
        .padding(.top, LadaGlass.Spacing.xs)
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipShape(BottomEdgeClip())
    }

    private func sidebarParts(_ heights: [SidebarPart: CGFloat]) -> WindowLayout.SidebarParts {
        WindowLayout.SidebarParts(top: heights[.top] ?? 0, steps: heights[.steps] ?? 0, output: heights[.output] ?? 0,
                                  bottom: heights[.bottom] ?? 0, chrome: Self.verticalChrome,
                                  stepsGap: LadaGlass.Spacing.xs, spacing: LadaGlass.Spacing.m)
    }

    #if DEBUG
    /// `-debugTogglePipelineEvery <seconds>` collapses and expands the pipeline over and over (animation checks).
    private func debugTogglePipelineLoop() async {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-debugTogglePipelineEvery"), index + 1 < arguments.count,
              let seconds = Double(arguments[index + 1]), seconds > 0 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(seconds))
            model.togglePipeline()
        }
    }

    /// `-debugWindowHeight <points>`: the expanded window as if the user had resized it to that height.
    private func debugWindowHeight() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-debugWindowHeight"), index + 1 < arguments.count,
              let height = Double(arguments[index + 1]) else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            sizer.debugRemember(height: CGFloat(height))
        }
    }
    #endif

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
            // Not while a run is in progress (same as the window-level drop target).
            guard !model.isRunning else { return false }
            model.add(urls)
            return !urls.isEmpty
        } isTargeted: { targeted = $0 && !model.isRunning }
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

/// The sidebar's parts whose natural heights decide the window height (see `WindowLayout.SidebarParts`).
enum SidebarPart: Hashable {
    case top, steps, output, bottom
}

/// The measured natural heights of the sidebar's parts.
private struct SidebarPartHeightsKey: PreferenceKey {
    static let defaultValue: [SidebarPart: CGFloat] = [:]
    static func reduce(value: inout [SidebarPart: CGFloat], nextValue: () -> [SidebarPart: CGFloat]) {
        value.merge(nextValue()) { max($0, $1) }
    }
}

private extension View {
    /// Reports this view's height as `part`.
    func measured(_ part: SidebarPart) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: SidebarPartHeightsKey.self, value: [part: proxy.size.height])
            }
        }
    }
}
