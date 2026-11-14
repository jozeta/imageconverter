import SwiftUI
import ImageconverterCore

/// Lets the user drop images or folders anywhere in the window, not only on the drop zone.
/// Accepts file URLs only (the step reorder drag carries a String and is left alone), and inner
/// drop targets such as the drop zone keep precedence. Off while a run is in progress.
private struct WindowDropTarget: ViewModifier {
    let model: AppModel
    @State private var targeted = false

    private var enabled: Bool { !model.isRunning }

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                guard enabled else { return false }
                let files = urls.filter(\.isFileURL)
                model.add(files)
                return !files.isEmpty
            } isTargeted: { targeted = $0 && enabled }
            .overlay { DropOverlay(visible: forcedVisible || targeted) }
    }

    private var forcedVisible: Bool {
        #if DEBUG
        CommandLine.arguments.contains("-debugShowDropOverlay")
        #else
        false
        #endif
    }
}

/// The full-window highlight shown while a file drag is over the window.
private struct DropOverlay: View {
    let visible: Bool

    var body: some View {
        ZStack {
            if visible {
                RoundedRectangle(cornerRadius: LadaGlass.Radius.card)
                    .fill(LadaGlass.accent.color.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: LadaGlass.Radius.card)
                            .strokeBorder(LadaGlass.accent.color, lineWidth: 3)
                    )
                    .padding(LadaGlass.Spacing.xs)
                Text("Drop images or folders to add them")
                    .font(LadaGlass.Typography.body)
                    .foregroundStyle(LadaGlass.Colors.text)
                    .padding(.horizontal, LadaGlass.Spacing.l)
                    .padding(.vertical, LadaGlass.Spacing.s)
                    .lgSurface()
                    .transition(.opacity)
            }
        }
        // Never intercepts clicks or drags.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeInOut(duration: 0.15), value: visible)
    }
}

extension View {
    /// Accepts dropped image files and folders anywhere on this view (see `WindowDropTarget`).
    func windowDropTarget(model: AppModel) -> some View {
        modifier(WindowDropTarget(model: model))
    }
}
