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
                // A shown proxy says "Refining…" in the header instead of covering the image.
                .overlay { if model.isRenderingPreview, !model.showsPreviewProxy { spinner } }
                .overlay { if !model.previewAllowed { pausedNote } }
                .modifier(HistogramCorner(model: model))
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
                // The bottom handle (pipeline collapse) is a compact mode: the details and thumbnails go too,
                // shrinking and growing with the window edge (`pipelineReveal`) instead of jumping.
                let reveal = model.windowSizer.pipelineReveal
                if !model.pipelineCollapsed || reveal > 0 {
                    VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
                        infoTable
                        BatchBrowser(model: model)
                    }
                    .padding(.top, -LadaGlass.Spacing.m * (1 - reveal))
                    .modifier(RevealModifier(progress: reveal))
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
        .task(id: model.altTextRequest) { await model.generatePreviewAltText(for: model.altTextRequest) }
        .task(id: model.ladderCropKey) { await model.recropLadder(for: model.ladderCropKey) }
        .task(id: model.clippingKey) { await model.renderClippingMask(for: model.clippingKey) }
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
                HistogramToggle(model: model)
                InspectorToggle(model: model)
            }
            VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
                HStack { titleRow; Spacer(); HistogramToggle(model: model); InspectorToggle(model: model) }
                HStack(spacing: LadaGlass.Spacing.s) { compareControls(segmented: true); Spacer() }
            }
            VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
                HStack { titleRow; Spacer(); HistogramToggle(model: model); InspectorToggle(model: model) }
                HStack(spacing: LadaGlass.Spacing.s) { compareControls(segmented: false); Spacer() }
            }
        }
    }

    private var titleRow: some View {
        HStack(spacing: LadaGlass.Spacing.s) {
            Text("Preview").font(LadaGlass.Typography.subtitle)
            if let target = model.previewDetecting {
                PreviewStatus(text: target.findingStatus)
            } else if model.showsPreviewProxy {
                PreviewStatus(text: "Refining…")
                    .help("A quick preview from a smaller copy; the full-size result replaces it in a moment")
            }
            conditionChips
            if model.previewFailure == nil, let note = model.previewResult?.redactSizeNote {
                LGChip(note, status: .warn)
                    .lineLimit(1)
                    .help("\(note). The Redact step was saved with a size in pixels; move its slider to switch to "
                          + "Blocks across or Strength.")
            }
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
        .disabled(model.items.isEmpty)
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
                        HStack(spacing: LadaGlass.Spacing.xs) {
                            cell(result?.outputName ?? "—")
                            if let extras = result?.extraOutputNames, !extras.isEmpty { extraOutputsChip(extras) }
                        }
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
                    GridRow {
                        label("Privacy")
                        privacyCell(model.privacy.findings[source].map(PrivacySummary.line) ?? "Scanning…",
                                    findings: model.privacy.findings[source])
                        privacyCell(failed ? "—" : resultPrivacy(estimate),
                                    findings: failed ? nil : estimate?.full?.privacy)
                    }
                    if !failed, let request = result?.altTextRequest {
                        PreviewAltTextRow(state: model.previewAltText?.key == request.key ? model.previewAltText?.state : nil)
                    }
                }
            }
            .textSelection(.enabled)
        }
    }

    /// What the output keeps, from the scan of the encoded bytes the estimate made.
    private func resultPrivacy(_ estimate: SizeEstimate?) -> String {
        guard let estimate else { return model.estimateFailed ? "—" : "Estimating…" }
        guard let privacy = estimate.full?.privacy else { return "—" }
        return PrivacySummary.line(privacy)
    }

    private func privacyCell(_ text: String, findings: PrivacyFindings?) -> some View {
        Text(text)
            .font(LadaGlass.Typography.mono)
            .foregroundStyle(findings?.highestSeverity?.color ?? LadaGlass.Colors.text)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(text)
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

    /// "+2 outputs"; hovering lists them.
    private func extraOutputsChip(_ names: [String]) -> some View {
        let label = "+\(names.count) \(names.count == 1 ? "output" : "outputs")"
        return LGChip(label)
            .fixedSize()
            .help(names.joined(separator: "\n"))
            .accessibilityLabel("\(label): \(names.joined(separator: ", "))")
    }
}

extension PreviewPane {
    fileprivate func cell(_ text: String, muted: Bool = false) -> some View {
        Text(text)
            .font(muted ? LadaGlass.Typography.label : LadaGlass.Typography.mono)
            .foregroundStyle(muted ? LadaGlass.Colors.muted : LadaGlass.Colors.text)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    fileprivate func folderCell(_ url: URL) -> some View {
        let path = url.path
        return Text(path)
            .font(LadaGlass.Typography.mono)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
    }

    fileprivate func label(_ text: String) -> some View {
        Text(text).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
    }
}

/// The preview header's status while the preview waits for a Redact step's detection (seconds on a large image
/// with text).
/// A quiet status in the preview header while it works: "Finding faces and text…", "Refining…".
private struct PreviewStatus: View {
    let text: String

    var body: some View {
        HStack(spacing: LadaGlass.Spacing.xs) {
            ProgressView().controlSize(.small).scaleEffect(0.8)
            Text(text)
                .font(LadaGlass.Typography.body)
                .foregroundStyle(LadaGlass.Colors.muted)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}
