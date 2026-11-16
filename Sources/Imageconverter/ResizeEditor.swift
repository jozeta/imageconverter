import SwiftUI
import ImageconverterCore

/// The resize step's editor: a grouped mode picker, the fields for that mode, presets, resampling and DPI.
struct ResizeEditor: View {
    @Binding var options: ResizeOptions

    enum Kind: String, CaseIterable {
        case maxWidth = "Max width", maxHeight = "Max height", fitBox = "Fit inside"
        case exactWidth = "Exact width", exactHeight = "Exact height", exactSize = "Exact size"
        case longestEdge = "Longest edge", shortestEdge = "Shortest edge", minimum = "Minimum size"
        case percent = "Percentage", physical = "Physical size", printSheet = "Print sheet"
        case mlEnlarge = "Enlarge with machine learning"
    }

    /// ML enlarge is offered on macOS 26 and later on Macs that can run the model; a step that already uses it
    /// stays shown (with the reason).
    private var offersMLEnlarge: Bool {
        kind == .mlEnlarge || MLEnlargeModel.shared.availability.offersMode
    }

    private static let pixelKinds: [Kind] = [.maxWidth, .maxHeight, .fitBox, .exactSize, .longestEdge,
                                             .shortestEdge, .minimum]

    private var kind: Kind {
        switch options.mode {
        case .maxWidth: return .maxWidth
        case .maxHeight: return .maxHeight
        case .fitBox: return .fitBox
        case .exactWidth: return .exactWidth
        case .exactHeight: return .exactHeight
        case .exactSize: return .exactSize
        case .longestEdge: return .longestEdge
        case .shortestEdge: return .shortestEdge
        case .minimum: return .minimum
        case .percent: return .percent
        case .physical: return .physical
        case .printSheet: return .printSheet
        case .mlEnlarge: return .mlEnlarge
        }
    }

    /// The pixel sizes the current mode implies; other modes start from a 1600 px box.
    private var pixels: (width: Int, height: Int) {
        switch options.mode {
        case .maxWidth(let side), .maxHeight(let side), .exactWidth(let side), .exactHeight(let side),
             .longestEdge(let side), .shortestEdge(let side):
            return (side, side)
        case .fitBox(let wide, let high), .exactSize(let wide, let high, _), .minimum(let wide, let high):
            return (wide, high)
        case .percent, .physical, .printSheet, .mlEnlarge:
            return (1600, 1600)
        }
    }

    private var fill: ExactFill {
        if case .exactSize(_, _, let value) = options.mode { return value }
        return .stretch
    }

    private var percent: Double {
        if case .percent(let value) = options.mode { return value }
        return 50
    }

    private struct Print {
        var width: Double?
        var height: Double?
        var unit: PhysicalUnit
        var dpi: Double
    }

    private var physical: Print {
        if case .physical(let wide, let high, let unit, let dpi) = options.mode {
            return Print(width: wide, height: high, unit: unit, dpi: dpi)
        }
        return Print(width: 21, height: nil, unit: .centimetre, dpi: 300)
    }

    // One case per mode.
    // swiftlint:disable:next cyclomatic_complexity
    private func set(_ kind: Kind, width: Int, height: Int, fill: ExactFill) {
        switch kind {
        case .maxWidth: options.mode = .maxWidth(width)
        case .maxHeight: options.mode = .maxHeight(height)
        case .fitBox: options.mode = .fitBox(width: width, height: height)
        case .exactWidth: options.mode = .exactWidth(width)
        case .exactHeight: options.mode = .exactHeight(height)
        case .exactSize: options.mode = .exactSize(width: width, height: height, fill: fill)
        case .longestEdge: options.mode = .longestEdge(max(width, height))
        case .shortestEdge: options.mode = .shortestEdge(min(width, height))
        case .minimum: options.mode = .minimum(width: width, height: height)
        case .percent: options.mode = .percent(percent)
        case .physical:
            let current = physical
            options.mode = .physical(width: current.width, height: current.height, unit: current.unit, dpi: current.dpi)
        case .printSheet:
            let current = PrintSheetFields.current(of: options)
            options.mode = .printSheet(long: current.long, short: current.short, unit: current.unit, dpi: current.dpi)
        case .mlEnlarge: options.mode = .mlEnlarge(factor: 2)
        }
    }

    /// Modes where "don't enlarge" has no meaning: they name the size outright or only ever enlarge.
    private var ignoresEnlargeRule: Bool {
        switch kind {
        case .percent, .physical, .printSheet, .minimum, .mlEnlarge: return true
        case .exactSize: return fill == .stretch
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            HStack {
                Picker("Mode", selection: Binding(
                    get: { kind },
                    set: { set($0, width: pixels.width, height: pixels.height, fill: fill) })) {
                    Section("Pixels") {
                        ForEach(Self.pixelKinds, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Section("Scale") { Text(Kind.percent.rawValue).tag(Kind.percent) }
                    Section("Print") {
                        Text(Kind.physical.rawValue).tag(Kind.physical)
                        Text(Kind.printSheet.rawValue).tag(Kind.printSheet)
                    }
                    if offersMLEnlarge {
                        Section("Machine learning") { Text(Kind.mlEnlarge.rawValue).tag(Kind.mlEnlarge) }
                    }
                    // Older saved presets can hold these; keep them shown rather than silently replaced.
                    if kind == .exactWidth || kind == .exactHeight {
                        Section("Other") { Text(kind.rawValue).tag(kind) }
                    }
                }
                .accessibilityLabel("Resize mode")
                presetsMenu
            }
            fields
            Text(help)
                .font(LadaGlass.Typography.label)
                .foregroundStyle(LadaGlass.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
            if !ignoresEnlargeRule {
                Toggle("Don't enlarge smaller images", isOn: Binding(
                    get: { !options.allowEnlarge }, set: { options.allowEnlarge = !$0 }))
            }
            if kind != .mlEnlarge {
                Picker("Resampling", selection: $options.resampling) {
                    ForEach(Resampling.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .accessibilityLabel("Resampling")
            }
            dpiRow
        }
    }

    // MARK: Fields

    @ViewBuilder private var fields: some View {
        switch kind {
        case .percent:
            DecimalField(title: "Percentage", value: Binding(
                get: { percent }, set: { options.mode = .percent(min(max($0, 1), 1000)) }), suffix: "%")
        case .physical:
            physicalFields
        case .printSheet:
            PrintSheetFields(options: $options)
        case .mlEnlarge:
            MLEnlargeControls(options: $options)
        case .longestEdge, .shortestEdge:
            NumberField(title: kind == .longestEdge ? "Longest edge" : "Shortest edge", value: Binding(
                get: { pixels.width }, set: { set(kind, width: $0, height: $0, fill: fill) }))
        default:
            pixelFields
        }
        if kind == .exactSize {
            Picker("Fill", selection: Binding(
                get: { fill },
                set: { set(kind, width: pixels.width, height: pixels.height, fill: $0) })) {
                Text("Stretch (ignore aspect ratio)").tag(ExactFill.stretch)
                Text("Fit inside, pad").tag(ExactFill.fitAndPad)
                Text("Fill, crop edges").tag(ExactFill.fillAndCrop)
            }
            .accessibilityLabel("Fill mode")
            if fill == .fitAndPad {
                ColorField(title: "Pad color", color: $options.padColor)
            }
            if fill == .fillAndCrop {
                FocusPicker(focus: $options.focus)
            }
        }
    }

    private var pixelFields: some View {
        FieldRow {
            if [.maxWidth, .fitBox, .exactWidth, .exactSize, .minimum].contains(kind) {
                NumberField(title: "Width", value: Binding(
                    get: { pixels.width },
                    set: { set(kind, width: $0, height: pixels.height, fill: fill) }))
            }
            if [.maxHeight, .fitBox, .exactHeight, .exactSize, .minimum].contains(kind) {
                NumberField(title: "Height", value: Binding(
                    get: { pixels.height },
                    set: { set(kind, width: pixels.width, height: $0, fill: fill) }))
            }
        }
    }

    private var physicalFields: some View {
        let current = physical
        return VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            FieldRow {
                OptionalSideField(title: "Width", value: Binding(
                    get: { current.width },
                    set: { options.mode = .physical(width: $0, height: current.height, unit: current.unit, dpi: current.dpi) }),
                    other: current.height)
                OptionalSideField(title: "Height", value: Binding(
                    get: { current.height },
                    set: { options.mode = .physical(width: current.width, height: $0, unit: current.unit, dpi: current.dpi) }),
                    other: current.width)
                Picker("Unit", selection: Binding(
                    get: { current.unit },
                    set: { options.mode = .physical(width: current.width, height: current.height, unit: $0, dpi: current.dpi) })) {
                    ForEach(PhysicalUnit.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 80)
                .accessibilityLabel("Unit")
            }
            HStack(spacing: LadaGlass.Spacing.xs) {
                Text("Resolution").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                DecimalField(title: "DPI", value: Binding(
                    get: { current.dpi },
                    set: { options.mode = .physical(width: current.width, height: current.height, unit: current.unit,
                                                    dpi: min($0, ResizeOptions.dpiRange.upperBound)) }), suffix: "dpi")
            }
        }
    }

    // MARK: Presets, DPI, help

    private var presetsMenu: some View {
        Menu("Presets") {
            Menu("Print") {
                Menu("Photo (cm)") { presetButtons(SizePresets.printPhotoCentimetres) }
                Menu("Photo (in)") { presetButtons(SizePresets.printPhotoInches) }
                Menu("Paper") { presetButtons(SizePresets.printPaper) }
            }
            Menu("Web") { presetButtons(SizePresets.web) }
            Menu("Devices & wallpapers") { presetButtons(SizePresets.devices) }
            Menu("App & web assets") { presetButtons(SizePresets.assets) }
            Menu("Social media") { presetButtons(SizePresets.social) }
            Menu("Resolutions") { presetButtons(SizePresets.resolutions) }
        }
        .fixedSize()
        .accessibilityLabel("Size presets")
    }

    private func presetButtons(_ presets: [SizePreset]) -> some View {
        ForEach(presets) { preset in
            Button(preset.menuTitle) {
                options = preset.applied(to: options)
            }
        }
    }

    /// Print sizes carry their own DPI, so the separate setting is only for the other modes.
    @ViewBuilder private var dpiRow: some View {
        if kind != .physical {
            HStack {
                Toggle("Set DPI", isOn: Binding(
                    get: { options.dpi != nil }, set: { options.dpi = $0 ? 300 : nil }))
                if options.dpi != nil {
                    DecimalField(title: "DPI", value: Binding(
                        get: { options.dpi ?? 300 },
                        set: { options.dpi = min($0, ResizeOptions.dpiRange.upperBound) }), suffix: "dpi")
                }
            }
            if options.dpi != nil {
                Text("Only labels the file's print resolution; no pixels change.")
                    .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
            }
        }
    }
}

extension ResizeEditor {
    var help: String {
        switch kind {
        case .maxWidth, .maxHeight, .exactWidth, .exactHeight:
            return "The other side follows the aspect ratio."
        case .fitBox: return "Fits inside the box; the aspect ratio is kept."
        case .longestEdge, .shortestEdge: return "The other side follows the aspect ratio."
        case .minimum:
            return "Scales up until both sides reach at least this size; the aspect ratio is kept. Never shrinks."
        case .percent: return "Scales both sides by this percentage (1 to 1000), so it can enlarge."
        case .physical:
            return "Print size at this resolution. Leave a side empty to follow the aspect ratio; with both "
                + "sides set the image fits inside, keeping its aspect ratio. Can enlarge."
        case .printSheet:
            return "A print sheet at this resolution. The image fits inside it, turned the way round its own "
                + "orientation needs (a landscape photo goes into long × short, a portrait one into short × long). "
                + "Can enlarge."
        case .mlEnlarge:
            return "Enlarges 2×, 3× or 4× with Apple's super-resolution model, on this Mac (macOS 26 or later). "
                + "It adds detail that wasn't there, so check the results. A result over the "
                + "\(DecodeLimits.standard.maxPixels / 1_000_000) MP limit isn't made."
        case .exactSize:
            switch fill {
            case .stretch: return "Stretch changes the aspect ratio; every other mode keeps it."
            case .fitAndPad: return "Keeps the aspect ratio and pads the rest with a color."
            case .fillAndCrop: return "Keeps the aspect ratio and crops what overflows."
            }
        }
    }
}

/// A print-size side that may be left empty (follows the aspect ratio); not both at once.
private struct OptionalSideField: View {
    let title: String
    @Binding var value: Double?
    let other: Double?

    var body: some View {
        HStack(spacing: LadaGlass.Spacing.xs) {
            Text(title).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
            TextField(title, value: Binding(
                get: { value },
                set: { new in
                    if let new {
                        value = new > 0 && new.isFinite ? new : value
                    } else if other != nil {
                        value = nil
                    }
                }), format: .number, prompt: Text("auto"))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .accessibilityLabel(title)
        }
    }
}

/// The print sheet's fields: long and short side, unit and DPI.
private struct PrintSheetFields: View {
    @Binding var options: ResizeOptions

    struct Sheet {
        var long: Double
        var short: Double
        var unit: PhysicalUnit
        var dpi: Double
    }

    static func current(of options: ResizeOptions) -> Sheet {
        if case .printSheet(let long, let short, let unit, let dpi) = options.mode {
            return Sheet(long: long, short: short, unit: unit, dpi: dpi)
        }
        return Sheet(long: 15, short: 10, unit: .centimetre, dpi: 300)
    }

    var body: some View {
        let current = Self.current(of: options)
        let update = { (long: Double, short: Double, unit: PhysicalUnit, dpi: Double) in
            options.mode = .printSheet(long: long, short: short, unit: unit,
                                       dpi: min(dpi, ResizeOptions.dpiRange.upperBound))
        }
        return VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            FieldRow {
                DecimalField(title: "Long side", value: Binding(
                    get: { current.long }, set: { update($0, current.short, current.unit, current.dpi) }))
                DecimalField(title: "Short side", value: Binding(
                    get: { current.short }, set: { update(current.long, $0, current.unit, current.dpi) }))
                Picker("Unit", selection: Binding(
                    get: { current.unit }, set: { update(current.long, current.short, $0, current.dpi) })) {
                    ForEach(PhysicalUnit.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 80)
                .accessibilityLabel("Unit")
            }
            HStack(spacing: LadaGlass.Spacing.xs) {
                Text("Resolution").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                DecimalField(title: "DPI", value: Binding(
                    get: { current.dpi }, set: { update(current.long, current.short, current.unit, $0) }),
                    suffix: "dpi")
            }
        }
    }
}
