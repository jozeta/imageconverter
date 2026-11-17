import SwiftUI
import ImageconverterCore

/// What one side of the before/after comparison shows.
struct PreviewSide {
    let kind: ZoomSide
    let title: String
    let image: CGImage?
    /// The full-size bitmap for zooming, when it is ready.
    let full: CGImage?
    /// The image's full pixel size (the drawn bitmap may be smaller).
    let pixelSize: CGSize?
    let isReference: Bool
    let failure: String?
    /// The clipping overlay drawn over this side (the result only, while View ▸ Show Clipping is on).
    var clipping: CGImage?

    var size: CGSize? { pixelSize ?? image.map { CGSize(width: $0.width, height: $0.height) } }
}

/// The image area in the selected comparison mode. All modes share the model's zoom state.
struct ComparisonStage: View {
    @Bindable var model: AppModel
    let stacked: Bool

    var body: some View {
        let (before, after) = sides
        switch model.compare.mode {
        case .sideBySide: sideBySide(before, after)
        case .split: SplitComparison(model: model, before: before, after: after)
        case .difference: DifferenceComparison(model: model)
        case .single: SingleComparison(model: model, before: before, after: after)
        }
    }

    private var sides: (PreviewSide, PreviewSide) {
        let result = model.previewResult
        let after = model.previewFailure == nil ? result?.after : nil
        // Full-size images for zooming, only when they belong to the image on screen.
        let full = model.sizeEstimate.flatMap { $0.item == result?.source ? $0.full : nil }
        return (PreviewSide(kind: .before, title: "Before", image: result?.before, full: full?.original,
                            pixelSize: result.map { CGSize(width: $0.sourceSize.0, height: $0.sourceSize.1) },
                            isReference: after == nil, failure: nil),
                PreviewSide(kind: .after, title: "After", image: after, full: full?.encoded,
                            pixelSize: result.map { CGSize(width: $0.outputSize.0, height: $0.outputSize.1) },
                            isReference: true, failure: model.previewFailure,
                            clipping: model.clippingOverlay(for: after)))
    }

    private func sideBySide(_ before: PreviewSide, _ after: PreviewSide) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(spacing: LadaGlass.Spacing.m))
                             : AnyLayout(HStackLayout(spacing: LadaGlass.Spacing.m))
        return layout {
            column(before)
            column(after)
        }
    }

    private func column(_ side: PreviewSide) -> some View {
        VStack(spacing: LadaGlass.Spacing.xs) {
            LGChip(side.title, status: .neutral)
            ZStack {
                if let image = side.image, let size = side.size {
                    ZoomableImage(image: image, fullImage: side.full, pixelSize: size, label: "\(side.title) image",
                                  side: side.kind, isReference: side.isReference, zoom: model.zoom,
                                  overlay: side.clipping)
                } else if let failure = side.failure {
                    FailureText(text: failure)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A render failure in place of an image.
struct FailureText: View {
    let text: String
    var body: some View {
        Text(text)
            .font(LadaGlass.Typography.body)
            .foregroundStyle(LadaGlass.Colors.warnText)
            .multilineTextAlignment(.center)
            .padding(LadaGlass.Spacing.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One image box: Before left of a draggable divider, After right of it, at the shared zoom.
/// ← and → move the divider while the box has keyboard focus.
struct SplitComparison: View {
    @Bindable var model: AppModel
    let before: PreviewSide
    let after: PreviewSide
    static let keyStep: CGFloat = 0.05

    var body: some View {
        let compare = model.compare
        let position = compare.splitPosition
        ZStack {
            if let beforeImage = before.image, let beforeSize = before.size {
                if let afterImage = after.image, let afterSize = after.size {
                    ZoomableImage(image: beforeImage, fullImage: before.full, pixelSize: beforeSize, label: "Before image",
                                  side: .before, isReference: false, zoom: model.zoom, interactive: false,
                                  visible: 0...position)
                    ZoomableImage(image: afterImage, fullImage: after.full, pixelSize: afterSize, label: "After image",
                                  side: .after, isReference: true, zoom: model.zoom, overlay: after.clipping,
                                  visible: position...1,
                                  divider: position, onDivider: { compare.setSplit($0) },
                                  onDividerEnd: { compare.commitSplit() })
                    dividerLine(at: position)
                } else {
                    ZoomableImage(image: beforeImage, fullImage: before.full, pixelSize: beforeSize, label: "Before image",
                                  side: .before, isReference: true, zoom: model.zoom)
                    if let failure = after.failure { FailureText(text: failure).allowsHitTesting(false) }
                }
            }
        }
        .overlay(alignment: .topLeading) { label("Before").padding(LadaGlass.Spacing.xs) }
        .overlay(alignment: .topTrailing) { label("After").padding(LadaGlass.Spacing.xs) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .onKeyPress(.leftArrow) {
            compare.moveSplit(by: -Self.keyStep)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            compare.moveSplit(by: Self.keyStep)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split comparison, Before left, After right")
        .accessibilityValue("Divider at \(Int((position * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: compare.moveSplit(by: Self.keyStep)
            case .decrement: compare.moveSplit(by: -Self.keyStep)
            @unknown default: break
            }
        }
    }

    private func label(_ text: String) -> some View {
        LGChip(text, status: .neutral).allowsHitTesting(false)
    }

    /// The line and its knob; the drag itself is handled by the After side's event view.
    private func dividerLine(at position: CGFloat) -> some View {
        GeometryReader { proxy in
            let line = proxy.size.width * position
            ZStack {
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: proxy.size.height)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.black)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white))
                    .shadow(color: .black.opacity(0.4), radius: 2)
            }
            .position(x: line, y: proxy.size.height / 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The amplified difference between the original and the encoded result, with its error figures.
struct DifferenceComparison: View {
    @Bindable var model: AppModel

    var body: some View {
        let outcome = model.compare.difference
        VStack(spacing: LadaGlass.Spacing.xs) {
            LGChip("Difference", status: .neutral)
            ZStack {
                if let outcome, let image = outcome.image {
                    // Drawn where its region sits in the full image, so pan and zoom stay live while the next
                    // region is computed.
                    ZoomableImage(image: image, fullImage: nil, pixelSize: outcome.fullSize,
                                  label: "Difference image", side: .after, isReference: true, zoom: model.zoom,
                                  region: outcome.region)
                } else if let reason = outcome?.unavailable ?? model.previewFailure {
                    Text(reason)
                        .font(LadaGlass.Typography.body)
                        .foregroundStyle(LadaGlass.Colors.muted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView("Computing the difference…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let outcome, let stats = outcome.stats {
                Text(CompareText.differenceSummary(stats, region: outcome.region != QualityLadder.unitRegion,
                                                   scaled: outcome.scaled))
                    .font(LadaGlass.Typography.mono)
                    .foregroundStyle(LadaGlass.Colors.muted)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// After at full size; hold Space (pointer over the image) or press B to see Before.
struct SingleComparison: View {
    @Bindable var model: AppModel
    let before: PreviewSide
    let after: PreviewSide

    var body: some View {
        let compare = model.compare
        let showBefore = compare.showingBefore || after.image == nil
        VStack(spacing: LadaGlass.Spacing.xs) {
            HStack(spacing: LadaGlass.Spacing.s) {
                Button { compare.showingBefore.toggle() } label: {
                    Label(showBefore ? "Before" : "After", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(.lg(.secondary))
                .disabled(after.image == nil)
                .help(CompareMode.single.help)
                .accessibilityLabel(showBefore ? "Showing before image" : "Showing after image")
                .accessibilityHint(showBefore ? "Toggle to after" : "Toggle to before")
                Text("Hold Space over the image or press B")
                    .font(LadaGlass.Typography.label)
                    .foregroundStyle(LadaGlass.Colors.muted)
                    .lineLimit(1)
            }
            ZStack {
                // After keeps its geometry while hidden, so the zoom range and 100 % stay the After image's.
                if let afterImage = after.image, let afterSize = after.size {
                    ZoomableImage(image: afterImage, fullImage: after.full, pixelSize: afterSize, label: "After image",
                                  side: .after, isReference: true, zoom: model.zoom, overlay: after.clipping,
                                  visible: showBefore ? 0...0 : 0...1)
                }
                if let beforeImage = before.image, let beforeSize = before.size {
                    ZoomableImage(image: beforeImage, fullImage: before.full, pixelSize: beforeSize, label: "Before image",
                                  side: .before, isReference: after.image == nil, zoom: model.zoom,
                                  interactive: after.image == nil, visible: showBefore ? 0...1 : 0...0)
                }
                if after.image == nil, let failure = after.failure {
                    FailureText(text: failure).allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onHover { compare.pointerInPreview = $0 }
            .onDisappear { compare.pointerInPreview = false }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
