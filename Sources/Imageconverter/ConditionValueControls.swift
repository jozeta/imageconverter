import SwiftUI
import ImageconverterCore

/// File name: contains / starts with / ends with / is / matches a pattern, the text, and "Match case".
struct NameMatchControls: View {
    let match: TextMatch
    let number: Int
    let set: (TextMatch) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            HStack(spacing: LadaGlass.Spacing.xs) {
                Picker("Name test", selection: Binding(get: { match.operation }, set: { update(operation: $0) })) {
                    ForEach(TextOperation.allCases, id: \.self) { Text($0.phrase).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Condition \(number) name test")
                Toggle("Match case", isOn: Binding(get: { !match.ignoresCase }, set: { update(ignoresCase: !$0) }))
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("Condition \(number): match upper and lower case")
            }
            TextField("Name", text: Binding(get: { match.text }, set: { update(text: String($0.prefix(Condition.maxTextLength))) }),
                      prompt: Text(match.operation == .matchesRegex ? "regular expression, e.g. ^IMG_\\d+" : "text, e.g. IMG_"))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Condition \(number): file name text, without the extension")
            if let error = match.regexError, !match.text.isEmpty {
                Text(error).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.warnText)
            }
        }
    }

    private func update(operation: TextOperation? = nil, text: String? = nil, ignoresCase: Bool? = nil) {
        set(TextMatch(operation ?? match.operation, text ?? match.text, ignoresCase: ignoresCase ?? match.ignoresCase))
    }
}

/// A date rule: is before / after / between / within the last N days / in a year / in a month / is known.
struct DateRuleControls: View {
    let field: DateField
    let rule: DateRule
    let number: Int
    let set: (DateRule) -> Void

    private enum Kind: String, CaseIterable {
        case before = "is before", after = "is after", between = "is between", within = "is within the last"
        case year = "is in the year", month = "is in the month", exists = "is known"
    }

    private var kind: Kind {
        switch rule {
        case .before: return .before
        case .after: return .after
        case .between: return .between
        case .withinLastDays: return .within
        case .inYear: return .year
        case .inMonth: return .month
        case .exists: return .exists
        }
    }

    private static var today: CalendarDay { CalendarDay(Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            HStack(spacing: LadaGlass.Spacing.xs) {
                Picker("Date test", selection: Binding(get: { kind }, set: { set(Self.rule(for: $0, from: rule)) })) {
                    ForEach(Kind.allCases, id: \.self) { Text(title(of: $0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Condition \(number) date test")
                values
            }
            if case .between(let from, let until) = rule {
                HStack(spacing: LadaGlass.Spacing.xs) {
                    dayPicker(from, label: "from") { set(.between($0, until)) }
                    Text("and").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                    dayPicker(until, label: "to") { set(.between(from, $0)) }
                }
            }
        }
        .help(field == .taken ? "Date taken is the EXIF date, or the XMP date created; files without one never match a date"
              : "The file's own date in Finder")
    }

    private func title(of kind: Kind) -> String {
        kind == .exists && field == .taken ? "is present" : kind.rawValue
    }

    @ViewBuilder private var values: some View {
        switch rule {
        case .before(let day): dayPicker(day, label: "date") { set(.before($0)) }
        case .after(let day): dayPicker(day, label: "date") { set(.after($0)) }
        case .withinLastDays(let days):
            NumberField(title: "Condition \(number) days", value: Binding(get: { days }, set: { set(.withinLastDays($0)) }),
                        minimum: 1, maximum: DateRule.maxDays, suffix: days == 1 ? "day" : "days", showsTitle: false)
        case .inYear(let year):
            TextField("Year", value: Binding(get: { year }, set: {
                set(.inYear(min(max($0, CalendarDay.years.lowerBound), CalendarDay.years.upperBound)))
            }), format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .accessibilityLabel("Condition \(number) year")
        case .inMonth(let month):
            Picker("Month", selection: Binding(get: { month }, set: { set(.inMonth($0)) })) {
                ForEach(1...12, id: \.self) { Text(ConditionCheck.monthName($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Condition \(number) month")
        case .between, .exists:
            EmptyView()
        }
    }

    private func dayPicker(_ day: CalendarDay, label: String, set: @escaping (CalendarDay) -> Void) -> some View {
        DatePicker(label, selection: Binding(get: { day.date ?? Date() }, set: { set(CalendarDay($0)) }),
                   displayedComponents: .date)
            .labelsHidden()
            .datePickerStyle(.field)
            .fixedSize()
            .accessibilityLabel("Condition \(number) \(label)")
    }

    /// The new rule of `kind`, keeping the day of the old one where both have one.
    private static func rule(for kind: Kind, from old: DateRule) -> DateRule {
        let day: CalendarDay
        switch old {
        case .before(let value), .after(let value), .between(let value, _): day = value
        default: day = today
        }
        switch kind {
        case .before: return .before(day)
        case .after: return .after(day)
        case .between: return .between(day, max(day, today))
        case .within: return .withinLastDays(30)
        case .year: return .inYear(day.year)
        case .month: return .inMonth(day.month)
        case .exists: return .exists
        }
    }
}

/// A metadata field (named, or any allowlisted EXIF/IPTC/XMP key), how it is tested, and the value.
struct MetadataTestControls: View {
    let test: MetadataTest
    let number: Int
    let set: (MetadataTest) -> Void

    private static func tag(_ subject: MetadataSubject) -> String {
        switch subject {
        case .named(let field): return "named:" + field.rawValue
        case .custom(let namespace, let key): return namespace.rawValue + ":" + key
        }
    }

    private static func subject(for tag: String) -> MetadataSubject? {
        let parts = tag.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[0] == "named" { return NamedMetadataField(rawValue: parts[1]).map(MetadataSubject.named) }
        return MetadataNamespace(rawValue: parts[0]).map { MetadataSubject.custom($0, parts[1]) }
    }

    private var operations: [MetadataOperation] {
        MetadataOperation.allCases.filter { test.subject.isNumeric || $0.comparison == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            HStack(spacing: LadaGlass.Spacing.xs) {
                fieldPicker
                Picker("Test", selection: Binding(get: { test.operation }, set: {
                    set(MetadataTest(test.subject, $0, test.value))
                })) {
                    ForEach(operations, id: \.self) { Text($0.phrase).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Condition \(number) metadata test")
            }
            if test.operation.takesValue {
                HStack(spacing: LadaGlass.Spacing.xs) {
                    TextField("Value", text: Binding(get: { test.value }, set: {
                        set(MetadataTest(test.subject, test.operation, String($0.prefix(Condition.maxTextLength))))
                    }), prompt: Text(prompt))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Condition \(number): metadata value")
                    if case .named(let field) = test.subject, !field.unit.isEmpty {
                        Text(field.unit).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                    }
                }
                if test.operation.comparison != nil, MetadataTest.number(test.value) == nil, !test.value.isEmpty {
                    Text("Enter a number").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.warnText)
                }
            }
        }
    }

    private var prompt: String {
        switch test.subject {
        case .named(.shutterSpeed): return "seconds, e.g. 1/250"
        case .named(.aperture): return "f-number, e.g. 2.8"
        case .named(.iso): return "e.g. 1600"
        case .named(.focalLength): return "e.g. 50"
        default: return "text"
        }
    }

    private var fieldPicker: some View {
        Picker("Field", selection: Binding(get: { Self.tag(test.subject) }, set: { tag in
            guard let subject = Self.subject(for: tag) else { return }
            // Comparisons only apply to numbers; a text field falls back to "contains".
            let operation = subject.isNumeric || test.operation.comparison == nil ? test.operation : .contains
            set(MetadataTest(subject, operation, test.value))
        })) {
            Section("Common") {
                ForEach(NamedMetadataField.allCases, id: \.self) { Text($0.displayName.capitalizedFirst).tag("named:" + $0.rawValue) }
            }
            ForEach(MetadataNamespace.allCases, id: \.self) { namespace in
                Section(namespace.rawValue.uppercased()) {
                    ForEach(MetadataFields.writable[namespace] ?? [], id: \.self) { key in
                        Text(key).tag(namespace.rawValue + ":" + key)
                    }
                }
            }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Condition \(number) metadata field")
    }
}

private extension String {
    /// `camera make` → `Camera make` (ISO stays ISO).
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
