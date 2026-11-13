import SwiftUI
import ImageconverterCore

/// Edits one pipeline step; switches on the kind of operation.
struct StepEditor: View {
    @Binding var operation: ImageOperation

    var body: some View {
        switch operation {
        case .resize:
            ResizeEditor(options: Binding(
                get: { if case .resize(let opts) = operation { return opts } else { return ResizeOptions() } },
                set: { operation = .resize($0) }))
        case .crop:
            CropEditor(options: Binding(
                get: { if case .crop(let opts) = operation { return opts } else { return CropOptions() } },
                set: { operation = .crop($0) }))
        case .rotateFlip:
            RotateFlipEditor(options: Binding(
                get: { if case .rotateFlip(let opts) = operation { return opts } else { return RotateFlipOptions() } },
                set: { operation = .rotateFlip($0) }))
        case .canvas:
            CanvasEditor(options: Binding(
                get: { if case .canvas(let opts) = operation { return opts } else { return CanvasOptions() } },
                set: { operation = .canvas($0) }))
        case .colorProfile:
            Picker("Profile", selection: Binding(
                get: { if case .colorProfile(let profile) = operation { return profile } else { return .sRGB } },
                set: { operation = .colorProfile($0) })) {
                ForEach(ColorProfile.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .accessibilityLabel("Color profile")
        }
    }
}

// MARK: - Resize

private struct ResizeEditor: View {
    @Binding var options: ResizeOptions

    private enum Kind: String, CaseIterable {
        case maxWidth = "Max width", maxHeight = "Max height", fitBox = "Fit inside"
        case exactWidth = "Exact width", exactHeight = "Exact height", exactSize = "Exact size"
    }

    private var values: (width: Int, height: Int) {
        switch options.mode {
        case .maxWidth(let side), .maxHeight(let side), .exactWidth(let side), .exactHeight(let side): return (side, side)
        case .fitBox(let wide, let high), .exactSize(let wide, let high, _): return (wide, high)
        }
    }

    private var fill: ExactFill {
        if case .exactSize(_, _, let value) = options.mode { return value }
        return .stretch
    }

    private var kind: Kind {
        switch options.mode {
        case .maxWidth: return .maxWidth
        case .maxHeight: return .maxHeight
        case .fitBox: return .fitBox
        case .exactWidth: return .exactWidth
        case .exactHeight: return .exactHeight
        case .exactSize: return .exactSize
        }
    }

    private func set(_ kind: Kind, width: Int, height: Int, fill: ExactFill) {
        switch kind {
        case .maxWidth: options.mode = .maxWidth(width)
        case .maxHeight: options.mode = .maxHeight(height)
        case .fitBox: options.mode = .fitBox(width: width, height: height)
        case .exactWidth: options.mode = .exactWidth(width)
        case .exactHeight: options.mode = .exactHeight(height)
        case .exactSize: options.mode = .exactSize(width: width, height: height, fill: fill)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            Picker("Mode", selection: Binding(
                get: { kind },
                set: { set($0, width: values.width, height: values.height, fill: fill) })) {
                ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .accessibilityLabel("Resize mode")
            FieldRow {
                if [.maxWidth, .fitBox, .exactWidth, .exactSize].contains(kind) {
                    NumberField(title: "Width", value: Binding(
                        get: { values.width },
                        set: { set(kind, width: $0, height: values.height, fill: fill) }))
                }
                if [.maxHeight, .fitBox, .exactHeight, .exactSize].contains(kind) {
                    NumberField(title: "Height", value: Binding(
                        get: { values.height },
                        set: { set(kind, width: values.width, height: $0, fill: fill) }))
                }
            }
            if kind == .exactSize {
                Picker("Fill", selection: Binding(
                    get: { fill },
                    set: { set(kind, width: values.width, height: values.height, fill: $0) })) {
                    Text("Stretch").tag(ExactFill.stretch)
                    Text("Pad").tag(ExactFill.fitAndPad)
                    Text("Crop").tag(ExactFill.fillAndCrop)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Fill mode")
                if fill == .fitAndPad {
                    ColorField(title: "Pad color", color: $options.padColor)
                }
            }
            if !(kind == .exactSize && fill == .stretch) {
                Toggle("Don't enlarge smaller images", isOn: Binding(
                    get: { !options.allowEnlarge }, set: { options.allowEnlarge = !$0 }))
            }
        }
    }
}

// MARK: - Crop

private struct CropEditor: View {
    @Binding var options: CropOptions
    @State private var customRatio = false

    private struct Preset { let name: String; let wide: Double; let high: Double }
    private static let presets = [
        Preset(name: "1:1", wide: 1, high: 1), Preset(name: "4:5", wide: 4, high: 5),
        Preset(name: "3:2", wide: 3, high: 2), Preset(name: "16:9", wide: 16, high: 9)
    ]

    private var isAspect: Bool {
        if case .aspect = options.mode { return true }
        return false
    }

    private var aspect: (wide: Double, high: Double) {
        if case .aspect(let wide, let high) = options.mode { return (wide, high) }
        return (1, 1)
    }

    private var size: (wide: Int, high: Int) {
        if case .size(let wide, let high) = options.mode { return (wide, high) }
        return (1000, 1000)
    }

    private var presetName: String {
        if customRatio { return "Custom" }
        let current = aspect
        return Self.presets.first { $0.wide == current.wide && $0.high == current.high }?.name ?? "Custom"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            Picker("Crop by", selection: Binding(
                get: { isAspect },
                set: { options.mode = $0 ? .aspect(width: aspect.wide, height: aspect.high)
                                          : .size(width: size.wide, height: size.high) })) {
                Text("Aspect").tag(true)
                Text("Size").tag(false)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Crop by")
            if isAspect {
                Picker("Ratio", selection: Binding(
                    get: { presetName },
                    set: { name in
                        if let preset = Self.presets.first(where: { $0.name == name }) {
                            customRatio = false
                            options.mode = .aspect(width: preset.wide, height: preset.high)
                        } else {
                            customRatio = true
                        }
                    })) {
                    ForEach(Self.presets, id: \.name) { Text($0.name).tag($0.name) }
                    Text("Custom").tag("Custom")
                }
                .accessibilityLabel("Aspect ratio")
                if presetName == "Custom" {
                    FieldRow {
                        DecimalField(title: "Ratio width", value: Binding(
                            get: { aspect.wide }, set: { options.mode = .aspect(width: $0, height: aspect.high) }))
                        Text(":").foregroundStyle(LadaGlass.Colors.muted)
                        DecimalField(title: "Ratio height", value: Binding(
                            get: { aspect.high }, set: { options.mode = .aspect(width: aspect.wide, height: $0) }))
                    }
                }
            } else {
                FieldRow {
                    NumberField(title: "Width", value: Binding(
                        get: { size.wide }, set: { options.mode = .size(width: $0, height: size.high) }))
                    NumberField(title: "Height", value: Binding(
                        get: { size.high }, set: { options.mode = .size(width: size.wide, height: $0) }))
                }
            }
            HStack(alignment: .top, spacing: LadaGlass.Spacing.m) {
                Text("Anchor").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                AnchorPicker(anchor: $options.anchor)
            }
        }
    }
}

// MARK: - Rotate / flip

private struct RotateFlipEditor: View {
    @Binding var options: RotateFlipOptions

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            Picker("Rotation", selection: $options.rotation) {
                ForEach(Rotation.allCases, id: \.self) { Text("\($0.rawValue)°").tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Rotation")
            Toggle("Flip horizontally", isOn: $options.flipHorizontal)
            Toggle("Flip vertically", isOn: $options.flipVertical)
        }
    }
}

// MARK: - Canvas / padding

private struct CanvasEditor: View {
    @Binding var options: CanvasOptions

    private enum Kind: String, CaseIterable {
        case padding = "Padding px", percent = "Padding %", size = "Canvas size"
    }

    private var kind: Kind {
        switch options.mode {
        case .padding: return .padding
        case .paddingPercent: return .percent
        case .size: return .size
        }
    }

    private var pixels: Int { if case .padding(let value) = options.mode { return value } else { return 20 } }
    private var percent: Double { if case .paddingPercent(let value) = options.mode { return value } else { return 5 } }
    private var size: (wide: Int, high: Int) {
        if case .size(let wide, let high) = options.mode { return (wide, high) } else { return (2000, 2000) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            Picker("Mode", selection: Binding(
                get: { kind },
                set: { new in
                    switch new {
                    case .padding: options.mode = .padding(pixels: pixels)
                    case .percent: options.mode = .paddingPercent(percent)
                    case .size: options.mode = .size(width: size.wide, height: size.high)
                    }
                })) {
                ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Canvas mode")
            switch kind {
            case .padding:
                NumberField(title: "Padding", value: Binding(
                    get: { pixels }, set: { options.mode = .padding(pixels: $0) }), minimum: 0)
            case .percent:
                HStack(spacing: LadaGlass.Spacing.xs) {
                    Text("Padding").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                    DecimalField(title: "Padding percent", value: Binding(
                        get: { percent }, set: { options.mode = .paddingPercent($0) }), minimum: 0, suffix: "%")
                }
            case .size:
                FieldRow {
                    NumberField(title: "Width", value: Binding(
                        get: { size.wide }, set: { options.mode = .size(width: $0, height: size.high) }))
                    NumberField(title: "Height", value: Binding(
                        get: { size.high }, set: { options.mode = .size(width: size.wide, height: $0) }))
                }
                HStack(alignment: .top, spacing: LadaGlass.Spacing.m) {
                    Text("Anchor").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                    AnchorPicker(anchor: $options.anchor)
                }
            }
            Toggle("Transparent", isOn: Binding(
                get: { options.background.alpha == 0 },
                set: { options.background = $0 ? .clear : .white }))
            if options.background.alpha != 0 {
                ColorField(title: "Background", color: $options.background)
            }
        }
    }
}

#Preview {
    struct Host: View {
        @State var ops: [ImageOperation] = StepKind.allCases.map(\.defaultOperation)
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: LadaGlass.Spacing.l) {
                    ForEach(ops.indices, id: \.self) { StepEditor(operation: $ops[$0]) }
                }
                .padding(LadaGlass.Spacing.m)
            }
            .frame(width: 340, height: 700)
            .lgCompact()
        }
    }
    return Host()
}
