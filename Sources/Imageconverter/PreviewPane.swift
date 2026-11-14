import SwiftUI
import ImageconverterCore

/// The right-hand pane: before and after of the selected image in the chosen comparison mode, what it is
/// renamed to, and the batch browser.
struct PreviewPane: View {
    @Bindable var model: AppModel
    /// Below this pane width the two images are stacked.
    static let stackedBelow: CGFloat = 560
    static let stageMinHeight: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
            header
            if model.items.isEmpty {
                Spacer()
                Text("Add images to see a preview")
                    .font(LadaGlass.Typography.body)
                    .foregroundStyle(LadaGlass.Colors.muted)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                GeometryReader { geometry in
                    ComparisonStage(model: model, stacked: geometry.size.width < Self.stackedBelow)
                }
                // Room for the image even while the progress area and a tall list share the pane.
                .frame(minHeight: Self.stageMinHeight)
                .overlay { if model.isRenderingPreview { spinner } }
                .overlay { if !model.previewAllowed { pausedNote } }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Before and after, \(model.compare.mode.title)")
                .accessibilityZoomAction { action in
                    switch action.direction {
                    case .zoomIn: model.zoom.zoomIn()
                    case .zoomOut: model.zoom.zoomOut()
                    }
                }
                if showsQualityPanel {
                    QualityPanel(model: model, stacked: narrow)
                }
                // Progress, Pause/Cancel and the Performance disclosure, directly above the table.
                RunProgressArea(model: model)
                // The bottom handle (pipeline collapse) is a compact mode: the details and thumbnails go too.
                if !model.pipelineCollapsed {
                    infoTable
                    BatchBrowser(model: model)
                }
            }
        }
        .background(GeometryReader { proxy in
            Color.clear.onChange(of: proxy.size.width < Self.stackedBelow, initial: true) { _, value in narrow = value }
        })
        .lgPanel()
        .padding(LadaGlass.Spacing.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .lgBackdrop()
        .lgCompact()
        .onChange(of: selectedSource, initial: true) { _, source in
            model.zoom.track(item: source)
            model.compare.selectionChanged()
        }
        .task(id: model.differenceKey) { await model.renderDifference(for: model.differenceKey) }
        .task(id: model.ladderKey) { await model.renderLadder(for: model.ladderKey) }
        .task(id: model.ladderCropKey) { await model.recropLadder(for: model.ladderCropKey) }
        // Single mode's Space/B monitor exists only while it can matter.
        .onChange(of: model.compare.mode == .single && !model.items.isEmpty, initial: true) { _, active in
            model.compare.setKeyMonitor(active: active)
        }
        .onDisappear { model.compare.setKeyMonitor(active: false) }
    }

    @State private var narrow = false

    private var supportsQuality: Bool { model.pipeline.output.format.supportsQuality }
    private var showsQualityPanel: Bool { model.compare.showsQuality && supportsQuality && !model.isRunning }

    private var selectedSource: URL? { model.selectedItemIndex.map { model.items[$0].source } }

    /// Title, chips and zoom on one row with the compare controls; in a narrow pane the controls go below.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: LadaGlass.Spacing.s) {
                titleRow
                Spacer(minLength: LadaGlass.Spacing.s)
                compareControls(segmented: true)
            }
            VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
                HStack { titleRow; Spacer() }
                HStack(spacing: LadaGlass.Spacing.s) { compareControls(segmented: true); Spacer() }
            }
            VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
                HStack { titleRow; Spacer() }
                HStack(spacing: LadaGlass.Spacing.s) { compareControls(segmented: false); Spacer() }
            }
        }
    }

    private var titleRow: some View {
        HStack(spacing: LadaGlass.Spacing.s) {
            Text("Preview").font(LadaGlass.Typography.subtitle)
            conditionChips
            if let percent = model.zoom.percent {
                LGChip("\(percent) %", status: .neutral)
                    .accessibilityLabel("Zoom \(percent) percent")
            }
        }
    }

    @ViewBuilder private func compareControls(segmented: Bool) -> some View {
        let picker = Picker("Compare", selection: Bindable(model.compare).mode) {
            ForEach(CompareMode.allCases) { Text($0.title).tag($0).help($0.help) }
        }
        .labelsHidden()
        .fixedSize()
        .help("How before and after are compared (⌘1…⌘4)")
        .accessibilityLabel("Compare")
        if segmented { picker.pickerStyle(.segmented) } else { picker.pickerStyle(.menu) }
        if supportsQuality, !model.items.isEmpty {
            Button(model.compare.showsQuality ? "Hide quality" : "Compare quality…") {
                model.compare.showsQuality.toggle()
            }
            .buttonStyle(.lg(.secondary))
            .fixedSize()
            .disabled(model.isRunning)
            .accessibilityLabel(model.compare.showsQuality ? "Hide the quality comparison" : "Compare quality")
        }
    }

    /// Which branch each condition takes for the shown image, and whether it is copied or skipped.
    @ViewBuilder private var conditionChips: some View {
        if let result = model.previewResult, model.previewFailure == nil,
           let conditions = model.previewConditions, !conditions.branches.isEmpty {
            let text = ConditionBranch.chipText(conditions.branches)
            LGChip(text, status: .neutral)
                .help("The pipeline this image gets from its conditions")
                .accessibilityLabel("Condition: \(text)")
            if let note = result.statusNote {
                LGChip(note, status: result.disposition == .skip ? .warn : .ok)
            }
        }
    }

    /// Low-memory mode and overwrite runs leave the preview alone while a batch runs.
    private var pausedNote: some View {
        Text("Preview paused during the run (\(model.monitor.overwriting ? "overwriting the originals" : "low-memory mode"))")
            .font(LadaGlass.Typography.body)
            .foregroundStyle(LadaGlass.Colors.muted)
            .padding(LadaGlass.Spacing.s)
            .lgSurface()
    }

    private var spinner: some View {
        ProgressView()
            .controlSize(.small)
            .padding(LadaGlass.Spacing.s)
            .lgSurface()
            .accessibilityLabel("Rendering the preview")
    }

    @ViewBuilder private var infoTable: some View {
        let result = model.previewResult
        let failed = model.previewFailure != nil
        let selected = model.selectedItemIndex.map { model.items[$0].source }
        let source = result?.source ?? selected
        // The previous result stays up until the next render lands, so only trust an estimate for this item.
        let estimate = model.sizeEstimate.flatMap { $0.item == source ? $0 : nil }
        if result != nil || failed {
            Grid(alignment: .leading, horizontalSpacing: LadaGlass.Spacing.m, verticalSpacing: LadaGlass.Spacing.xs) {
                GridRow {
                    Text("")
                    cell("Original", muted: true)
                    cell("Result", muted: true)
                }
                GridRow {
                    label("Name")
                    cell(result?.sourceName ?? model.previewFailureName ?? "—")
                    if let failure = model.previewFailure {
                        Text(failure).font(LadaGlass.Typography.mono)
                            .foregroundStyle(LadaGlass.Colors.warnText)
                            .lineLimit(2)
                    } else {
                        cell(result?.outputName ?? "—")
                    }
                }
                if let source {
                    GridRow {
                        label("Folder")
                        folderCell(source.deletingLastPathComponent())
                        if let result { folderCell(result.outputURL.deletingLastPathComponent()) } else { cell("—") }
                    }
                    GridRow {
                        label("Dimensions")
                        cell(result.map { "\($0.sourceSize.0) × \($0.sourceSize.1)" } ?? "—")
                        cell(failed ? "—" : result.map { "\($0.outputSize.0) × \($0.outputSize.1)" } ?? "—")
                    }
                    GridRow {
                        label("Size")
                        cell(Self.bytes(estimate?.original ?? result?.sourceFileSize
                                        ?? (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize))
                        cell(failed ? "—" : resultSize(estimate))
                    }
                }
            }
            .textSelection(.enabled)
        }
    }

    private func resultSize(_ estimate: SizeEstimate?) -> String {
        guard let estimate else { return model.estimateFailed ? "—" : "Estimating…" }
        guard let output = estimate.output, let original = estimate.original,
              let change = SizeFormat.percentChange(from: original, to: output)
        else { return Self.bytes(estimate.output) }
        return "\(Self.bytes(output))\(qualitySuffix(estimate.quality, mode: model.pipeline.output.compression)) (\(change))"
    }

    private static func bytes(_ count: Int?) -> String {
        guard let count else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
    }

    private func cell(_ text: String, muted: Bool = false) -> some View {
        Text(text)
            .font(muted ? LadaGlass.Typography.label : LadaGlass.Typography.mono)
            .foregroundStyle(muted ? LadaGlass.Colors.muted : LadaGlass.Colors.text)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func folderCell(_ url: URL) -> some View {
        let path = url.path
        return Text(path)
            .font(LadaGlass.Typography.mono)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
    }
}
