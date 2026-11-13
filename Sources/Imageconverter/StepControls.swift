import SwiftUI
import AppKit
import ImageconverterCore

/// ImageconverterCore's anchor, not SwiftUI's generic `Anchor`.
typealias Anchor = ImageconverterCore.Anchor

// MARK: - Shared controls

/// The trash button on every pipeline row: muted, red on hover and when keyboard-focused.
struct RemoveStepButton: View {
    let label: String
    let action: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) { Image(systemName: "trash") }
            .buttonStyle(.plain)
            .focused($focused)
            .foregroundStyle(hovered || focused ? LadaGlass.Colors.badText : LadaGlass.Colors.muted)
            .onHover { hovered = $0 }
            .padding(LadaGlass.Spacing.xs)
            .contentShape(Rectangle())
            .accessibilityLabel("Remove \(label)")
            .help("Remove")
    }
}

/// A labelled integer field; values are clamped to `minimum` when committed.
struct NumberField: View {
    let title: String
    @Binding var value: Int
    var minimum = 1
    var maximum = Int.max
    var suffix = "px"

    var body: some View {
        HStack(spacing: LadaGlass.Spacing.xs) {
            Text(title).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
            TextField(title, value: Binding(get: { value }, set: { value = min(max(minimum, $0), maximum) }), format: .number)
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
        HStack(spacing: LadaGlass.Spacing.s) { content }
    }
}

/// An accordion card: a chevron button and a header, with the content below when expanded. Own chevron
/// instead of DisclosureGroup so it can be greyed and inert while the step is off.
struct AccordionCard<Header: View, Content: View>: View {
    @Binding var isExpanded: Bool
    let canExpand: Bool
    let title: String
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    private var showsContent: Bool { isExpanded && canExpand }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: LadaGlass.Spacing.s) {
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(showsContent ? 90 : 0))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(LadaGlass.Colors.muted)
                .opacity(canExpand ? 1 : 0.35)
                .disabled(!canExpand)
                .accessibilityLabel(showsContent ? "Collapse \(title)" : "Expand \(title)")
                header
                    .onTapGesture { if canExpand { isExpanded.toggle() } }
            }
            if showsContent {
                content.padding(.top, LadaGlass.Spacing.xs)
            }
        }
        .font(LadaGlass.Typography.body)
        .padding(.horizontal, LadaGlass.Spacing.m)
        .padding(.vertical, LadaGlass.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lgSurface()
        .onChange(of: canExpand) { _, can in if !can { isExpanded = false } }
    }
}
