import SwiftUI
import ImageconverterCore

/// Edits one pipeline step; switches on the kind of operation.
struct StepEditor: View {
    @Binding var operation: ImageOperation
    /// What a condition's "Set output/metadata/rename…" start from.
    var branchDefaults = BranchDefaults()

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
        case .redact:
            RedactEditor(options: Binding(
                get: { if case .redact(let opts) = operation { return opts } else { return RedactOptions() } },
                set: { operation = .redact($0) }))
        case .canvas:
            CanvasEditor(options: Binding(
                get: { if case .canvas(let opts) = operation { return opts } else { return CanvasOptions() } },
                set: { operation = .canvas($0) }))
        case .colorProfile:
            ColorEditor(options: Binding(
                get: { if case .colorProfile(let opts) = operation { return opts } else { return ColorOptions() } },
                set: { operation = .colorProfile($0) }))
        case .adjust:
            AdjustEditor(options: Binding(
                get: { if case .adjust(let opts) = operation { return opts } else { return AdjustOptions() } },
                set: { operation = .adjust($0) }))
        case .perspective:
            PerspectiveEditor(options: Binding(
                get: { if case .perspective(let opts) = operation { return opts } else { return PerspectiveOptions() } },
                set: { operation = .perspective($0) }))
        case .trim:
            TrimEditor(options: Binding(
                get: { if case .trim(let opts) = operation { return opts } else { return TrimOptions() } },
                set: { operation = .trim($0) }))
        case .watermark:
            WatermarkEditor(options: Binding(
                get: { if case .watermark(let opts) = operation { return opts } else { return WatermarkOptions() } },
                set: { operation = .watermark($0) }))
        case .condition:
            ConditionEditor(step: Binding(
                get: { if case .condition(let step) = operation { return step } else { return ConditionalStep() } },
                set: { operation = .condition($0) }), defaults: branchDefaults)
        }
    }
}

// MARK: - Crop

private struct CropEditor: View {
    @Binding var options: CropOptions
    @State private var customRatio = false

    private static let presets = SizePresets.aspectRatios

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
        return Self.presets.first { $0.width == current.wide && $0.height == current.high }?.name ?? "Custom"
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
                            options.mode = preset.cropMode
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
            FocusPicker(focus: $options.focus)
        }
    }
}

// MARK: - Canvas / padding

private struct CanvasEditor: View {
    @Binding var options: CanvasOptions

    private enum Kind: String, CaseIterable {
        case padding = "Padding px", percent = "Padding %", size = "Canvas size", aspect = "Ratio"
    }

    private var kind: Kind {
        switch options.mode {
        case .padding: return .padding
        case .paddingPercent: return .percent
        case .size: return .size
        case .aspect: return .aspect
        }
    }

    private var pixels: Int { if case .padding(let value) = options.mode { return value } else { return 20 } }
    private var percent: Double { if case .paddingPercent(let value) = options.mode { return value } else { return 5 } }
    private var size: (wide: Int, high: Int) {
        if case .size(let wide, let high) = options.mode { return (wide, high) } else { return (2000, 2000) }
    }
    private var aspectRatio: (wide: Double, high: Double) {
        if case .aspect(let wide, let high) = options.mode { return (wide, high) } else { return (1, 1) }
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
                    case .aspect: options.mode = .aspect(width: aspectRatio.wide, height: aspectRatio.high)
                    }
                })) {
                ForEach(Kind.allCases, id: \.self) {
                    Text($0.rawValue).tag($0).accessibilityLabel($0 == .aspect ? "Aspect ratio" : $0.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
                HStack(alignment: .top, spacing: LadaGlass.Spacing.s) {
                    Text("Anchor").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                    AnchorPicker(anchor: $options.anchor)
                }
            case .aspect:
                AspectRatioPicker(mode: $options.mode)
                HStack(alignment: .top, spacing: LadaGlass.Spacing.s) {
                    Text("Anchor").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                    AnchorPicker(anchor: $options.anchor)
                }
                Text("Pads the shorter side until the image fits the ratio.")
                    .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
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
