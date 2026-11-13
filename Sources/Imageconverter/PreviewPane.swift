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
                infoTable
                Filmstrip(model: model)
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
            side(title: "Before", image: result?.before, full: full?.original,
                 pixelSize: result.map { CGSize(width: $0.sourceSize.0, height: $0.sourceSize.1) },
                 isReference: after == nil, failure: nil)
            side(title: "After", image: after, full: full?.encoded,
                 pixelSize: result.map { CGSize(width: $0.outputSize.0, height: $0.outputSize.1) },
                 isReference: true, failure: model.previewFailure)
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func side(title: String, image: CGImage?, full: CGImage?, pixelSize: CGSize?,
                      isReference: Bool, failure: String?) -> some View {
        VStack(spacing: LadaGlass.Spacing.xs) {
            LGChip(title, status: .neutral)
            ZStack {
                if let image {
                    ZoomableImage(image: image, fullImage: full,
                                  pixelSize: pixelSize ?? CGSize(width: image.width, height: image.height),
                                  label: "\(title) image", isReference: isReference, zoom: model.zoom)
                } else if let failure {
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
                            .lineLimit(2).gridCellColumns(1)
                    } else {
                        cell(result?.outputName ?? "—")
                    }
                }
                if !failed, let result {
                    GridRow {
                        label("Folder")
                        folderCell(result.source.deletingLastPathComponent())
                        folderCell(result.outputURL.deletingLastPathComponent())
                    }
                    GridRow {
                        label("Dimensions")
                        cell("\(result.sourceSize.0) × \(result.sourceSize.1)")
                        cell("\(result.outputSize.0) × \(result.outputSize.1)")
                    }
                    GridRow {
                        label("Size")
                        cell(Self.bytes(model.sizeEstimate?.original ?? result.sourceFileSize))
                        cell(resultSize)
                    }
                }
            }
            .textSelection(.enabled)
        }
    }

    private var resultSize: String {
        if model.isEstimating { return "Estimating…" }
        return Self.bytes(model.sizeEstimate?.output)
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
