import AppKit
import SwiftUI
import ImageconverterCore

/// The ⓘ right of the main output's format picker (Johan, round 3): the size estimate for the selected image moved
/// here from under the format. Pointing at it shows a box with every output's estimated size and notes ("Main
/// JPEG … · Thumbnail JPEG …"); a click (or Space when it has keyboard focus) pins the box open until clicked again
/// or Escape. The box is a tooltip-style window that never becomes key (`HoverBox`), so a field being edited keeps
/// its focus. VoiceOver reads the same text as the button's value.
struct EstimateInfoButton: View {
    var model: AppModel
    @State private var hovered = false
    @State private var pinned = false
    @State private var box = HoverBox()
    @State private var anchor = AnchorView.Holder()

    private var shown: Bool { pinned || hovered }

    var body: some View {
        Button { pinned.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(shown ? LadaGlass.Colors.text : LadaGlass.Colors.muted)
        .background(AnchorView(holder: anchor))
        .onHover { hovered = $0 }
        .onChange(of: shown) { _, isShown in update(isShown) }
        .onKeyPress(.escape) {
            guard pinned else { return .ignored }
            pinned = false
            return .handled
        }
        .onDisappear { box.close() }
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

    private func update(_ isShown: Bool) {
        if isShown, let view = anchor.view {
            box.show(EstimateBox(model: model), beside: view)
        } else {
            box.close()
        }
    }
}

/// Finds the AppKit view behind a SwiftUI view, to place a window next to it.
struct AnchorView: NSViewRepresentable {
    final class Holder {
        weak var view: NSView?
    }

    let holder: Holder

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        holder.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        holder.view = nsView
    }
}

/// A borderless, non-activating child window showing SwiftUI content to the right of a view, like a tooltip: it
/// never becomes key (the field being edited keeps its focus), ignores the mouse, and moves with its window.
@MainActor
final class HoverBox {
    private var panel: NSPanel?

    func show<Content: View>(_ content: Content, beside anchor: NSView) {
        guard let window = anchor.window else { return }
        close()
        let controller = NSHostingController(rootView: content.fixedSize())
        controller.sizingOptions = .preferredContentSize
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                            defer: true)
        panel.contentViewController = controller
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        let size = controller.view.fittingSize
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        var origin = CGPoint(x: rect.maxX + 8, y: rect.maxY + 12 - size.height)
        if let screen = window.screen?.visibleFrame {
            origin.x = min(origin.x, screen.maxX - size.width)
            origin.y = max(min(origin.y, screen.maxY - size.height), screen.minY)
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: false)
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        self.panel = panel
    }

    func close() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
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
        // Its own window shows whatever is behind it through the material: an opaque base keeps it readable.
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: LadaGlass.Radius.card))
    }
}
