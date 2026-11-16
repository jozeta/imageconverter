import SwiftUI

/// A small capsule grab handle on a panel edge with a chevron showing which way a click moves the edge.
/// It is a button (keyboard focusable with Full Keyboard Access, VoiceOver label, tooltip); the menu
/// commands are the keyboard alternative.
struct EdgeHandle: View {
    enum Edge { case trailing, bottom, top }

    let edge: Edge
    /// True when a click moves the edge outward (shows the preview, expands the pipeline, expands Output upwards).
    let pointsOutward: Bool
    let label: String
    let action: () -> Void

    @State private var hovering = false
    @FocusState private var focused: Bool
    static let length: CGFloat = 44
    static let thickness: CGFloat = 6
    /// Extra clickable margin around the thin capsule: the hit target is 20 × 58 pt.
    static let hitMargin: CGFloat = 7

    var body: some View {
        Button(action: action) {
            ZStack {
                Capsule()
                    .fill(highlighted ? LadaGlass.accent.color : LadaGlass.Colors.muted)
                Image(systemName: chevron)
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(highlighted ? LadaGlass.Colors.onAccent : LadaGlass.Colors.bg)
            }
            .frame(width: isVertical ? Self.thickness : Self.length,
                   height: isVertical ? Self.length : Self.thickness)
            .padding(Self.hitMargin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hovering = $0 }
        .animation(LadaGlass.Motion.quick, value: highlighted)
        .help(label)
        .accessibilityLabel(label)
    }

    private var highlighted: Bool { hovering || focused }

    private var isVertical: Bool { edge == .trailing }

    private var chevron: String {
        switch edge {
        case .trailing: pointsOutward ? "chevron.compact.right" : "chevron.compact.left"
        case .bottom: pointsOutward ? "chevron.compact.down" : "chevron.compact.up"
        case .top: pointsOutward ? "chevron.compact.up" : "chevron.compact.down"
        }
    }
}
