import SwiftUI
import AppKit
import ImageconverterCore

/// ImageconverterCore's anchor, not SwiftUI's generic `Anchor`.
typealias Anchor = ImageconverterCore.Anchor

// MARK: - Shared controls

/// A labelled integer field; values are clamped to `minimum` when committed.
struct NumberField: View {
    let title: String
    @Binding var value: Int
    var minimum = 1
    var suffix = "px"

    var body: some View {
        HStack(spacing: LadaGlass.Spacing.xs) {
            Text(title).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
            TextField(title, value: Binding(get: { value }, set: { value = max(minimum, $0) }), format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                .accessibilityLabel(title)
            Text(suffix).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
        }
    }
}

struct DecimalField: View {
    let title: String
    @Binding var value: Double
    var minimum = 1.0
    var suffix = ""

    var body: some View {
        HStack(spacing: LadaGlass.Spacing.xs) {
            TextField(title, value: Binding(get: { value }, set: { value = max(minimum, $0) }), format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                .accessibilityLabel(title)
            if !suffix.isEmpty {
                Text(suffix).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
            }
        }
    }
}

/// A color picker with opacity, bridged to `RGBAColor` through sRGB.
struct ColorField: View {
    let title: String
    @Binding var color: RGBAColor

    var body: some View {
        ColorPicker(title, selection: Binding(
            get: { Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha) },
            set: { color = Self.rgba(from: $0) }), supportsOpacity: true)
            .accessibilityLabel(title)
    }

    static func rgba(from color: Color) -> RGBAColor {
        guard let native = NSColor(color).usingColorSpace(.sRGB) else { return .black }
        return RGBAColor(red: Double(native.redComponent), green: Double(native.greenComponent),
                         blue: Double(native.blueComponent), alpha: Double(native.alphaComponent))
    }
}

/// A 3x3 grid for choosing an anchor; arrow keys move the selection.
struct AnchorPicker: View {
    @Binding var anchor: Anchor
    @FocusState private var focused: Bool

    private var index: Int { Anchor.allCases.firstIndex(of: anchor) ?? 4 }

    var body: some View {
        Grid(horizontalSpacing: LadaGlass.Spacing.xs, verticalSpacing: LadaGlass.Spacing.xs) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { col in cell(Anchor.allCases[row * 3 + col]) }
                }
            }
        }
        .padding(LadaGlass.Spacing.xs)
        .focusable()
        .focused($focused)
        .overlay(
            RoundedRectangle(cornerRadius: LadaGlass.Radius.small)
                .strokeBorder(focused ? LadaGlass.accent.color : .clear, lineWidth: 1)
        )
        .onKeyPress(.leftArrow) { move(dCol: -1, dRow: 0) }
        .onKeyPress(.rightArrow) { move(dCol: 1, dRow: 0) }
        .onKeyPress(.upArrow) { move(dCol: 0, dRow: -1) }
        .onKeyPress(.downArrow) { move(dCol: 0, dRow: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Anchor")
    }

    private func cell(_ value: Anchor) -> some View {
        let selected = value == anchor
        return Button { anchor = value } label: {
            RoundedRectangle(cornerRadius: LadaGlass.Radius.small)
                .fill(selected ? LadaGlass.accent.color : LadaGlass.Colors.surface)
                .overlay(RoundedRectangle(cornerRadius: LadaGlass.Radius.small)
                    .strokeBorder(LadaGlass.Colors.border, lineWidth: 1))
                .frame(width: 24, height: 20)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func move(dCol: Int, dRow: Int) -> KeyPress.Result {
        let col = min(2, max(0, index % 3 + dCol))
        let row = min(2, max(0, index / 3 + dRow))
        anchor = Anchor.allCases[row * 3 + col]
        return .handled
    }
}

struct FieldRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: LadaGlass.Spacing.m) { content }
    }
}
