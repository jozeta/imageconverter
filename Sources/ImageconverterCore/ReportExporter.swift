import Foundation

/// Turns a `ProcessingReport` into a file. Filenames, paths and reasons are untrusted: CSV fields are quoted and
/// guarded against formula injection, text drops control and direction-override characters, JSON keys are sorted.
public enum ReportExporter {
    public static let csvColumns = ["source", "destination", "status", "input bytes", "output bytes", "saving %",
                                    "note"]

    public static func data(_ report: ProcessingReport, format: ReportFormat) -> Data {
        switch format {
        case .csv: return Data(csv(report).utf8)
        case .json: return json(report)
        case .text: return Data(text(report).utf8)
        }
    }

    // MARK: CSV

    /// One row per file, then a `TOTAL` row in the same columns (status holds the counts).
    public static func csv(_ report: ProcessingReport) -> String {
        var rows = [csvColumns.map { quoted($0) }]
        for entry in report.entries {
            rows.append([
                quoted(guarded(entry.source)), quoted(guarded(entry.destination ?? "")),
                quoted(entry.status.rawValue), quoted(entry.inputBytes.map(String.init) ?? ""),
                quoted(entry.outputBytes.map(String.init) ?? ""),
                quoted(entry.ratio.map(savingPercent) ?? ""), quoted(guarded(entry.note ?? ""))
            ])
        }
        let summary = report.summary
        rows.append([
            quoted("TOTAL"), quoted(""), quoted(counts(summary)), quoted(String(summary.inputBytes)),
            quoted(String(summary.outputBytes)), quoted(summary.overallRatio.map(savingPercent) ?? ""), quoted("")
        ])
        return rows.map { $0.joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// A field starting with `= + - @`, tab or CR would be run as a formula by spreadsheets: prefix `'`.
    static func guarded(_ field: String) -> String {
        guard let first = field.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) else { return field }
        return "'" + field
    }

    static func quoted(_ field: String) -> String {
        "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// "74.0": how much smaller the output is, in percent (negative when it grew).
    static func savingPercent(_ ratio: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), (1 - ratio) * 100)
    }

    static func counts(_ summary: RunSummary) -> String {
        "\(summary.total) files: \(summary.succeeded) succeeded, \(summary.failed) failed, "
            + "\(summary.skipped) skipped, " + (summary.unchanged > 0 ? "\(summary.unchanged) unchanged, " : "")
            + "\(summary.cancelled) cancelled"
    }

    // MARK: JSON

    private struct JSONReport: Encodable {
        let summary: RunSummary
        let entries: [ReportEntry]
    }

    /// `{"entries": [...], "summary": {...}}` with sorted keys and ISO 8601 dates.
    public static func json(_ report: ProcessingReport) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        // Encoding plain value types can't fail; an empty object is safer than a crash if it ever does.
        return (try? encoder.encode(JSONReport(summary: report.summary, entries: report.entries))) ?? Data("{}".utf8)
    }

    // MARK: Text

    public static func text(_ report: ProcessingReport) -> String {
        let summary = report.summary
        var lines = ["imageconverter report"]
        let dates = ISO8601DateFormatter()
        lines.append("Started:  \(dates.string(from: summary.startedAt))")
        lines.append("Finished: \(dates.string(from: summary.finishedAt))")
        if let job = summary.jobName { lines.append("Job: \(printable(job))") }
        if let preset = summary.presetName { lines.append("Preset: \(printable(preset))") }
        lines.append(counts(summary))
        if let phrase = SizeFormat.savedPhrase(input: summary.inputBytes, output: summary.outputBytes),
           summary.succeeded > 0 {
            lines.append("\(SizeFormat.bytes(summary.inputBytes)) \u{2192} \(SizeFormat.bytes(summary.outputBytes)), "
                         + phrase)
        }
        lines.append("")
        for entry in report.entries {
            var line = "\(entry.status.rawValue): \(printable(entry.source))"
            if let destination = entry.destination { line += " \u{2192} \(printable(destination))" }
            if let input = entry.inputBytes, let output = entry.outputBytes {
                line += " (\(SizeFormat.bytes(input)) \u{2192} \(SizeFormat.bytes(output))"
                if let change = SizeFormat.percentChange(from: input, to: output) { line += ", \(change)" }
                line += ")"
            }
            if let note = entry.note { line += " \u{2014} \(printable(note))" }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One line: no control characters, no line or paragraph separators (U+2028/U+2029), no bidi overrides that
    /// could disguise a name ("gpj.exe").
    static func printable(_ text: String) -> String {
        let replaced: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator]
        return String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            replaced.contains(scalar.properties.generalCategory) ? "?" : scalar
        }))
    }
}
