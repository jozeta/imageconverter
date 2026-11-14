import AppKit
import SwiftUI

/// The one motion every main-window height change uses: quick and ease-in-out, with the window edge and
/// the content moving as one.
///
/// How they stay together: the sidebar animates a single value, the window height it wants
/// (`WindowSizer.targetHeight`), with this animation. `SidebarHeightReporter` is `Animatable`, so SwiftUI
/// hands it the interpolated height on every frame; `WindowSizer` sets the window to it in the same pass,
/// and the sidebar and preview lay themselves out in the window as it is (Output and Run sit at the
/// bottom, the pipeline steps get the room between). Nothing is animated twice, so nothing jumps.
/// Content changes that should also glide inside the window (a step added to a window the user made
/// taller) are made with `perform` or through `sidebarAnimated`.
enum SidebarMotion {
    static let duration: TimeInterval = 0.2

    /// The animation, or nil under Reduce Motion (changes then happen at once).
    @MainActor static var animation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: duration)
    }

    /// Makes a change that alters the sidebar's height, animated.
    @MainActor static func perform<Result>(_ change: () throws -> Result) rethrows -> Result {
        try withAnimation(animation, change)
    }
}

extension Binding {
    /// This binding with the sidebar motion, for controls whose value changes the sidebar's height
    /// (an editor's mode picker, an expand toggle).
    @MainActor var sidebarAnimated: Binding<Value> { animation(SidebarMotion.animation) }
}

/// Reports the window height the sidebar shows at this frame. Because it is `Animatable`, SwiftUI
/// re-evaluates it with the interpolated value on every frame of an animation, so the reported height
/// is the one to put on screen now, not the target.
struct SidebarHeightReporter: ViewModifier, Animatable {
    var height: CGFloat

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func body(content: Content) -> some View {
        content.preference(key: SidebarShownHeightKey.self, value: height)
    }
}

/// The window content height the sidebar shows at this frame.
struct SidebarShownHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Shows `progress` (0…1) of its content's height, from the top, clipped at the bottom (far outside on
/// the other sides, so focus rings and shadows stay). Used for parts that come and go with the window
/// edge, such as the preview's details when the pipeline is collapsed or expanded.
struct RevealLayout: Layout {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(proposal)
        return CGSize(width: size.width, height: size.height * min(max(progress, 0), 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(proposal)
        child.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

/// `RevealLayout` plus the clip.
struct RevealModifier: ViewModifier {
    var progress: CGFloat

    func body(content: Content) -> some View {
        RevealLayout(progress: progress) { content }
            .clipShape(BottomEdgeClip())
    }
}

/// A rectangle cut at the view's bottom edge and far outside it on the other three sides.
struct BottomEdgeClip: Shape {
    func path(in rect: CGRect) -> Path {
        let outset: CGFloat = 1000
        return Path(CGRect(x: rect.minX - outset, y: rect.minY - outset,
                           width: rect.width + 2 * outset, height: rect.height + outset))
    }
}
