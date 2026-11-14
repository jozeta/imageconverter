import SwiftUI
import ImageconverterCore

/// The value controls of one condition, per kind: comparisons with numbers and units, text fields, date pickers
/// and menus. Every control writes a whole new check, so there is no view state to go stale when rows move.
struct ConditionControls: View {
    @Binding var check: ConditionCheck
    let number: Int

    var body: some View {
        switch check {
        case .longestEdge(let comparison, let value):
            pixelControls(comparison, value) { .longestEdge($0, $1) }
        case .width(let comparison, let value):
            pixelControls(comparison, value) { .width($0, $1) }
        case .height(let comparison, let value):
            pixelControls(comparison, value) { .height($0, $1) }
        case .fileSize(let comparison, let bytes):
            FileSizeControls(comparison: comparison, bytes: bytes, number: number) { check = .fileSize($0, bytes: $1) }
        case .format(let match):
            FormatMatchPicker(match: match, number: number) { check = .format($0) }
        case .name(let match):
            NameMatchControls(match: match, number: number) { check = .name($0) }
        case .date(let field, let rule):
            DateRuleControls(field: field, rule: rule, number: number) { check = .date(field, $0) }
        case .metadata(let test):
            MetadataTestControls(test: test, number: number) { check = .metadata($0) }
        default:
            otherControls
        }
    }

    @ViewBuilder private var otherControls: some View {
        switch check {
        case .hasTransparency(let wanted):
            yesNo(wanted, yesText: "has transparency", noText: "is opaque") { check = .hasTransparency($0) }
        case .orientation(let orientation):
            menu("orientation", selection: Binding(get: { orientation }, set: { check = .orientation($0) }),
                 options: Orientation.allCases) { "is \($0.rawValue)" }
        case .hasGPS(let wanted):
            yesNo(wanted, yesText: "has location", noText: "has no location") { check = .hasGPS($0) }
        case .camera(let text):
            textField(text, prompt: "camera contains, e.g. iPhone", label: "camera make or model contains") {
                check = .camera(contains: $0)
            }
        case .fileExtension(let list):
            ListTextField(values: list, prompt: "extensions, e.g. jpg, png", parse: ConditionCheck.extensions(from:),
                          label: "Condition \(number): extension is one of") { check = .fileExtension($0) }
        case .folder(let text):
            textField(text, prompt: "folder path contains, e.g. Holiday", label: "folder path contains") {
                check = .folder(contains: $0)
            }
        case .megapixels(let comparison, let value):
            HStack(spacing: LadaGlass.Spacing.xs) {
                ComparisonPicker(comparison: Binding(get: { comparison }, set: { check = .megapixels($0, value) }),
                                 number: number)
                DecimalField(title: "Condition \(number) megapixels", value: Binding(
                    get: { value }, set: { check = .megapixels(comparison, min($0, ConditionCheck.maxMegapixels)) }),
                             minimum: 0, suffix: "MP")
            }
        case .aspectRatio(let rule):
            AspectRuleControls(rule: rule, number: number) { check = .aspectRatio($0) }
        default:
            imageControls
        }
    }

    @ViewBuilder private var imageControls: some View {
        switch check {
        case .bitDepth(let depth):
            menu("bit depth", selection: Binding(get: { depth }, set: { check = .bitDepth($0) }),
                 options: BitDepth.allCases) { "is \($0.displayName)" }
        case .colorSpace(let kind):
            menu("color space", selection: Binding(get: { kind }, set: { check = .colorSpace($0) }),
                 options: ColorSpaceKind.allCases) { "is \($0.displayName)" }
        case .dpi(let comparison, let value):
            HStack(spacing: LadaGlass.Spacing.xs) {
                ComparisonPicker(comparison: Binding(get: { comparison }, set: { check = .dpi($0, value) }), number: number)
                NumberField(title: "Condition \(number) DPI", value: Binding(get: { value }, set: { check = .dpi(comparison, $0) }),
                            minimum: 0, maximum: ConditionCheck.maxDPI, suffix: "dpi", showsTitle: false)
            }
        case .hasProfile: note("has an embedded color profile")
        case .isRotated: note("its EXIF orientation turns or mirrors it")
        case .isAnimated: note("has more than one frame or page")
        default: EmptyView()
        }
    }

    private func pixelControls(_ comparison: Comparison, _ value: Int,
                               make: @escaping (Comparison, Int) -> ConditionCheck) -> some View {
        HStack(spacing: LadaGlass.Spacing.xs) {
            ComparisonPicker(comparison: Binding(get: { comparison }, set: { check = make($0, value) }), number: number)
            NumberField(title: "Condition \(number) pixels", value: Binding(get: { value }, set: { check = make(comparison, $0) }),
                        minimum: 0, maximum: Condition.maxPixelValue, showsTitle: false)
        }
    }

    private func yesNo(_ wanted: Bool, yesText: String, noText: String, set: @escaping (Bool) -> Void) -> some View {
        Picker("Condition \(number)", selection: Binding(get: { wanted }, set: set)) {
            Text(yesText).tag(true)
            Text(noText).tag(false)
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Condition \(number)")
    }

    private func menu<Value: Hashable>(_ name: String, selection: Binding<Value>, options: [Value],
                                       title: @escaping (Value) -> String) -> some View {
        Picker(name, selection: selection) {
            ForEach(options, id: \.self) { Text(title($0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Condition \(number) \(name)")
    }

    private func textField(_ text: String, prompt: String, label: String,
                           set: @escaping (String) -> Void) -> some View {
        TextField(label, text: Binding(get: { text }, set: { set(String($0.prefix(Condition.maxTextLength))) }),
                  prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Condition \(number): \(label)")
    }

    private func note(_ text: String) -> some View {
        Text(text).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
    }
}

/// "is more than", "is less than", "is at least", "is at most".
struct ComparisonPicker: View {
    @Binding var comparison: Comparison
    let number: Int

    var body: some View {
        Picker("Comparison", selection: $comparison) {
            ForEach(Comparison.allCases, id: \.self) { Text($0.phrase).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Condition \(number) comparison")
        .accessibilityValue(comparison.phrase)
    }
}

/// A comma-separated list in a text field (extensions, tags, keywords). What is typed stays as typed; the list
/// is parsed from it on every change, and the text is only replaced when the list changes from outside.
struct ListTextField: View {
    let values: [String]
    let prompt: String
    let parse: (String) -> [String]
    let label: String
    let set: ([String]) -> Void
    @State private var draft = ""

    var body: some View {
        TextField(label, text: $draft, prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(label)
            .onAppear { draft = values.joined(separator: ", ") }
            .onChange(of: draft) { _, text in
                let parsed = parse(text)
                if parsed != values { set(parsed) }
            }
            .onChange(of: values) { _, new in
                if parse(draft) != new { draft = new.joined(separator: ", ") }
            }
    }
}

/// Wider than / taller than a ratio, or about square.
private struct AspectRuleControls: View {
    let rule: AspectRule
    let number: Int
    let set: (AspectRule) -> Void

    private enum Kind: String, CaseIterable {
        case wider = "is wider than", taller = "is taller than", square = "is about square"
    }

    private var kind: Kind {
        switch rule {
        case .widerThan: return .wider
        case .tallerThan: return .taller
        case .square: return .square
        }
    }

    private var ratio: Double {
        switch rule {
        case .widerThan(let value), .tallerThan(let value): return value
        case .square: return 1.5
        }
    }

    var body: some View {
        HStack(spacing: LadaGlass.Spacing.xs) {
            Picker("Aspect ratio", selection: Binding(get: { kind }, set: { make($0, ratio) })) {
                ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Condition \(number) aspect ratio")
            if kind != .square {
                DecimalField(title: "Condition \(number) ratio", value: Binding(get: { ratio }, set: { make(kind, min($0, 100)) }),
                             minimum: 0.01, suffix: "to 1")
            }
        }
        .help("A ratio of 1.5 to 1 is 3:2; about square is within 1 %")
    }

    private func make(_ kind: Kind, _ ratio: Double) {
        switch kind {
        case .wider: set(.widerThan(ratio))
        case .taller: set(.tallerThan(ratio))
        case .square: set(.square)
        }
    }
}

/// Comparison, number and KB/MB. The unit is derived from the stored bytes (MB when they are whole megabytes), so
/// there is no view state to go stale when rows move.
private struct FileSizeControls: View {
    let comparison: Comparison
    let bytes: Int
    let number: Int
    let set: (Comparison, Int) -> Void

    private enum Unit: Int, CaseIterable {
        case kilobytes = 1000, megabytes = 1_000_000
        var name: String { self == .kilobytes ? "KB" : "MB" }
    }

    private var unit: Unit {
        bytes >= Unit.megabytes.rawValue && bytes % Unit.megabytes.rawValue == 0 ? .megabytes : .kilobytes
    }

    var body: some View {
        HStack(spacing: LadaGlass.Spacing.xs) {
            ComparisonPicker(comparison: Binding(get: { comparison }, set: { set($0, bytes) }), number: number)
            NumberField(title: "Condition \(number) file size", value: Binding(
                get: { bytes / unit.rawValue },
                set: { set(comparison, min($0, Condition.maxBytesValue / unit.rawValue) * unit.rawValue) }),
                        minimum: 0, suffix: "", showsTitle: false)
            Picker("Unit", selection: Binding(
                get: { unit },
                set: { new in
                    // Keeps the number and changes what it means: 500 KB becomes 500 MB.
                    let shown = bytes / unit.rawValue
                    set(comparison, min(shown, Condition.maxBytesValue / new.rawValue) * new.rawValue)
                })) {
                ForEach(Unit.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Changing the unit keeps the number: 500 KB becomes 500 MB")
            .accessibilityLabel("Condition \(number) size unit")
            .accessibilityHint("Changing the unit keeps the number")
        }
    }
}

/// The writable formats plus a few read-only families (RAW, WebP); a hand-edited type stays listed.
private struct FormatMatchPicker: View {
    let match: FormatMatch
    let number: Int
    let set: (FormatMatch) -> Void

    private static let readOnlyTypes: [(name: String, identifier: String)] = [
        ("RAW (any camera)", "public.camera-raw-image"), ("WebP", "org.webmproject.webp"), ("HEIF (any)", "public.heif"),
    ]

    private static func tag(_ match: FormatMatch) -> String {
        switch match {
        case .format(let format): return "format:" + format.rawValue
        case .type(let identifier): return "type:" + identifier
        }
    }

    private static func match(for tag: String) -> FormatMatch? {
        if tag.hasPrefix("format:") { return OutputFormat(rawValue: String(tag.dropFirst(7))).map(FormatMatch.format) }
        if tag.hasPrefix("type:") { return .type(String(tag.dropFirst(5))) }
        return nil
    }

    private var listed: [(name: String, tag: String)] {
        var entries = OutputFormat.available().map { ($0.displayName, Self.tag(.format($0))) }
        entries += Self.readOnlyTypes.map { ($0.name, Self.tag(.type($0.identifier))) }
        let current = Self.tag(match)
        if !entries.contains(where: { $0.1 == current }) {
            switch match {
            case .format(let format): entries.append((format.displayName, current))
            case .type(let identifier): entries.append((identifier, current))
            }
        }
        return entries.map { (name: $0.0, tag: $0.1) }
    }

    var body: some View {
        Picker("Format", selection: Binding(
            get: { Self.tag(match) },
            set: { if let new = Self.match(for: $0) { set(new) } })) {
            ForEach(listed, id: \.tag) { Text($0.name).tag($0.tag) }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Condition \(number) format")
    }
}
