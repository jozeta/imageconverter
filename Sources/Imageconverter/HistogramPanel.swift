import SwiftUI
import ImageconverterCore

/// Which preview image the histogram measures.
enum HistogramSource: String, CaseIterable, Identifiable {
    case original, result
    var id: String { rawValue }
    var title: String { self == .original ? "Original" : "Result" }
}

/// The histogram panel and clipping overlay settings (View ▸ Show Histogram / Show Clipping, persisted), and the
/// clipping mask of the shown result.
@MainActor @Observable
final class HistogramState {
    var showHistogram: Bool {
        didSet { defaults.set(showHistogram, forKey: ViewDefaults.showHistogramKey) }
    }
    var showClipping: Bool {
        didSet { defaults.set(showClipping, forKey: ViewDefaults.showClippingKey) }
    }
    var source: HistogramSource {
        didSet { defaults.set(source.rawValue, forKey: ViewDefaults.histogramSourceKey) }
    }
    /// The overlay for the result image it was made from (see `AppModel.renderClippingMask`).
    var clippingMask: ClippingMask?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        showHistogram = defaults.bool(forKey: ViewDefaults.showHistogramKey)
        showClipping = defaults.bool(forKey: ViewDefaults.showClippingKey)
        source = defaults.string(forKey: ViewDefaults.histogramSourceKey).flatMap(HistogramSource.init(rawValue:))
            ?? .result
    }
}

/// A clipping mask and the result image it belongs to (the overlay is drawn only over that image).
struct ClippingMask {
    let after: CGImage
    let mask: CGImage
}

/// What the clipping mask task depends on: the shown result image and whether the overlay is on.
struct ClippingKey: Equatable {
    let image: CGImage?
    let enabled: Bool

    static func == (lhs: ClippingKey, rhs: ClippingKey) -> Bool {
        lhs.image === rhs.image && lhs.enabled == rhs.enabled
    }
}

extension AppModel {
    var clippingKey: ClippingKey {
        let after = previewFailure == nil ? previewResult?.after : nil
        return ClippingKey(image: after, enabled: histogram.showClipping && !previewCollapsed)
    }

    /// The clipping overlay for `image`, when it is the image the mask was made from.
    func clippingOverlay(for image: CGImage?) -> CGImage? {
        guard histogram.showClipping, let image, let mask = histogram.clippingMask, mask.after === image else { return nil }
        return mask.mask
    }
}

/// The preview header's histogram button (View ▸ Show Histogram, ⌥⌘G).
struct HistogramToggle: View {
    let model: AppModel

    var body: some View {
        let shown = model.histogram.showHistogram
        Button { model.histogram.showHistogram.toggle() } label: {
            Image(systemName: "chart.bar.xaxis")
                .foregroundStyle(shown ? LadaGlass.accent.color : LadaGlass.Colors.text)
        }
        .buttonStyle(.lg(.ghost))
        .help(shown ? "Hide the histogram (⌥⌘G)" : "Show the histogram and clipping warnings (⌥⌘G)")
        .accessibilityLabel("Show histogram")
        .accessibilityAddTraits(shown ? .isSelected : [])
    }
}

/// The histogram panel in the stage's bottom-left corner while it is shown, sized for the stage's height.
struct HistogramCorner: ViewModifier {
    let model: AppModel
    @State private var stageHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stageHeight = $0 }
            .overlay(alignment: .bottomLeading) {
                if model.histogram.showHistogram {
                    HistogramPanel(model: model, layout: HistogramLayout(stageHeight: stageHeight))
                        .padding(LadaGlass.Spacing.xs)
                }
            }
    }
}

/// The histogram of the original or the result in the preview's bottom-left corner, with the clipping figures. Its
/// size follows the stage (`HistogramLayout`); it sits on an opaque backing so a bright image can't wash it out.
struct HistogramPanel: View {
    @Bindable var model: AppModel
    var layout = HistogramLayout(stageHeight: 0)

    var body: some View {
        let state = model.histogram
        let histogram = shownHistogram
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            if !layout.compact {
                Picker("Histogram of", selection: Bindable(state).source) {
                    ForEach(HistogramSource.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Histogram of")
            }
            ZStack(alignment: .topLeading) {
                if let histogram {
                    HistogramChart(histogram: histogram)
                        .opacity(model.isRenderingPreview ? 0.4 : 1)
                } else {
                    Text(emptyText)
                        .font(LadaGlass.Typography.label)
                        .foregroundStyle(LadaGlass.Colors.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // Compact (a short stage): which image is measured, in place of the picker; a click switches it.
                if layout.compact {
                    Button { state.source = state.source == .result ? .original : .result } label: {
                        Text(state.source.title)
                            .font(LadaGlass.Typography.label)
                            .foregroundStyle(LadaGlass.Colors.muted)
                            .padding(LadaGlass.Spacing.xxs)
                    }
                    .buttonStyle(.plain)
                    .help("Histogram of the \(state.source.title.lowercased()); click to measure the "
                          + (state.source == .result ? "original" : "result"))
                    .accessibilityLabel("Histogram of the \(state.source.title.lowercased())")
                    .accessibilityHint("Switches between the original and the result")
                }
            }
            .frame(width: layout.chartSize.width, height: layout.chartSize.height)
            .background(LadaGlass.Colors.code, in: RoundedRectangle(cornerRadius: LadaGlass.Radius.small))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(histogram.map { "Histogram of the \(state.source.title.lowercased()): highlights "
                + "\(Self.percent($0.highlightFraction)), shadows \(Self.percent($0.shadowFraction))" } ?? emptyText)
            HStack(spacing: LadaGlass.Spacing.xs) {
                clipChip("Highlights", fraction: histogram?.highlightFraction, clipped: histogram?.isHighlightClipped)
                clipChip("Shadows", fraction: histogram?.shadowFraction, clipped: histogram?.isShadowClipped)
            }
        }
        .padding(LadaGlass.Spacing.s)
        // Opaque under the glass: the image behind must not show through the chart and chips.
        .background(LadaGlass.Colors.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: LadaGlass.Radius.card))
        .lgSurface()
        .help("Measured on the preview image (at most 1024 px on the long side), not on the full-size file. "
              + "Highlights: pixels with a channel at 255; shadows: pixels with all channels at 0. "
              + "Measured in sRGB, so wide-gamut (Display P3) colours beyond sRGB show as clipped.")
    }

    private var shownHistogram: ImageHistogram? {
        guard let result = model.previewResult, model.selectedItemIndex != nil else { return nil }
        switch model.histogram.source {
        case .original: return result.beforeHistogram
        case .result: return model.previewFailure == nil ? result.afterHistogram : nil
        }
    }

    private var emptyText: String {
        if model.selectedItemIndex == nil { return "No image selected" }
        if model.isRenderingPreview { return "Measuring…" }
        return model.previewFailure != nil && model.histogram.source == .result ? "No result to measure"
            : "No image selected"
    }

    /// "Highlights 0.3 %"; red above `ImageHistogram.warnFraction`; clicking turns on Show Clipping.
    private func clipChip(_ title: String, fraction: Double?, clipped: Bool?) -> some View {
        let text = "\(title) \(fraction.map(Self.percent) ?? "—")"
        return Button { model.histogram.showClipping = true } label: {
            LGChip(text, status: clipped == true ? .bad : .neutral)
        }
        .buttonStyle(.plain)
        .disabled(fraction == nil)
        .help("Show the clipped pixels over the result (⌥⌘J)")
        .accessibilityLabel(text)
        .accessibilityHint("Shows the clipped pixels over the result")
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.1f %%", fraction * 100)
    }
}

/// R, G and B as translucent filled areas (additive in dark mode) and luminance as a line, scaled to the 99.5th
/// percentile bin.
private struct HistogramChart: View {
    let histogram: ImageHistogram
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let channels: [([Int], Color)] = [(histogram.red, .red), (histogram.green, .green), (histogram.blue, .blue)]
        let peak = Double(max(ImageHistogram.displayPeak(histogram.red), ImageHistogram.displayPeak(histogram.green),
                              ImageHistogram.displayPeak(histogram.blue), ImageHistogram.displayPeak(histogram.luminance)))
        Canvas { context, size in
            context.blendMode = colorScheme == .dark ? .plusLighter : .multiply
            for (bins, color) in channels {
                context.fill(Self.area(bins, peak: peak, in: size), with: .color(color.opacity(0.45)))
            }
            context.blendMode = .normal
            context.stroke(Self.line(histogram.luminance, peak: peak, in: size),
                           with: .color(LadaGlass.Colors.text.opacity(0.85)), lineWidth: 1)
        }
    }

    private static func y(_ count: Int, peak: Double, height: CGFloat) -> CGFloat {
        height - height * CGFloat(min(Double(count) / peak, 1))
    }

    private static func line(_ bins: [Int], peak: Double, in size: CGSize) -> Path {
        var path = Path()
        let step = size.width / CGFloat(max(bins.count - 1, 1))
        for (bin, count) in bins.enumerated() {
            let point = CGPoint(x: CGFloat(bin) * step, y: y(count, peak: peak, height: size.height))
            if bin == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    private static func area(_ bins: [Int], peak: Double, in size: CGSize) -> Path {
        var path = line(bins, peak: peak, in: size)
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }
}
