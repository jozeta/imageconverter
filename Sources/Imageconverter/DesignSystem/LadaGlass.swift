// lada-glass 2.2.0
// Låda Glass for native Mac apps (SwiftUI, macOS 14+, Swift 6). Copy this one file into an app's
// sources, e.g. <App>/DesignSystem/LadaGlass.swift (Sources/<Target>/DesignSystem/ for SwiftPM), and
// keep the version line above: claude-check compares it with tools/design/VERSION. Values come from
// Låda (tools/design/tokens.json; a test checks this file matches). Don't edit the copy; update it.
//
// What's here (2.1 matches the 2.0 web components):
//   Tokens       LadaGlass.Colors, Accent, Glass, Spacing, Radius, Typography, Durations, Motion, Density
//   Surfaces     .lgPanel(), .lgSurface(), .lgBackdrop(), .lgSheetSurface(), .lgPopoverSurface()
//   Controls     LGButtonStyle (.lg(.primary | .secondary | .ghost | .danger)), LGChip
//   Toasts       LGToastCenter + .lgToasts(center): show / update / dismiss / promise
//   Notify       LadaGlass.SystemNotifications: macOS notifications in the background, a toast in front (2.2)
//   Palette      .lgCommandPalette(isPresented:commands:) with ⌘K; LadaGlass.fuzzy, filterCommands
//                (fuzzy scores as the web for ASCII and NFC text; Swift compares Characters, JS UTF-16
//                units, so decomposed text and case mappings like İ can differ)
//   Numbers      LGNumber(value:format:showsDelta:), LGDelta
//   Charts       LadaGlass.chartColors, .lgChartSeriesStyle(index:), LGSparkline(values:)
//
// Drawer and bottom sheet: use the system's, with the 2.0 surface:
//   .inspector(isPresented: $showInfo) { InfoView().lgSheetSurface() }                  side sheet
//   .sheet(isPresented: $edit) { EditView().lgSheetSurface().presentationDetents([.medium, .large]) }
// Menus, tooltips and popovers stay native (Menu, .help("…"), .popover); give a popover the surface
// with .popover(isPresented: $p) { Content().lgPopoverSurface() }.
import SwiftUI
import AppKit
import Charts
import UserNotifications

public enum LadaGlass {
    // MARK: Colours (dark / light, following the system appearance)

    /// A colour that follows the appearance: `dark` under Dark Aqua, `light` otherwise.
    public static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    public enum Colors {
        public static let bg = adaptive(dark: 0x141619, light: 0xF7F6F3)
        public static let sidebar = adaptive(dark: 0x1B1E23, light: 0xEFECE6)
        public static let surface = adaptive(dark: 0x1E2127, light: 0xFCFBF9)
        public static let elevated = adaptive(dark: 0x252930, light: 0xFFFFFF)
        public static let code = adaptive(dark: 0x0F1217, light: 0xF5F7FA)
        public static let text = adaptive(dark: 0xECEEEF, light: 0x1A1D21)
        public static let muted = adaptive(dark: 0x8E96A2, light: 0x5C646E)
        public static let border = adaptive(dark: 0x2C313A, light: 0xDFDDD7)
        /// Status colours: for dots, icons and tints.
        public static let ok = adaptive(dark: 0x47B577, light: 0x2C8C58)
        public static let warn = adaptive(dark: 0xE09B3D, light: 0xB8741A)
        public static let bad = adaptive(dark: 0xE05A5A, light: 0xB83B3B)
        /// Status colours for text on a status tint (chips): these meet WCAG AA.
        public static let okText = adaptive(dark: 0x50B97E, light: 0x216A43)
        public static let warnText = adaptive(dark: 0xE09B3D, light: 0x845413)
        public static let badText = adaptive(dark: 0xE78282, light: 0xA23434)
        /// Text on an accent-coloured fill (primary buttons).
        public static let onAccent = adaptive(dark: 0x0F1217, light: 0xFFFFFF)
        public static let backdropFrom = adaptive(dark: 0x11151B, light: 0xEAF0F5)
        public static let backdropTo = adaptive(dark: 0x181B21, light: 0xF3F5F8)
    }

    // MARK: Accents (Låda's accent themes; lighter in dark mode, deeper in light mode)

    public enum Accent: String, CaseIterable, Sendable {
        case fjord, arcticTeal, slateSteel, frostCyan, auroraGreen, auroraViolet, lingonberry, cloudberry, birchGold, midnightIndigo

        /// (dark, light) sRGB hex.
        public var hex: (dark: UInt32, light: UInt32) {
            switch self {
            case .fjord: return (0x5A93C4, 0x2B5B84)
            case .arcticTeal: return (0x459AA3, 0x216B73)
            case .slateSteel: return (0x7D91A8, 0x415164)
            case .frostCyan: return (0x88C0D0, 0x2A7288)
            case .auroraGreen: return (0xA3BE8C, 0x45763E)
            case .auroraViolet: return (0xB48EAD, 0x714D88)
            case .lingonberry: return (0xD96E75, 0xA83541)
            case .cloudberry: return (0xE0915C, 0xAD591D)
            case .birchGold: return (0xE1BC6D, 0x8C6A16)
            case .midnightIndigo: return (0x8D95E3, 0x41479C)
            }
        }

        public var color: Color { LadaGlass.adaptive(dark: hex.dark, light: hex.light) }
    }

    /// The app's accents. Set once at launch to customise (e.g. `LadaGlass.accent = .arcticTeal`).
    nonisolated(unsafe) public static var accent: Accent = .fjord
    nonisolated(unsafe) public static var accent2: Accent = .frostCyan

    // MARK: Glass (the 2.0 surface recipe)

    /// An sRGB colour with alpha, as in tokens.json's rgba() values.
    public struct RGBA: Equatable, Sendable {
        public var r: UInt8, g: UInt8, b: UInt8
        public var a: Double
        public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: Double) { self.r = r; self.g = g; self.b = b; self.a = a }
        /// A (dark, light) pair from two (r, g, b, a) tuples.
        public static func pair(dark: (UInt8, UInt8, UInt8, Double), light: (UInt8, UInt8, UInt8, Double)) -> Pair {
            Pair(dark: RGBA(dark.0, dark.1, dark.2, dark.3), light: RGBA(light.0, light.1, light.2, light.3))
        }
        public struct Pair: Equatable, Sendable {
            public var dark: RGBA
            public var light: RGBA
            public var color: Color { LadaGlass.adaptive(dark: dark, light: light) }
        }
    }

    /// A colour with alpha that follows the appearance.
    public static func adaptive(dark: RGBA, light: RGBA) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: c.a)
        })
    }

    /// The 2.0 glass: a vertical fill gradient (fillTop to fillBottom), a 1 pt edge, a top highlight,
    /// a layered shadow, and the glow strength of lit (primary) controls.
    public enum Glass {
        public static let fillTop = RGBA.pair(dark: (255, 255, 255, 0.055), light: (255, 255, 255, 0.85))
        public static let fillBottom = RGBA.pair(dark: (255, 255, 255, 0.02), light: (255, 255, 255, 0.55))
        public static let edge = RGBA.pair(dark: (255, 255, 255, 0.08), light: (26, 29, 33, 0.11))
        public static let highlight = RGBA.pair(dark: (255, 255, 255, 0.06), light: (255, 255, 255, 0.9))
        public static let shadow = RGBA.pair(dark: (0, 0, 0, 0.6), light: (40, 50, 70, 0.16))
        /// Accent glow opacity factor (dark, light).
        public static let glow = (dark: 0.35, light: 0.22)
    }

    /// color-mix(in srgb, a weight·100 %, b): mixes two sRGB hex colours; weight is a's share.
    public static func mix(_ a: UInt32, _ b: UInt32, _ weight: Double) -> UInt32 {
        func ch(_ hex: UInt32, _ shift: UInt32) -> Double { Double((hex >> shift) & 0xFF) }
        var out: UInt32 = 0
        for shift: UInt32 in [16, 8, 0] {
            let v = (weight * ch(a, shift) + (1 - weight) * ch(b, shift)).rounded()
            out |= UInt32(min(255, max(0, v))) << shift
        }
        return out
    }

    // MARK: Layout, type, motion

    /// 4-pt spacing scale.
    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
    }

    public enum Radius {
        /// Buttons, fields, badges, list rows.
        public static let control: CGFloat = 9
        /// Panels and cards.
        public static let card: CGFloat = 12
        /// Chips, keys and other small marks.
        public static let small: CGFloat = 6
        /// Sheets, drawers and dialogs.
        public static let sheet: CGFloat = 16
    }

    public enum Typography {
        public static let title = Font.system(size: 18, weight: .semibold)
        public static let subtitle = Font.system(size: 13, weight: .medium)
        public static let body = Font.system(size: 13)
        public static let label = Font.system(size: 11, weight: .semibold)
        public static let kpi = Font.system(size: 22, weight: .semibold).monospacedDigit()
        public static let mono = Font.system(size: 12, design: .monospaced)
    }

    /// Durations in seconds. Quick micro-animations; slow, smooth larger transitions.
    public enum Durations {
        public static let quick: Double = 0.14
        public static let standard: Double = 0.32
        public static let data: Double = 0.35
        public static let slow: Double = 0.55
    }

    public enum Motion {
        /// Hover, highlight and colour changes.
        public static let quick = Animation.easeOut(duration: Durations.quick)
        /// Layout and state changes.
        public static let standard = Animation.spring(response: Durations.standard, dampingFraction: 0.86)
        /// Numbers and charts settling.
        public static let data = Animation.easeInOut(duration: Durations.data)
        /// Larger transitions: slow and smooth.
        public static let slow = Animation.easeInOut(duration: Durations.slow)
    }

    /// Compact density everywhere (as in Låda).
    public enum Density {
        public static let paddingScale: CGFloat = 0.65
        public static let rowHeight: CGFloat = 20
    }
}


// MARK: - Pure helpers (unit-tested in design/swift)

public extension LadaGlass {
    /// Fuzzy matching, the same scoring as LadaGlass.fuzzy on the web: a case-insensitive
    /// subsequence match; nil when the query's characters don't all appear in order, 0 for an empty
    /// query. +3 for each matched character at a word start, +2 for each one right after the previous
    /// match, +5 when the text starts with the query. Each place the first character occurs is tried
    /// as a start (the rest matched leftmost from there) and the best score wins. Identical to the web
    /// for ASCII and NFC text; Swift compares Characters where JS compares UTF-16 units, so decomposed
    /// text (e + U+0301) and special case mappings (İ lowercases to two units in JS) can score differently.
    static func fuzzy(_ query: String, _ text: String) -> Int? {
        let q = Array(query.lowercased()), t = Array(text.lowercased())
        if q.isEmpty { return 0 }
        func wordStart(_ i: Int) -> Bool { i == 0 || !(t[i - 1].isLetter || t[i - 1].isNumber) }
        func find(_ c: Character, from: Int) -> Int? {
            var i = from
            while i < t.count { if t[i] == c { return i }; i += 1 }
            return nil
        }
        var best: Int?
        var start = find(q[0], from: 0)
        while let s = start {
            var score: Int? = wordStart(s) ? 3 : 0
            var prev = s
            for j in q.indices.dropFirst() {
                guard let i = find(q[j], from: prev + 1) else { score = nil; break }
                if wordStart(i) { score! += 3 }
                if i == prev + 1 { score! += 2 }
                prev = i
            }
            guard let sc = score else { break }   // a later start can't match what an earlier one couldn't
            if best == nil || sc > best! { best = sc }
            start = find(q[0], from: s + 1)
        }
        if best != nil && t.starts(with: q) { best! += 5 }
        return best
    }

    /// The command palette's filter: groups in the order they first appear; inside a group the best
    /// fuzzy score over the label and keywords first, then the original order. The query is trimmed.
    static func filterCommands(_ commands: [LGCommand], query: String) -> [LGCommandGroup] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var groups: [(name: String, items: [(cmd: LGCommand, score: Int, i: Int)])] = []
        for (i, cmd) in commands.enumerated() {
            let name = cmd.group ?? ""
            let g = groups.firstIndex { $0.name == name } ?? { groups.append((name, [])); return groups.count - 1 }()
            let score = ([cmd.label] + cmd.keywords).compactMap { fuzzy(q, $0) }.max()
            if let score { groups[g].items.append((cmd, score, i)) }
        }
        return groups.filter { !$0.items.isEmpty }.map { g in
            LGCommandGroup(name: g.name, commands: g.items.sorted { $0.score != $1.score ? $0.score > $1.score : $0.i < $1.i }.map(\.cmd))
        }
    }

    /// Series accents for charts, in the web's order: the accent, the second accent, then the other
    /// accent presets in tokens.json order.
    static func chartAccents(accent: Accent = LadaGlass.accent, accent2: Accent = LadaGlass.accent2) -> [Accent] {
        [accent, accent2] + Accent.allCases.filter { $0 != accent && $0 != accent2 }
    }

    /// Series colours (adaptive) in the web's order; use with .chartForegroundStyleScale(range:).
    static func chartColors(accent: Accent = LadaGlass.accent, accent2: Accent = LadaGlass.accent2) -> [Color] {
        chartAccents(accent: accent, accent2: accent2).map(\.color)
    }

    enum SeriesSymbol: CaseIterable, Hashable, Sendable {
        case circle, square, triangle, diamond, pentagon, cross
        public var shape: BasicChartSymbolShape {
            switch self {
            case .circle: return .circle
            case .square: return .square
            case .triangle: return .triangle
            case .diamond: return .diamond
            case .pentagon: return .pentagon
            case .cross: return .cross
            }
        }
    }

    /// A series' symbol and line dash, so no chart relies on colour alone.
    struct SeriesStyle: Hashable, Sendable {
        public var symbol: SeriesSymbol
        public var dash: [CGFloat]
    }

    /// Six symbols and four dash patterns: the first twelve series all differ.
    static func seriesStyle(index: Int) -> SeriesStyle {
        let dashes: [[CGFloat]] = [[], [6, 3], [2, 3], [8, 3, 2, 3]]
        let i = max(0, index)
        let symbols = SeriesSymbol.allCases
        return SeriesStyle(symbol: symbols[i % symbols.count], dash: dashes[i % dashes.count])
    }

    /// A number formatted for display, with a real minus sign (U+2212).
    static func formatNumber(_ value: Double, format: FloatingPointFormatStyle<Double> = .number) -> String {
        value.formatted(format).replacingOccurrences(of: "-", with: "\u{2212}")
    }

    /// A change as the web's delta badge shows it: +n, −n (U+2212) or n for no change.
    static func formatDelta(_ diff: Double, format: FloatingPointFormatStyle<Double> = .number) -> String {
        let abs = Swift.abs(diff).formatted(format)
        return diff > 0 ? "+" + abs : diff < 0 ? "\u{2212}" + abs : abs
    }

    enum DeltaDirection: Sendable {
        case up, down, flat
        public init(_ diff: Double) { self = diff > 0 ? .up : diff < 0 ? .down : .flat }
    }

    /// What VoiceOver reads for a sparkline.
    static func sparklineSummary(_ values: [Double], format: FloatingPointFormatStyle<Double> = .number) -> String {
        guard let first = values.first, let last = values.last, let lo = values.min(), let hi = values.max() else { return "No data" }
        let f = { formatNumber($0, format: format) }
        return "Trend from \(f(first)) to \(f(last)), low \(f(lo)), high \(f(hi))"
    }

    internal static let textHex: (dark: UInt32, light: UInt32) = (0xECEEEF, 0x1A1D21)
}

// MARK: - Surfaces

public extension View {
    /// A 2.0 glass panel: padding, full width, the glass surface with 12 pt continuous corners.
    func lgPanel(padding: CGFloat = LadaGlass.Spacing.l) -> some View {
        self.padding(padding * LadaGlass.Density.paddingScale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(LGGlass(cornerRadius: LadaGlass.Radius.card))
    }

    /// The 2.0 glass surface without padding or sizing: frosted material, a vertical fill gradient,
    /// a 1 pt edge, a top highlight and a layered soft shadow.
    func lgSurface(cornerRadius: CGFloat = LadaGlass.Radius.card) -> some View {
        modifier(LGGlass(cornerRadius: cornerRadius))
    }

    /// The 2.0 surface for a system sheet or inspector (the drawer / bottom-sheet recipe).
    func lgSheetSurface() -> some View {
        self.scrollContentBackground(.hidden)
            .background { LGGlassFill().ignoresSafeArea() }
            .presentationBackground { LGGlassFill() }
    }

    /// The 2.0 surface inside a native popover.
    func lgPopoverSurface() -> some View {
        self.padding(LadaGlass.Spacing.m).background { LGGlassFill().ignoresSafeArea() }
    }

    /// Page background: the calm backdrop the glass frosts.
    func lgBackdrop() -> some View { background(LGBackdrop().ignoresSafeArea()) }

    /// Applies `animation` unless Reduce Motion is on.
    func lgMotion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(LGReducibleAnimation(animation: animation, value: value))
    }

    /// Compact controls and rows.
    func lgCompact() -> some View {
        self.controlSize(.small).environment(\.defaultMinListRowHeight, LadaGlass.Density.rowHeight)
    }
}

/// Material plus the glass gradient, no edge or shadow (sheets, popovers, and inside LGGlass).
private struct LGGlassFill: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.thinMaterial)   // turns solid with Reduce Transparency
            LinearGradient(colors: [LadaGlass.Glass.fillTop.color, LadaGlass.Glass.fillBottom.color],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

private struct LGGlass: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background { LGGlassFill().clipShape(shape) }
            .clipShape(shape)
            // the top light: a 1 pt line just inside the edge, fading out down the corners
            .overlay {
                shape.inset(by: 1.5).stroke(LadaGlass.Glass.highlight.color, lineWidth: 1)
                    .mask(alignment: .top) {
                        LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: max(cornerRadius, 4))
                    }
                    .allowsHitTesting(false)
            }
            .overlay { shape.strokeBorder(LadaGlass.Glass.edge.color, lineWidth: 1).allowsHitTesting(false) }
            // layered shadow: a tight contact shadow and a soft, lower one
            .shadow(color: LadaGlass.Glass.shadow.color.opacity(0.25), radius: 1, y: 1)
            .shadow(color: LadaGlass.Glass.shadow.color.opacity(0.55), radius: 14, y: 8)
    }
}

private struct LGBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        ZStack {
            LinearGradient(colors: [LadaGlass.Colors.backdropFrom, LadaGlass.Colors.backdropTo],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [LadaGlass.accent.color.opacity(dark ? 0.30 : 0.26), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 700)
            RadialGradient(colors: [LadaGlass.accent2.color.opacity(dark ? 0.18 : 0.22), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 600)
        }
    }
}

private struct LGReducibleAnimation<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

// MARK: - Controls

/// Buttons in the 2.0 look: `.buttonStyle(.lg(.primary))`. Primary is lit (a gradient from the
/// accent, an inner top highlight and an accent glow); secondary is a quiet field; ghost is accent
/// text; danger a red tint. Pressed buttons shrink slightly (dim instead under Reduce Motion).
public struct LGButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case primary, secondary, ghost, danger }
    let kind: Kind
    public init(_ kind: Kind = .secondary) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        LGButtonBody(kind: kind, label: configuration.label, isPressed: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == LGButtonStyle {
    static func lg(_ kind: LGButtonStyle.Kind = .secondary) -> LGButtonStyle { LGButtonStyle(kind) }
}

private struct LGButtonBody<Label: View>: View {
    let kind: LGButtonStyle.Kind
    let label: Label
    let isPressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LadaGlass.Radius.control, style: .continuous)
        let dark = colorScheme == .dark
        label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(minHeight: 28)
            .foregroundStyle(foreground)
            .background { background(shape, dark: dark) }
            .overlay { border(shape, dark: dark) }
            .shadow(color: kind == .primary && isEnabled ? LadaGlass.accent.color.opacity((dark ? LadaGlass.Glass.glow.dark : LadaGlass.Glass.glow.light) * 1.7) : .clear,
                    radius: 7, y: 4)
            .contentShape(shape)
            .brightness(isPressed ? -0.06 : (hovered && kind == .primary ? 0.04 : 0))
            .scaleEffect(isPressed && !reduceMotion && isEnabled ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : LadaGlass.Motion.quick, value: isPressed)
            .animation(reduceMotion ? nil : LadaGlass.Motion.quick, value: hovered)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return LadaGlass.Colors.onAccent
        case .secondary: return LadaGlass.Colors.text
        case .ghost: return LadaGlass.accent.color
        case .danger: return LadaGlass.Colors.badText
        }
    }

    @ViewBuilder private func background(_ shape: RoundedRectangle, dark: Bool) -> some View {
        switch kind {
        case .primary:
            // Toward the text colour, so on-accent contrast never drops below the solid accent's.
            let a = LadaGlass.accent.hex, t = LadaGlass.textHex
            shape.fill(LinearGradient(colors: [
                LadaGlass.adaptive(dark: LadaGlass.mix(a.dark, t.dark, 0.84), light: a.light),
                LadaGlass.adaptive(dark: a.dark, light: LadaGlass.mix(a.light, t.light, 0.86)),
            ], startPoint: .top, endPoint: .bottom))
        case .secondary:
            shape.fill(dark ? Color.white.opacity(0.04) : Color(red: 20 / 255, green: 24 / 255, blue: 32 / 255).opacity(0.03))
        case .ghost:
            shape.fill(hovered ? LadaGlass.accent.color.opacity(0.10) : .clear)
        case .danger:
            shape.fill(LadaGlass.Colors.bad.opacity(0.14))
        }
    }

    @ViewBuilder private func border(_ shape: RoundedRectangle, dark: Bool) -> some View {
        let topLight = LinearGradient(colors: [kind == .primary ? .white.opacity(0.28) : LadaGlass.Glass.highlight.color, .clear],
                                      startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.25))
        switch kind {
        case .primary:
            shape.inset(by: 0.5).stroke(topLight, lineWidth: 1)
        case .secondary:
            let line = dark ? Color.white.opacity(0.15) : Color(red: 20 / 255, green: 24 / 255, blue: 32 / 255).opacity(0.16)
            ZStack {
                shape.inset(by: 1).stroke(topLight, lineWidth: 1)
                shape.strokeBorder(hovered && isEnabled ? LadaGlass.accent.color.opacity(0.55) : line, lineWidth: 1)
            }
        case .ghost:
            EmptyView()
        case .danger:
            shape.strokeBorder(LadaGlass.Colors.bad.opacity(0.26), lineWidth: 1)
        }
    }
}

/// A status chip: a pill with a 12 % status tint and a thin tinted outline (neutral: 5 % muted),
/// a dot in the status colour, and the label in its AA text colour.
public struct LGChip: View {
    public enum Status: Sendable { case ok, warn, bad, neutral }
    let label: String
    let status: Status
    public init(_ label: String, status: Status = .neutral) { self.label = label; self.status = status }

    public var body: some View {
        let (dot, text): (Color, Color) = {
            switch status {
            case .ok: return (LadaGlass.Colors.ok, LadaGlass.Colors.okText)
            case .warn: return (LadaGlass.Colors.warn, LadaGlass.Colors.warnText)
            case .bad: return (LadaGlass.Colors.bad, LadaGlass.Colors.badText)
            case .neutral: return (LadaGlass.Colors.muted, LadaGlass.Colors.muted)
            }
        }()
        let neutral = status == .neutral
        HStack(spacing: 5) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(text)
        }
        .padding(.horizontal, 8).padding(.vertical, 1)
        .background(dot.opacity(neutral ? 0.05 : 0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(dot.opacity(neutral ? 0.22 : 0.26), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Animated numbers

/// A KPI number that rolls to its new value (.numericText), with an optional change badge.
/// Instant under Reduce Motion.
public struct LGNumber: View {
    let value: Double
    let format: FloatingPointFormatStyle<Double>
    let showsDelta: Bool
    @State private var delta: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(value: Double, format: FloatingPointFormatStyle<Double> = .number, showsDelta: Bool = false) {
        self.value = value; self.format = format; self.showsDelta = showsDelta
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LadaGlass.Spacing.s) {
            Text(LadaGlass.formatNumber(value, format: format))
                .font(LadaGlass.Typography.kpi)
                .contentTransition(reduceMotion ? .identity : .numericText(value: value))
                .animation(reduceMotion ? nil : LadaGlass.Motion.data, value: value)
            if showsDelta, let delta { LGDelta(delta, format: format) }
        }
        .onChange(of: value) { old, new in delta = new - old }
    }
}

/// A change badge: +n green, −n red (U+2212), n grey for no change.
public struct LGDelta: View {
    let diff: Double
    let format: FloatingPointFormatStyle<Double>
    public init(_ diff: Double, format: FloatingPointFormatStyle<Double> = .number) { self.diff = diff; self.format = format }

    public var body: some View {
        let dir = LadaGlass.DeltaDirection(diff)
        let (tone, text): (Color, Color) = {
            switch dir {
            case .up: return (LadaGlass.Colors.ok, LadaGlass.Colors.okText)
            case .down: return (LadaGlass.Colors.bad, LadaGlass.Colors.badText)
            case .flat: return (LadaGlass.Colors.muted, LadaGlass.Colors.muted)
            }
        }()
        let abs = Swift.abs(diff).formatted(format)
        Text(LadaGlass.formatDelta(diff, format: format))
            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            .foregroundStyle(text)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(tone.opacity(dir == .flat ? 0.08 : 0.12), in: Capsule())
            .accessibilityLabel(dir == .up ? "Up \(abs)" : dir == .down ? "Down \(abs)" : "No change")
    }
}

// MARK: - Charts (Swift Charts)

public extension ChartContent {
    /// A distinct symbol and line dash per series (index from 0), so a chart never relies on colour
    /// alone. Colour the series with .chartForegroundStyleScale(range: LadaGlass.chartColors()).
    func lgChartSeriesStyle(index: Int) -> some ChartContent {
        let style = LadaGlass.seriesStyle(index: index)
        return self.symbol(style.symbol.shape)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: style.dash))
    }
}

/// A small line chart for KPI cards; VoiceOver reads a summary (first, last, low, high).
public struct LGSparkline: View {
    let values: [Double]
    let color: Color?
    public init(values: [Double], color: Color? = nil) { self.values = values; self.color = color }

    public var body: some View {
        let c = color ?? LadaGlass.accent.color
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let domain = lo == hi ? (lo - 1)...(hi + 1) : lo...hi
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                AreaMark(x: .value("Index", i), yStart: .value("Low", domain.lowerBound), yEnd: .value("Value", v))
                    .foregroundStyle(LinearGradient(colors: [c.opacity(0.25), c.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Index", i), y: .value("Value", v))
                    .foregroundStyle(c)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
        .chartYScale(domain: domain)
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel(LadaGlass.sparklineSummary(values))
    }
}

// MARK: - Toasts

public enum LGToastType: Sendable { case info, ok, bad, loading }

public struct LGToast: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var type: LGToastType
    public var description: String?
    /// Seconds left while paused or not yet started (infinity: stays until updated or dismissed).
    var remaining: TimeInterval = .infinity
    /// When it goes, on the centre's clock (nil: paused or persistent).
    var deadline: TimeInterval?
}

/// One toast's place in the stack (newest last), as LadaGlass.toast.offsets on the web.
public struct LGToastOffset: Equatable, Sendable {
    public var y: CGFloat
    public var scale: CGFloat
    public var opacity: Double
    public init(y: CGFloat, scale: CGFloat, opacity: Double) { self.y = y; self.scale = scale; self.opacity = opacity }
}

/// Sonner-style toasts. Keep one centre (e.g. in the app's state), put `.lgToasts(center)` on the
/// window's root view, and call `center.show("Saved", type: .ok)`. Toasts auto-dismiss after 4 s
/// (paused while the pointer is over them); loading toasts and duration 0 stay until updated or
/// dismissed. Each toast is announced to VoiceOver.
@MainActor @Observable public final class LGToastCenter {
    public nonisolated static let maxVisible = 3
    public nonisolated static let defaultDuration: TimeInterval = 4

    public private(set) var toasts: [LGToast] = []
    /// The newest three, oldest first.
    public var visible: [LGToast] { Array(toasts.suffix(Self.maxVisible)) }
    /// Fanned out (pointer over the stack): timers pause.
    public var isExpanded = false {
        didSet {
            guard oldValue != isExpanded else { return }
            let t = now()
            for i in toasts.indices {
                if isExpanded, let d = toasts[i].deadline {
                    toasts[i].remaining = max(0, d - t); toasts[i].deadline = nil
                } else if !isExpanded, toasts[i].remaining.isFinite {
                    toasts[i].deadline = t + toasts[i].remaining
                }
            }
            schedule()
        }
    }

    @ObservationIgnored private let now: @MainActor () -> TimeInterval
    @ObservationIgnored private let timers: Bool
    @ObservationIgnored private let announce: @MainActor (_ text: String, _ urgent: Bool) -> Void
    @ObservationIgnored private var timerTask: Task<Void, Never>?

    /// - Parameters:
    ///   - now: the clock in seconds (tests inject one).
    ///   - timers: schedule auto-dismissal; with false, call `tick()` yourself (tests).
    ///   - announce: how a toast is spoken, and whether it is urgent (bad toasts); default: a VoiceOver
    ///     announcement, high priority when urgent.
    public init(now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                timers: Bool = true,
                announce: @escaping @MainActor (_ text: String, _ urgent: Bool) -> Void = LGToastCenter.voiceOver) {
        self.now = now; self.timers = timers; self.announce = announce
    }

    /// Posts a VoiceOver announcement; urgent ones (bad toasts, as role="alert" on the web) get high priority.
    public static func voiceOver(_ text: String, urgent: Bool) {
        var s = AttributedString(text)
        s.accessibilitySpeechAnnouncementPriority = urgent ? .high : .default
        AccessibilityNotification.Announcement(s).post()
    }

    /// Whether an auto-dismiss timer is scheduled (tests).
    var hasPendingTimer: Bool { timerTask != nil }

    @discardableResult
    public func show(_ title: String, type: LGToastType = .info, description: String? = nil, duration: TimeInterval? = nil) -> LGToast.ID {
        var t = LGToast(id: UUID(), title: title, type: type, description: description)
        arm(&t, duration)
        toasts.append(t)
        speak(t)
        schedule()
        return t.id
    }

    /// Changes a toast in place (same place in the stack) and restarts its timer with the new type's duration.
    public func update(id: LGToast.ID, _ title: String, type: LGToastType = .info, description: String? = nil, duration: TimeInterval? = nil) {
        guard let i = toasts.firstIndex(where: { $0.id == id }) else { return }
        toasts[i].title = title; toasts[i].type = type; toasts[i].description = description
        arm(&toasts[i], duration)
        speak(toasts[i])
        schedule()
    }

    public func dismiss(id: LGToast.ID) {
        toasts.removeAll { $0.id == id }
        if toasts.isEmpty { isExpanded = false }
        schedule()
    }

    /// Removes the toasts whose time is up (the scheduled timer calls this).
    public func tick() {
        let t = now() + 1e-6
        let before = toasts.count
        toasts.removeAll { $0.deadline.map { $0 <= t } ?? false }
        if toasts.count != before && toasts.isEmpty { isExpanded = false }
        schedule()
    }

    /// A loading toast that turns ok (success's text; dismissed without one) or bad (error's text).
    public func promise<T>(loading: String = "Loading…", success: ((T) -> String)? = nil, error: ((any Error) -> String)? = nil,
                           _ operation: @MainActor () async throws -> T) async throws -> T {
        let id = show(loading, type: .loading)
        do {
            let value = try await operation()
            if let success { update(id: id, success(value), type: .ok) } else { dismiss(id: id) }
            return value
        } catch let e {
            update(id: id, error?(e) ?? (e as? LocalizedError)?.errorDescription ?? "Failed", type: .bad)
            throw e
        }
    }

    /// Stack layout (pure, as the web's toast.offsets): collapsed, each older toast peeks 10 pt
    /// above and 5 % smaller; expanded, they fan out by height + 8. Beyond three: opacity 0.
    public nonisolated static func offsets(_ count: Int, _ expanded: Bool, _ height: CGFloat) -> [LGToastOffset] {
        (0..<max(0, count)).map { i in
            let k = count - 1 - i
            let step = expanded ? height + 8 : 10
            return LGToastOffset(y: k == 0 ? 0 : -CGFloat(k) * step,
                                 scale: expanded ? 1 : ((1 - CGFloat(k) * 0.05) * 1000).rounded() / 1000,
                                 opacity: k >= maxVisible ? 0 : 1)
        }
    }

    private func arm(_ t: inout LGToast, _ duration: TimeInterval?) {
        let d = duration.map { $0 >= 0 ? $0 : Self.defaultDuration } ?? Self.defaultDuration
        t.remaining = t.type == .loading || d == 0 ? .infinity : d
        t.deadline = isExpanded || !t.remaining.isFinite ? nil : now() + t.remaining
    }

    private func speak(_ t: LGToast) {
        let urgent = t.type == .bad
        if let d = t.description, !d.isEmpty { announce("\(t.title). \(d)", urgent) } else { announce(t.title, urgent) }
    }

    private func schedule() {
        guard timers else { return }
        timerTask?.cancel()
        guard let next = toasts.compactMap(\.deadline).min() else { timerTask = nil; return }
        let wait = max(0, next - now())
        timerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }
}

public extension View {
    /// Shows `center`'s toasts in the bottom-trailing corner.
    func lgToasts(_ center: LGToastCenter) -> some View {
        overlay(alignment: .bottomTrailing) { LGToaster(center: center).padding(LadaGlass.Spacing.l) }
    }
}

// MARK: - System notifications

/// Where `LadaGlass.SystemNotifications` sends a notification: the injectable part, so the routing can
/// be tested without the notification system. `LGUserNotificationSender` is the real one.
@MainActor public protocol LGNotificationSender {
    func requestAuthorization() async -> Bool
    /// Whether the user allows alerts now (they can turn them off in System Settings at any time).
    func isAuthorized() async -> Bool
    func send(title: String, body: String, identifier: String) async
}

/// Real macOS notifications through UserNotifications. `UNUserNotificationCenter.current()` needs a
/// bundled app (it traps in a bare executable or `swift test`), so tests inject a fake sender.
/// Alerts and sound only: no Dock badge.
public struct LGUserNotificationSender: LGNotificationSender {
    public init() {}
    public func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
    public func isAuthorized() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }
    public func send(title: String, body: String, identifier: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}

public extension LadaGlass {
    /// macOS system notifications for events that finish while the app is in the background (a scan,
    /// a sync), with the in-app toast while it is in front. Ask once, e.g. on the first scan:
    ///
    ///     let notify = LadaGlass.SystemNotifications(toasts: toastCenter)
    ///     _ = await notify.requestAuthorization()
    ///     await notify.post(title: "Scan finished", body: "3 findings", type: .ok)
    ///
    /// The default rule (`defaultPolicy`): post to the system only when the app is not active;
    /// otherwise show a toast in `toasts`. Pass `policy` to change it. With no toast centre, a
    /// notification meant for a toast goes to the system; when the user hasn't allowed (or has turned
    /// off) notifications, one meant for the system becomes a toast, so nothing is dropped silently
    /// (`.none` is returned when neither is possible).
    @MainActor final class SystemNotifications {
        public enum Route: Equatable, Sendable { case system, toast, none }
        /// Decides the route from whether the app is active.
        public typealias Policy = @MainActor (_ appIsActive: Bool) -> Route

        public nonisolated static func defaultPolicy(_ appIsActive: Bool) -> Route { appIsActive ? .toast : .system }

        private let sender: any LGNotificationSender
        private let toasts: LGToastCenter?
        private let isAppActive: @MainActor () -> Bool
        private let policy: Policy

        /// - Parameter sender: where system notifications go; nil: `LGUserNotificationSender()` (tests inject a fake).
        public init(sender: (any LGNotificationSender)? = nil, toasts: LGToastCenter? = nil,
                    isAppActive: @escaping @MainActor () -> Bool = { NSApplication.shared.isActive },
                    policy: @escaping Policy = SystemNotifications.defaultPolicy) {
            self.sender = sender ?? LGUserNotificationSender(); self.toasts = toasts; self.isAppActive = isAppActive; self.policy = policy
        }

        /// Asks for permission to show alerts (the system asks the user once).
        public func requestAuthorization() async -> Bool { await sender.requestAuthorization() }

        /// Posts `title` and `body` where the policy says, and returns where it went. `type` is the
        /// toast's type when it becomes a toast (an empty body is no description).
        @discardableResult
        public func post(title: String, body: String, identifier: String = UUID().uuidString, type: LGToastType = .info) async -> Route {
            var route = policy(isAppActive())
            if route == .toast && toasts == nil { route = .system }
            if route == .system, !(await sender.isAuthorized()) { route = toasts == nil ? .none : .toast }
            switch route {
            case .system: await sender.send(title: title, body: body, identifier: identifier)
            case .toast: toasts?.show(title, type: type, description: body.isEmpty ? nil : body)
            case .none: break
            }
            return route
        }
    }
}

private struct LGToastHeights: PreferenceKey {
    static let defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct LGToaster: View {
    let center: LGToastCenter
    @State private var heights: [UUID: CGFloat] = [:]
    @State private var hovered = false
    /// Keyboard focus (a toast's ×) and VoiceOver focus inside the stack pause the timers, like hover
    /// (WCAG 2.2.1; the web pauses on focus too).
    @FocusState private var keyboardFocus: UUID?
    @AccessibilityFocusState private var voiceOverFocus: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let width: CGFloat = 340

    var body: some View {
        let shown = center.visible
        let expanded = center.isExpanded
        let h = shown.compactMap { heights[$0.id] }.max() ?? 60
        let front = shown.last.flatMap { heights[$0.id] }
        let offsets = LGToastCenter.offsets(shown.count, expanded, h)
        ZStack(alignment: .bottom) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, toast in
                let behind = !expanded && i < shown.count - 1
                LGToastView(toast: toast, behind: behind, height: behind ? front : nil, reduceMotion: reduceMotion,
                            keyboardFocus: $keyboardFocus, voiceOverFocus: $voiceOverFocus) {
                    center.dismiss(id: toast.id)
                }
                .scaleEffect(offsets[i].scale, anchor: .bottom)
                .offset(y: offsets[i].y)
                .opacity(offsets[i].opacity)
                .zIndex(Double(i))
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: width, height: expanded && !shown.isEmpty ? CGFloat(shown.count) * (h + 8) : nil, alignment: .bottom)
        .contentShape(Rectangle())
        .onHover { hovered = $0; syncExpanded() }
        .onChange(of: keyboardFocus) { syncExpanded() }
        .onChange(of: voiceOverFocus) { syncExpanded() }
        .onPreferenceChange(LGToastHeights.self) { value in
            MainActor.assumeIsolated { heights = value }
        }
        .animation(reduceMotion ? nil : LadaGlass.Motion.standard, value: center.toasts)
        .animation(reduceMotion ? nil : LadaGlass.Motion.standard, value: expanded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notifications")
    }

    private func syncExpanded() {
        center.isExpanded = (hovered || keyboardFocus != nil || voiceOverFocus != nil) && !center.toasts.isEmpty
    }
}

private struct LGToastView: View {
    let toast: LGToast
    let behind: Bool
    let height: CGFloat?
    let reduceMotion: Bool
    var keyboardFocus: FocusState<UUID?>.Binding
    var voiceOverFocus: AccessibilityFocusState<UUID?>.Binding
    let onDismiss: () -> Void
    @State private var dragX: CGFloat = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LadaGlass.Radius.card, style: .continuous)
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 16, height: 16).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(LadaGlass.Colors.text)
                if let d = toast.description, !d.isEmpty {
                    Text(d).font(.system(size: 12)).foregroundStyle(LadaGlass.Colors.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityFocused(voiceOverFocus, equals: toast.id)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(LadaGlass.Colors.muted)
            .accessibilityLabel("Dismiss")
            .focused(keyboardFocus, equals: toast.id)
            .accessibilityFocused(voiceOverFocus, equals: toast.id)
        }
        .padding(LadaGlass.Spacing.m)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { p in Color.clear.preference(key: LGToastHeights.self, value: behind ? [:] : [toast.id: p.size.height]) })
        .opacity(behind ? 0 : 1)   // a toast behind the front one shows only its edge
        .frame(height: height, alignment: .top)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) { Rectangle().fill(tone).frame(width: 3).accessibilityHidden(true) }   // accent stripe
        .lgSurface()
        .clipShape(shape)
        .offset(x: dragX)
        .opacity(Double(max(0, 1 - dragX / 250)))
        .gesture(DragGesture(minimumDistance: 4)
            .onChanged { dragX = max(0, $0.translation.width) }
            .onEnded { _ in
                if dragX >= 90 { onDismiss() } else if reduceMotion { dragX = 0 } else { withAnimation(LadaGlass.Motion.standard) { dragX = 0 } }
            })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(toast.description.map { "\(toast.title). \($0)" } ?? toast.title)
        .accessibilityHidden(behind)
        .accessibilityAction(named: "Dismiss", onDismiss)
    }

    private var tone: Color {
        switch toast.type {
        case .ok: return LadaGlass.Colors.ok
        case .bad: return LadaGlass.Colors.bad
        case .info, .loading: return LadaGlass.accent.color
        }
    }

    @ViewBuilder private var icon: some View {
        switch toast.type {
        case .loading: ProgressView().controlSize(.small).scaleEffect(0.8)
        case .ok: Image(systemName: "checkmark.circle").foregroundStyle(LadaGlass.Colors.ok)
        case .bad: Image(systemName: "exclamationmark.circle").foregroundStyle(LadaGlass.Colors.bad)
        case .info: Image(systemName: "info.circle").foregroundStyle(LadaGlass.accent.color)
        }
    }
}

// MARK: - Command palette

/// A palette command. `run` is called after the palette has closed.
public struct LGCommand: Identifiable {
    public let id = UUID()
    public var label: String
    public var group: String?
    public var keywords: [String]
    /// Shown as a key cap, e.g. "⌘E" (display only; bind the shortcut in the app's menus).
    public var shortcut: String?
    public var run: @MainActor () -> Void

    public init(_ label: String, group: String? = nil, keywords: [String] = [], shortcut: String? = nil, run: @escaping @MainActor () -> Void) {
        self.label = label; self.group = group; self.keywords = keywords; self.shortcut = shortcut; self.run = run
    }
}

public struct LGCommandGroup: Identifiable {
    public var name: String
    public var commands: [LGCommand]
    public var id: String { name }
}

public extension View {
    /// A command palette: ⌘K toggles it; type to filter (LadaGlass.fuzzy), ↑↓ to move, Return runs,
    /// Esc closes. Put it on the window's root view.
    func lgCommandPalette(isPresented: Binding<Bool>, commands: [LGCommand], placeholder: String = "Type a command or search…") -> some View {
        modifier(LGCommandPaletteModifier(isPresented: isPresented, commands: commands, placeholder: placeholder))
    }
}

private struct LGCommandPaletteModifier: ViewModifier {
    @Binding var isPresented: Bool
    let commands: [LGCommand]
    let placeholder: String

    func body(content: Content) -> some View {
        content
            .background {
                // ⌘K: a zero-size button carries the shortcut (a hidden() view would drop it).
                Button("Command palette") { isPresented.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                    .opacity(0).frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .overlay {
                if isPresented {
                    LGPalette(isPresented: $isPresented, commands: commands, placeholder: placeholder)
                }
            }
    }
}

private struct LGPalette: View {
    @Binding var isPresented: Bool
    let commands: [LGCommand]
    let placeholder: String
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        let groups = LadaGlass.filterCommands(commands, query: query)
        let flat = groups.flatMap(\.commands)
        ZStack(alignment: .top) {
            Color.black.opacity(0.25).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                TextField("Command", text: $query, prompt: Text(placeholder))
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .padding(LadaGlass.Spacing.m)
                    .focused($focused)
                    .accessibilityLabel("Command")
                    // On the field itself: its field editor would otherwise take ↑↓ (moveUp:/moveDown:)
                    // before an ancestor's handler sees them.
                    .onKeyPress(.downArrow) { if !flat.isEmpty { selection = (selection + 1) % flat.count }; return .handled }
                    .onKeyPress(.upArrow) { if !flat.isEmpty { selection = (selection - 1 + flat.count) % flat.count }; return .handled }
                    .onKeyPress(.return) { run(flat, selection); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                Divider().opacity(0.6)
                if flat.isEmpty {
                    Text("No results").font(LadaGlass.Typography.body).foregroundStyle(LadaGlass.Colors.muted)
                        .padding(LadaGlass.Spacing.l)
                        .accessibilityAddTraits(.updatesFrequently)
                } else {
                    list(groups, flat: flat)
                }
            }
            .frame(width: 560)
            .lgSurface(cornerRadius: LadaGlass.Radius.sheet)
            .padding(.top, 70)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Command palette")
            .accessibilityAddTraits(.isModal)
        }
        .defaultFocus($focused, true)
        // An overlay may appear before it is in a window: focus the field once it is.
        .task { await Task.yield(); focused = true }
        .onChange(of: query) { selection = 0 }
        .onExitCommand { close() }
    }

    private func list(_ groups: [LGCommandGroup], flat: [LGCommand]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(groups) { group in
                        if !group.name.isEmpty {
                            Text(group.name).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                                .padding(.horizontal, LadaGlass.Spacing.s).padding(.top, LadaGlass.Spacing.s)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(group.commands) { cmd in
                            let n = flat.firstIndex { $0.id == cmd.id } ?? 0
                            row(cmd, selected: n == selection) { run(flat, n) }
                                .id(cmd.id)
                                .onHover { if $0 { selection = n } }
                        }
                    }
                }
                .padding(LadaGlass.Spacing.s)
            }
            .frame(maxHeight: 340)
            .onChange(of: selection) { _, n in
                if flat.indices.contains(n) { proxy.scrollTo(flat[n].id) }
            }
        }
    }

    private func row(_ cmd: LGCommand, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(cmd.label).font(LadaGlass.Typography.body).foregroundStyle(LadaGlass.Colors.text)
                Spacer(minLength: LadaGlass.Spacing.m)
                if let s = cmd.shortcut {
                    Text(s).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(LadaGlass.Colors.muted)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(LadaGlass.Colors.muted.opacity(0.12), in: RoundedRectangle(cornerRadius: LadaGlass.Radius.small))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(selected ? LadaGlass.accent.color.opacity(0.16) : .clear,
                        in: RoundedRectangle(cornerRadius: LadaGlass.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(cmd.shortcut.map { "\(cmd.label), \($0)" } ?? cmd.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func close() { isPresented = false }

    private func run(_ flat: [LGCommand], _ i: Int) {
        guard flat.indices.contains(i) else { return }
        let action = flat[i].run
        close()
        Task { @MainActor in action() }   // after the palette has closed
    }
}
