import AppKit
import Observation
import SwiftUI
import ImageconverterCore

/// The Output panel's collapsed state and the height chosen by dragging its handle, persisted in UserDefaults.
@MainActor @Observable
final class OutputPanelState {
    static let collapsedKey = "outputCollapsed"
    static let heightKey = "outputHeight"

    /// Only the summary line shows.
    var collapsed: Bool {
        didSet { defaults.set(collapsed, forKey: Self.collapsedKey) }
    }
    /// The open panel's height; nil: its full content.
    var height: CGFloat? {
        didSet {
            if let height { defaults.set(Double(height), forKey: Self.heightKey) } else {
                defaults.removeObject(forKey: Self.heightKey)
            }
        }
    }
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        collapsed = defaults.bool(forKey: Self.collapsedKey)
        height = OutputPanelSizing.storedHeight(defaults.object(forKey: Self.heightKey) as? Double)
    }
}

/// The Output panel with a grab handle on its top edge (Johan, round 3): a click collapses it to one summary line
/// or opens it again; a drag sets its height between that line and its full content (the content scrolls inside a
/// shorter panel) while the window keeps its height, so the pipeline steps above give way. Arrow keys on the
/// focused handle (and VoiceOver's adjust actions) resize it too; View ▸ Collapse Output is the menu command.
/// Every change that moves the edge goes through `SidebarMotion`, like the sidebar's other height changes.
struct CollapsibleOutputPanel: View {
    @Bindable var model: AppModel
    var settings: AppSettings

    /// The open panel's natural height and the collapsed panel's height, as last measured.
    @State private var fullHeight: CGFloat = 0
    @State private var collapsedHeight: CGFloat = 0
    /// The panel's height when the drag began, and its height now; nil while not dragging.
    @State private var dragStart: CGFloat?
    @State private var dragHeight: CGFloat?
    /// A click right after a drag is the drag's own mouse-up, not a toggle.
    @State private var lastDragEnd = Date.distantPast
    @State private var hoverCursor = false
    /// True while a drag gesture is live; SwiftUI resets it when the gesture ends or is cancelled.
    @GestureState private var dragging = false

    private var state: OutputPanelSizing.State {
        OutputPanelSizing.State(collapsed: model.outputPanel.collapsed, height: model.outputPanel.height)
    }

    /// The fixed height of the open panel (dragging, or a chosen height), or nil for its natural height.
    private var openHeight: CGFloat? {
        dragHeight ?? OutputPanelSizing.shownHeight(state, collapsed: collapsedHeight, full: fullHeight)
    }

    /// The panel's height on screen now, where a drag or a key press starts from.
    private var currentHeight: CGFloat {
        if model.outputPanel.collapsed, dragHeight == nil { return collapsedHeight }
        return openHeight ?? fullHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            handle
            if model.outputPanel.collapsed && dragHeight == nil {
                summary
            } else {
                openPanel
            }
        }
        // The collapsed line's height is known even while the panel is open: it is the drag's lower end.
        .background(alignment: .top) {
            summary.fixedSize(horizontal: false, vertical: true).hidden().accessibilityHidden(true)
                .background(GeometryReader { proxy in
                    Color.clear.onAppear { collapsedHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, height in collapsedHeight = height }
                })
                .allowsHitTesting(false)
        }
    }

    // MARK: Handle

    private var handle: some View {
        let collapsed = model.outputPanel.collapsed
        return EdgeHandle(edge: .top, pointsOutward: collapsed,
                          label: collapsed ? "Expand Output" : "Collapse Output") { click() }
            .simultaneousGesture(drag)
            .onKeyPress(.upArrow) { step(1) }
            .onKeyPress(.downArrow) { step(-1) }
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: _ = step(1)
                case .decrement: _ = step(-1)
                @unknown default: break
                }
            }
            .accessibilityValue(accessibilityValue)
            .accessibilityHint("Click to collapse or expand; drag or use the arrow keys to change the height")
            .onHover { inside in
                guard inside != hoverCursor else { return }
                hoverCursor = inside
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if hoverCursor { NSCursor.pop() }
                hoverCursor = false
                endDragWithoutSettling()
            }
            .onChange(of: dragging) { _, live in
                // A cancelled drag never reaches `onEnded`: once the gesture is over, a drag still open is let go
                // (checked a turn later, after `onEnded` had its chance).
                guard !live else { return }
                DispatchQueue.main.async { endDragWithoutSettling() }
            }
            .frame(maxWidth: .infinity)
    }

    /// "Collapsed", or "180 points of 320" (the panel's height and its full content).
    private var accessibilityValue: String {
        if model.outputPanel.collapsed, dragHeight == nil { return "Collapsed" }
        return "\(Int(currentHeight.rounded())) points of \(Int(max(fullHeight, currentHeight).rounded()))"
    }

    /// Ends a drag that didn't finish normally: the panel keeps its saved state and the window pin is let go.
    private func endDragWithoutSettling() {
        guard dragStart != nil else { return }
        dragStart = nil
        dragHeight = nil
        model.windowSizer.requestRelease()
    }

    private func click() {
        guard dragStart == nil, Date().timeIntervalSince(lastDragEnd) > 0.3 else { return }
        model.toggleOutput()
    }

    private var drag: some Gesture {
        // Global coordinates: the handle moves with the panel's top edge while it is dragged.
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .updating($dragging) { _, live, _ in live = true }
            .onChanged { value in
                if dragStart == nil {
                    dragStart = currentHeight
                    model.windowSizer.pinHeight()
                }
                dragHeight = OutputPanelSizing.dragged(from: dragStart ?? currentHeight,
                                                       translation: value.translation.height,
                                                       collapsed: collapsedHeight, full: fullHeight)
            }
            .onEnded { _ in
                let settled = OutputPanelSizing.settled(dragHeight ?? currentHeight, collapsed: collapsedHeight,
                                                        full: fullHeight)
                SidebarMotion.perform { apply(settled) }
                dragStart = nil
                dragHeight = nil
                lastDragEnd = Date()
                model.windowSizer.requestRelease()
            }
    }

    private func step(_ direction: Int) -> KeyPress.Result {
        let next = OutputPanelSizing.stepped(from: currentHeight, by: direction, collapsed: collapsedHeight,
                                             full: fullHeight)
        guard next != state else { return .handled }
        // Like a drag: the window keeps its height until the new layout is measured.
        model.windowSizer.pinHeight()
        SidebarMotion.perform { apply(next) }
        model.windowSizer.requestRelease()
        return .handled
    }

    private func apply(_ new: OutputPanelSizing.State) {
        if model.outputPanel.collapsed != new.collapsed { model.outputPanel.collapsed = new.collapsed }
        // Collapsing keeps the open height for the next expand.
        if !new.collapsed, model.outputPanel.height != new.height { model.outputPanel.height = new.height }
    }

    // MARK: Panel

    private var openPanel: some View {
        ScrollView {
            OutputPanel(model: model, settings: settings)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { proxy in
                    Color.clear.onAppear { fullHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, height in fullHeight = height }
                })
        }
        .scrollDisabled(openHeight == nil)
        .scrollIndicators(openHeight == nil ? .never : .automatic)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: openHeight)
        .clipShape(RoundedRectangle(cornerRadius: LadaGlass.Radius.card))
        .lgSurface()
    }

    /// One line: "Output", then format · quality · where the files go.
    private var summary: some View {
        HStack(spacing: LadaGlass.Spacing.s) {
            Text("Output").font(LadaGlass.Typography.subtitle)
            Text(summaryText)
                .font(LadaGlass.Typography.label)
                .foregroundStyle(LadaGlass.Colors.muted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LadaGlass.Spacing.m)
        .padding(.vertical, LadaGlass.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lgSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Output: \(summaryText)")
    }

    private var summaryText: String {
        OutputSummary.line(model.pipeline.output, saveTo: settings.modeKind,
                           folderName: settings.outputFolder?.lastPathComponent, suffix: settings.sameFolderSuffix,
                           extraOutputs: model.pipeline.extraOutputs.count)
    }
}
