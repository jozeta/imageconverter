import SwiftUI
import ImageconverterCore

/// The right-hand pane: before and after of the selected image, what it is renamed to, and the filmstrip.
struct PreviewPane: View {
    @Bindable var model: AppModel
    /// Below this pane width the two images are stacked.
    static let stackedBelow: CGFloat = 560

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
                    images(stacked: geometry.size.width < Self.stackedBelow)
                }
                .overlay { if model.isRenderingPreview { spinner } }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Before and after")
                .accessibilityZoomAction { action in
                    switch action.direction {
                    case .zoomIn: model.zoom.zoomIn()
                    case .zoomOut: model.zoom.zoomOut()
                    }
                }
                runProgress
                // The bottom handle (pipeline collapse) is a compact mode: the details and thumbnails go too.
                if !model.pipelineCollapsed {
                    infoTable
                    Filmstrip(model: model)
                }
            }
        }
        .lgPanel()
        .padding(LadaGlass.Spacing.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .lgBackdrop()
        .lgCompact()
        .onChange(of: selectedSource, initial: true) { _, source in model.zoom.track(item: source) }
    }

    private var selectedSource: URL? { model.selectedItemIndex.map { model.items[$0].source } }

    private var header: some View {
        HStack {
            Text("Preview").font(LadaGlass.Typography.subtitle)
            Spacer()
            if let percent = model.zoom.percent {
                LGChip("\(percent) %", status: .neutral)
                    .accessibilityLabel("Zoom \(percent) percent")
            }
        }
    }

    private var spinner: some View {
        ProgressView()
            .controlSize(.small)
            .padding(LadaGlass.Spacing.s)
            .lgSurface()
            .accessibilityLabel("Rendering the preview")
    }

    @ViewBuilder private func images(stacked: Bool) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(spacing: LadaGlass.Spacing.m))
                             : AnyLayout(HStackLayout(spacing: LadaGlass.Spacing.m))
        let result = model.previewResult
        let after = model.previewFailure == nil ? result?.after : nil
        // Full-size images for zooming, only when they belong to the image on screen.
        let full = model.sizeEstimate.flatMap { $0.item == result?.source ? $0.full : nil }
        layout {
            side(PreviewSide(kind: .before, title: "Before", image: result?.before, full: full?.original,
                             pixelSize: result.map { CGSize(width: $0.sourceSize.0, height: $0.sourceSize.1) },
                             isReference: after == nil, failure: nil))
            side(PreviewSide(kind: .after, title: "After", image: after, full: full?.encoded,
                             pixelSize: result.map { CGSize(width: $0.outputSize.0, height: $0.outputSize.1) },
                             isReference: true, failure: model.previewFailure))
        }
    }

    private func side(_ side: PreviewSide) -> some View {
        VStack(spacing: LadaGlass.Spacing.xs) {
            LGChip(side.title, status: .neutral)
            ZStack {
                if let image = side.image {
                    ZoomableImage(image: image, fullImage: side.full,
                                  pixelSize: side.pixelSize ?? CGSize(width: image.width, height: image.height),
                                  label: "\(side.title) image", side: side.kind, isReference: side.isReference,
                                  zoom: model.zoom)
                } else if let failure = side.failure {
                    Text(failure)
                        .font(LadaGlass.Typography.body)
                        .foregroundStyle(LadaGlass.Colors.warnText)
                        .multilineTextAlignment(.center)
                        .padding(LadaGlass.Spacing.m)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Progress bar and Cancel while a batch runs, directly above the table.
    @ViewBuilder private var runProgress: some View {
        if model.isRunning {
            HStack(spacing: LadaGlass.Spacing.s) {
                if let progress = model.progress {
                    ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                        .accessibilityLabel("Conversion progress")
                    Text("\(progress.completed) / \(progress.total)")
                        .font(LadaGlass.Typography.mono)
                        .foregroundStyle(LadaGlass.Colors.muted)
                } else {
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                Button("Cancel") { model.cancel() }
                    .buttonStyle(.lg(.secondary))
                    .accessibilityLabel("Cancel the conversion")
            }
        }
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
        return Self.bytes(estimate.output)
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

/// What one side of the before/after comparison shows.
private struct PreviewSide {
    let kind: ZoomSide
    let title: String
    let image: CGImage?
    /// The full-size bitmap for zooming, when it is ready.
    let full: CGImage?
    /// The image's full pixel size (the drawn bitmap may be smaller).
    let pixelSize: CGSize?
    let isReference: Bool
    let failure: String?
}
