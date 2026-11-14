import AppKit
import SwiftUI
import ImageconverterCore

/// The hover box on a pipeline item's title: after the pointer has stayed on the title for 1.5 s, a popover
/// says what the item does and how to use it. It closes when the pointer leaves the title and the box, on a
/// click, a scroll or Escape, and it never takes keyboard focus. VoiceOver gets the summary as the hint.
struct StepHelpHover: ViewModifier {
    static let delay: Duration = .milliseconds(1500)
    private static let grace: Duration = .milliseconds(250)

    let topic: StepHelpTopic
    @State private var shown = false
    @State private var titleHovered = false
    @State private var boxHovered = false
    @State private var timer: Task<Void, Never>?
    @State private var monitor: Any?

    private var info: StepHelpInfo { StepHelp.info(for: topic) }

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                titleHovered = inside
                if inside { startTimer() } else { timer?.cancel(); closeSoon() }
            }
            .simultaneousGesture(TapGesture().onEnded { close() })
            .popover(isPresented: $shown, arrowEdge: .trailing) {
                StepHelpBox(info: info)
                    .onHover { inside in
                        boxHovered = inside
                        if !inside { closeSoon() }
                    }
            }
            .onChange(of: shown) { _, isShown in isShown ? watchEvents() : unwatchEvents() }
            .onDisappear { close() }
            .accessibilityHint(info.summary)
            #if DEBUG
            .task {
                let args = CommandLine.arguments
                guard let index = args.firstIndex(of: "-debugShowStepHelp"), index + 1 < args.count,
                      args[index + 1] == Self.debugName(topic) else { return }
                try? await Task.sleep(for: .milliseconds(1200))
                shown = true
            }
            #endif
    }

    #if DEBUG
    /// `-debugShowStepHelp <name>` opens the box of the item with this StepKind raw value, or metadata/rename/output.
    private static func debugName(_ topic: StepHelpTopic) -> String {
        switch topic {
        case .step(let kind): return kind.rawValue
        case .metadata: return "metadata"
        case .rename: return "rename"
        case .output: return "output"
        }
    }
    #endif

    private func startTimer() {
        timer?.cancel()
        guard !shown else { return }
        timer = Task { @MainActor in
            try? await Task.sleep(for: Self.delay)
            // Not while a button is held (dragging a step, a slider, a text selection).
            guard !Task.isCancelled, titleHovered, NSEvent.pressedMouseButtons == 0 else { return }
            shown = true
        }
    }

    /// A short grace period lets the pointer cross the gap between the title and the box.
    private func closeSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: Self.grace)
            if !titleHovered && !boxHovered { close() }
        }
    }

    private func close() {
        timer?.cancel()
        if shown { shown = false }
        boxHovered = false
    }

    private func watchEvents() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown, .leftMouseDown]) { event in
            if event.type != .keyDown || event.keyCode == 53 { Task { @MainActor in close() } }
            return event
        }
    }

    private func unwatchEvents() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension View {
    /// Shows the help box for `topic` when the pointer rests on this view for 1.5 s.
    func stepHelp(_ topic: StepHelpTopic) -> some View { modifier(StepHelpHover(topic: topic)) }
}

/// The popover content: title, summary, "How to use" bullets and tips.
private struct StepHelpBox: View {
    let info: StepHelpInfo

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            Text(info.title).font(LadaGlass.Typography.subtitle)
            Text(info.summary).font(LadaGlass.Typography.body)
            section("How to use", info.howTo)
            if !info.tips.isEmpty { section("Tips", info.tips) }
        }
        .foregroundStyle(LadaGlass.Colors.text)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 320, alignment: .leading)
        .lgPopoverSurface()
        .allowsHitTesting(true)
        .accessibilityElement(children: .combine)
    }

    private func section(_ heading: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            Text(heading).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: LadaGlass.Spacing.xs) {
                    Text("•")
                    Text(line)
                }
                .font(LadaGlass.Typography.body)
            }
        }
    }
}
