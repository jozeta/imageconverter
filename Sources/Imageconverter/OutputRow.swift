import SwiftUI
import ImageconverterCore

/// How the Compression picker names the modes (the size modes carry a byte count in the model).
enum CompressionKind: String, CaseIterable {
    case quality, target, maximum, smart

    init(_ mode: CompressionMode) {
        switch mode {
        case .quality: self = .quality
        case .targetSize: self = .target
        case .maxSize: self = .maximum
        case .smart: self = .smart
        }
    }

    var title: String {
        switch self {
        case .quality: return "Quality"
        case .target: return "Target size"
        case .maximum: return "Maximum size"
        case .smart: return "Smart"
        }
    }
}

/// Format, quality and compression controls of the Output row.
struct OutputFormatControls: View {
    @Binding var output: OutputSettings
    @State private var sizeText = ""
    @State private var unit: SizeUnit = .kilobytes
    @FocusState private var sizeFocused: Bool
    /// The last size of each size mode, so Target -> Quality -> Target keeps it.
    @State private var lastBytes: Int?

    private static let defaultBytes = 500_000

    var body: some View {
        Picker("Format", selection: $output.format) {
            ForEach(OutputFormat.available(), id: \.self) { Text($0.displayName).tag($0) }
        }
        .accessibilityLabel("Output format")
        if output.format.supportsQuality {
            Picker("Compression", selection: kindBinding) {
                ForEach(CompressionKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityLabel("Compression mode")
            switch output.compression {
            case .quality, .maxSize:
                qualitySlider
                if case .maxSize = output.compression { sizeField }
            case .targetSize:
                sizeField
            case .smart:
                Text("Picks the lowest quality that still looks the same (up to 95 %)")
                    .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
            }
        }
        if output.format == .jpeg {
            Toggle("Progressive", isOn: $output.progressive)
                .accessibilityLabel("Progressive JPEG")
        }
        if output.format == .png {
            Toggle("Optimise PNG", isOn: $output.optimizePNG)
                .accessibilityLabel("Optimise PNG")
        }
        if output.format == .tiff {
            Picker("Compression", selection: $output.tiffCompression) {
                Text("None").tag(TIFFCompression.none)
                Text("LZW").tag(TIFFCompression.lzw)
            }
            .accessibilityLabel("TIFF compression")
        }
    }

    private var percent: Int { Int((output.clampedQuality * 100).rounded()) }

    private var qualitySlider: some View {
        HStack {
            Slider(value: $output.quality, in: 0...1, step: 0.01)
                .accessibilityLabel(output.compression == .quality ? "Quality" : "Starting quality")
                .accessibilityValue("\(percent) percent")
            Text("\(percent) %")
                .font(LadaGlass.Typography.mono)
                .frame(minWidth: 44, alignment: .trailing)
        }
    }

    private var currentBytes: Int? {
        switch output.compression {
        case .targetSize(let bytes), .maxSize(let bytes): return bytes
        default: return nil
        }
    }

    private var sizeField: some View {
        HStack {
            TextField("Size", text: $sizeText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 90)
                .focused($sizeFocused)
                .accessibilityLabel(sizeLabel)
                .onChange(of: sizeText) { _, text in
                    if let bytes = parseSizeBytes(text, unit: unit) { setBytes(bytes) }
                }
                .onSubmit { revertIfInvalid() }
                .onChange(of: sizeFocused) { _, focused in if !focused { revertIfInvalid() } }
            Picker("Unit", selection: $unit) {
                ForEach(SizeUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Size unit")
            .onChange(of: unit) { _, _ in
                if let bytes = parseSizeBytes(sizeText, unit: unit) { setBytes(bytes) } else { syncText() }
            }
        }
        .onAppear { syncText(chooseUnit: true) }
        // A preset load or reset can change the bytes while this mode stays selected.
        .onChange(of: currentBytes) { _, bytes in
            if let bytes, parseSizeBytes(sizeText, unit: unit) != bytes { syncText(chooseUnit: true) }
        }
    }

    private var sizeLabel: String {
        if case .maxSize = output.compression { return "Maximum size" }
        return "Target size"
    }

    private func setBytes(_ bytes: Int) {
        switch output.compression {
        case .targetSize: output.compression = .targetSize(bytes: bytes)
        case .maxSize: output.compression = .maxSize(bytes: bytes)
        default: break
        }
    }

    /// Invalid input keeps the previous value: show it again.
    private func revertIfInvalid() {
        if parseSizeBytes(sizeText, unit: unit) == nil { syncText() }
    }

    private func syncText(chooseUnit: Bool = false) {
        guard let bytes = currentBytes else { return }
        if chooseUnit { unit = bytes >= 1_000_000 ? .megabytes : .kilobytes }
        let value = (Double(bytes) / unit.bytes * 100).rounded() / 100
        sizeText = value == value.rounded() ? String(Int(value)) : String(value)
    }

    private var kindBinding: Binding<CompressionKind> {
        Binding(
            get: { CompressionKind(output.compression) },
            set: { kind in
                let bytes = currentBytes ?? lastBytes ?? Self.defaultBytes
                if let current = currentBytes { lastBytes = current }
                switch kind {
                case .quality: output.compression = .quality
                case .target: output.compression = .targetSize(bytes: bytes)
                case .maximum: output.compression = .maxSize(bytes: bytes)
                case .smart: output.compression = .smart
                }
                syncText(chooseUnit: true)
            })
    }
}
