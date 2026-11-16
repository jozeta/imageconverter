import SwiftUI
import ImageconverterCore

/// The ⓘ right of the main output's format picker (Johan, round 3): the size estimate for the selected image moved
/// here from under the format. Hovering shows a box with every output's estimated size and notes ("Main JPEG …
/// · Thumbnail JPEG …"); a click (or Space when it has keyboard focus) pins the box open until clicked again or
/// Escape. VoiceOver reads the same text as the button's value.
struct EstimateInfoButton: View {
    var model: AppModel
    @State private var iconInside = false
    @State private var boxInside = false
    @State private var hoverShown = false
    @State private var pinned = false

    private static let grace: Duration = .milliseconds(250)

    private var shown: Binding<Bool> {
        Binding(get: { pinned || hoverShown },
                set: { if !$0 { pinned = false; hoverShown = false } })
    }

    var body: some View {
        Button { pinned.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(shown.wrappedValue ? LadaGlass.Colors.text : LadaGlass.Colors.muted)
        .onHover { inside in
            iconInside = inside
            if inside { hoverShown = true } else { closeSoon() }
        }
        .popover(isPresented: shown, arrowEdge: .trailing) {
            EstimateBox(model: model)
                .onHover { inside in
                    boxInside = inside
                    if !inside { closeSoon() }
                }
        }
        .accessibilityLabel("Size estimate")
        .accessibilityValue(EstimateBox.lines(model).map { line in
            [line.title, line.size, line.note].compactMap { $0 }.joined(separator: ", ")
        }.joined(separator: "; "))
        .accessibilityHint("Shows the estimated file size of every output")
        #if DEBUG
        // Screenshot aid: `-debugShowEstimateInfo` opens the box once the window is up.
        .task {
            guard CommandLine.arguments.contains("-debugShowEstimateInfo") else { return }
            try? await Task.sleep(for: .milliseconds(1500))
            pinned = true
        }
        #endif
    }

    /// A short grace period lets the pointer cross the gap between the icon and the box.
    private func closeSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: Self.grace)
            if !iconInside && !boxInside { hoverShown = false }
        }
    }
}

/// The box behind the ⓘ: one line per output (the main output first), or why there is no estimate yet.
struct EstimateBox: View {
    var model: AppModel

    struct Line: Hashable {
        let title: String
        let size: String
        let note: String?
        var failed = false
    }

    /// What the box says now.
    @MainActor
    static func lines(_ model: AppModel) -> [Line] {
        func only(_ text: String) -> [Line] { [Line(title: "Estimated size", size: text, note: nil)] }
        if model.items.isEmpty { return only("Add images to see the file size") }
        if let reason = model.estimateFailure { return only(reason) }
        if model.estimateFailed { return only("—") }
        guard !model.isEstimating, let estimate = model.sizeEstimate, let output = estimate.output else {
            return only("Estimating…")
        }
        let main = SizeEstimator.MainEstimate(original: estimate.original, bytes: output, quality: estimate.quality,
                                              note: estimate.note)
        return SizeEstimator.lines(main: main, settings: model.pipeline.output, variants: estimate.variants)
            .map { Line(title: $0.title, size: $0.size, note: $0.note, failed: $0.failed) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            Text("Estimated size · selected image")
                .font(LadaGlass.Typography.label)
                .foregroundStyle(LadaGlass.Colors.muted)
            ForEach(Self.lines(model), id: \.self) { line in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: LadaGlass.Spacing.s) {
                        Text(line.title).font(LadaGlass.Typography.body.weight(.semibold))
                        Spacer(minLength: LadaGlass.Spacing.s)
                        Text(line.size)
                            .font(LadaGlass.Typography.mono)
                            .foregroundStyle(line.failed ? LadaGlass.Colors.badText : LadaGlass.Colors.text)
                    }
                    if let note = line.note {
                        Text(note)
                            .font(LadaGlass.Typography.label)
                            .foregroundStyle(line.failed ? LadaGlass.Colors.badText : LadaGlass.Colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(LadaGlass.Spacing.m)
        .frame(width: 320, alignment: .leading)
        .lgPopoverSurface()
    }
}
