import SwiftUI
import ImageconverterCore

/// What a branch's "Set output…", "Set metadata…" and "Set rename…" start from: the pipeline's own settings.
struct BranchDefaults {
    var output = OutputSettings()
    var metadata = MetadataOptions()
    var rename = RenameOptions()
    /// Set while overwriting originals: renaming is off then, in branches too.
    var renameLockedHelp: String?
}

/// The if/then/else step: "Match all/any of:" with the conditions, then a Then and an Else list of actions.
struct ConditionEditor: View {
    @Binding var step: ConditionalStep
    let defaults: BranchDefaults
    /// One stable id per condition, so a row's controls follow it when another row is removed.
    @State private var ids: RowIDs

    init(step: Binding<ConditionalStep>, defaults: BranchDefaults) {
        _step = step
        self.defaults = defaults
        _ids = State(initialValue: RowIDs(count: step.wrappedValue.conditions.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            HStack(spacing: LadaGlass.Spacing.xs) {
                Text("Match").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                Picker("Match", selection: $step.match) {
                    Text("all").tag(ConditionalStep.Match.all)
                    Text("any").tag(ConditionalStep.Match.any)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Match all or any of the conditions")
                Text("of:").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
            }
            ForEach(ids.rows(count: step.conditions.count), id: \.id) { _, index in
                ConditionRow(condition: conditionBinding(index), number: index + 1,
                             canRemove: step.conditions.count > 1) {
                    guard step.conditions.indices.contains(index), step.conditions.count > 1 else { return }
                    ids.sync(count: step.conditions.count)
                    ids.remove(at: index)
                    step.conditions.remove(at: index)
                }
            }
            Button("+ Add condition") {
                ids.sync(count: step.conditions.count)
                step.conditions.append(ConditionKind.orientation.defaultCondition)
                ids.append()
            }
            .buttonStyle(.lg(.ghost))
            .disabled(step.conditions.count >= ConditionalStep.maxConditions)
            .help(step.conditions.count >= ConditionalStep.maxConditions ? "At most 10 conditions" : "")
            .accessibilityLabel("Add a condition")
            Divider()
            ActionList(title: "Then", actions: $step.then, defaults: defaults)
            ActionList(title: "Else", actions: $step.otherwise, defaults: defaults)
        }
        .onChange(of: step.conditions.count) { _, count in ids.sync(count: count) }
    }

    /// Reads by index on every access, so a row that outlives its condition cannot index out of range.
    private func conditionBinding(_ index: Int) -> Binding<Condition> {
        Binding(
            get: { step.conditions.indices.contains(index) ? step.conditions[index] : ConditionKind.longestEdge.defaultCondition },
            set: { if step.conditions.indices.contains(index) { step.conditions[index] = $0 } })
    }
}

// MARK: - Conditions

/// The kinds of condition, as the kind picker lists them.
enum ConditionKind: String, CaseIterable {
    case longestEdge, width, height, fileSize, format, transparency, orientation, location, camera

    init(_ condition: Condition) {
        switch condition {
        case .longestEdge: self = .longestEdge
        case .width: self = .width
        case .height: self = .height
        case .fileSize: self = .fileSize
        case .format: self = .format
        case .hasTransparency: self = .transparency
        case .orientation: self = .orientation
        case .hasGPS: self = .location
        case .camera: self = .camera
        }
    }

    var displayName: String {
        switch self {
        case .longestEdge: return "Longest edge"
        case .width: return "Width"
        case .height: return "Height"
        case .fileSize: return "File size"
        case .format: return "Format"
        case .transparency: return "Transparency"
        case .orientation: return "Orientation"
        case .location: return "Location"
        case .camera: return "Camera"
        }
    }

    var defaultCondition: Condition {
        switch self {
        case .longestEdge: return .longestEdge(.greaterThan, 2048)
        case .width: return .width(.greaterThan, 2048)
        case .height: return .height(.greaterThan, 2048)
        case .fileSize: return .fileSize(.greaterThan, bytes: 5_000_000)
        case .format: return .format(.format(.png))
        case .transparency: return .hasTransparency(true)
        case .orientation: return .orientation(.portrait)
        case .location: return .hasGPS(true)
        case .camera: return .camera(contains: "iPhone")
        }
    }

    /// The condition of this kind, keeping the comparison and number when moving between pixel kinds.
    func converted(from old: Condition) -> Condition {
        guard case let (comparison, value)? = old.pixelLimit else { return defaultCondition }
        switch self {
        case .longestEdge: return .longestEdge(comparison, value)
        case .width: return .width(comparison, value)
        case .height: return .height(comparison, value)
        default: return defaultCondition
        }
    }
}

private extension Condition {
    var pixelLimit: (Comparison, Int)? {
        switch self {
        case .longestEdge(let comparison, let value), .width(let comparison, let value),
             .height(let comparison, let value):
            return (comparison, value)
        default: return nil
        }
    }
}

private extension Comparison {
    var spokenName: String {
        switch self {
        case .greaterThan: return "greater than"
        case .lessThan: return "less than"
        case .atLeast: return "at least"
        case .atMost: return "at most"
        }
    }
}

/// One condition: kind, then its own controls (comparison and number, format, yes/no, text).
private struct ConditionRow: View {
    @Binding var condition: Condition
    let number: Int
    let canRemove: Bool
    let remove: () -> Void

    private var kind: ConditionKind { ConditionKind(condition) }

    var body: some View {
        HStack(spacing: LadaGlass.Spacing.xs) {
            Picker("Condition \(number)", selection: Binding(
                get: { kind },
                set: { if $0 != kind { condition = $0.converted(from: condition) } })) {
                ForEach(ConditionKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Condition \(number) kind")
            controls
            Spacer(minLength: 0)
            RemoveStepButton(label: "condition \(number)", action: remove)
                .disabled(!canRemove)
                .opacity(canRemove ? 1 : 0.35)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Condition \(number): \(condition.summary)")
    }

    @ViewBuilder private var controls: some View {
        switch condition {
        case .longestEdge(let comparison, let value):
            pixelControls(comparison, value) { .longestEdge($0, $1) }
        case .width(let comparison, let value):
            pixelControls(comparison, value) { .width($0, $1) }
        case .height(let comparison, let value):
            pixelControls(comparison, value) { .height($0, $1) }
        case .fileSize(let comparison, let bytes):
            FileSizeControls(comparison: comparison, bytes: bytes, number: number) { condition = .fileSize($0, bytes: $1) }
        case .format(let match):
            FormatMatchPicker(match: match, number: number) { condition = .format($0) }
        case .hasTransparency(let wanted):
            yesNo(wanted, yesText: "has transparency", noText: "is opaque") { condition = .hasTransparency($0) }
        case .orientation(let orientation):
            Picker("Orientation", selection: Binding(get: { orientation }, set: { condition = .orientation($0) })) {
                ForEach(Orientation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Condition \(number) orientation")
        case .hasGPS(let wanted):
            yesNo(wanted, yesText: "has GPS", noText: "has no GPS") { condition = .hasGPS($0) }
        case .camera(let text):
            TextField("Camera contains", text: Binding(
                get: { text },
                set: { condition = .camera(contains: String($0.prefix(Condition.maxTextLength))) }),
                      prompt: Text("contains, e.g. iPhone"))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Condition \(number): camera make or model contains")
        }
    }

    private func pixelControls(_ comparison: Comparison, _ value: Int,
                               make: @escaping (Comparison, Int) -> Condition) -> some View {
        HStack(spacing: LadaGlass.Spacing.xs) {
            ComparisonPicker(comparison: Binding(get: { comparison }, set: { condition = make($0, value) }), number: number)
            NumberField(title: "Condition \(number) pixels", value: Binding(get: { value }, set: { condition = make(comparison, $0) }),
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
}

/// ">", "<", "≥", "≤", each read out in words.
private struct ComparisonPicker: View {
    @Binding var comparison: Comparison
    let number: Int

    var body: some View {
        Picker("Comparison", selection: $comparison) {
            ForEach(Comparison.allCases, id: \.self) { Text($0.symbol).tag($0).accessibilityLabel($0.spokenName) }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Condition \(number) comparison")
        .accessibilityValue(comparison.spokenName)
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
