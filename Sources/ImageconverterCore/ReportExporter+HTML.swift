import Foundation

extension ReportExporter {
    /// Escapes the five characters that matter in HTML text and quoted attributes.
    static func escapeHTML(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    /// Untrusted text for the page: control and direction-override characters dropped, then escaped.
    private static func safe(_ text: String) -> String { escapeHTML(printable(text)) }

    /// One self-contained page: inline CSS, no scripts, no external resources (a CSP says so too), light and dark
    /// by `prefers-color-scheme`. Every name, path and reason is escaped.
    public static func html(_ report: ProcessingReport) -> String {
        let summary = report.summary
        let dates = ISO8601DateFormatter()
        var cards: [(String, String)] = [
            ("Files", String(summary.total)), ("Succeeded", String(summary.succeeded)),
            ("Failed", String(summary.failed)), ("Skipped", String(summary.skipped))
        ]
        if summary.unchanged > 0 { cards.append(("Unchanged", String(summary.unchanged))) }
        if summary.cancelled > 0 { cards.append(("Cancelled", String(summary.cancelled))) }
        cards.append(("Input", SizeFormat.bytes(summary.inputBytes)))
        cards.append(("Output", SizeFormat.bytes(summary.outputBytes)))
        if summary.succeeded > 0 {
            cards.append(("Saved", SizeFormat.savedPhrase(input: summary.inputBytes, output: summary.outputBytes) ?? "-"))
        }
        if let ratio = summary.averageRatio { cards.append(("Average size", String(format: "%.0f %%", ratio * 100))) }
        cards.append(("Duration", seconds(summary.totalDuration)))

        var meta = ["Started \(dates.string(from: summary.startedAt))", "Finished \(dates.string(from: summary.finishedAt))"]
        if let job = summary.jobName { meta.append("Job: \(job)") }
        if let preset = summary.presetName { meta.append("Preset: \(preset)") }
        meta.append("Output: \(summary.outputMode)")

        var page = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>imageconverter report</title>
        <style>\(css)</style>
        </head>
        <body>
        <h1>imageconverter report</h1>
        <p class="meta">\(meta.map(safe).joined(separator: " &middot; "))</p>
        <div class="cards">

        """
        for (label, value) in cards {
            page += "<div class=\"card\"><div class=\"value\">\(safe(value))</div><div class=\"label\">\(safe(label))</div></div>\n"
        }
        page += "</div>\n<table>\n<thead><tr>"
        for head in ["File", "Status", "Input", "Output", "Change", "Size (px)", "Time", "Note"] {
            page += "<th scope=\"col\">\(head)</th>"
        }
        page += "</tr></thead>\n<tbody>\n"
        for entry in report.entries {
            page += row(entry)
        }
        page += "</tbody>\n</table>\n</body>\n</html>\n"
        return page
    }

    private static func row(_ entry: ReportEntry) -> String {
        let name = (entry.variant.map { "\($0): " } ?? "")
            + (entry.destination.map { "\(entry.source) \u{2192} \($0)" } ?? entry.source)
        let change = entry.inputBytes.flatMap { input in
            entry.outputBytes.flatMap { SizeFormat.percentChange(from: input, to: $0) }
        } ?? ""
        var dimensions = ""
        if let width = entry.inputWidth, let height = entry.inputHeight { dimensions = "\(width)\u{00D7}\(height)" }
        if let width = entry.outputWidth, let height = entry.outputHeight {
            dimensions += (dimensions.isEmpty ? "" : " \u{2192} ") + "\(width)\u{00D7}\(height)"
        }
        let cells: [(String, String)] = [
            ("path", name), entry.warning ? ("status warning", "warning") : ("status \(entry.status.rawValue)", entry.status.rawValue),
            ("num", entry.inputBytes.map(SizeFormat.bytes) ?? ""), ("num", entry.outputBytes.map(SizeFormat.bytes) ?? ""),
            ("num", change), ("num", dimensions), ("num", entry.duration > 0 ? seconds(entry.duration) : ""),
            ("note", entry.note ?? "")
        ]
        // Class names are fixed strings from this file, never untrusted.
        return "<tr>" + cells.map { "<td class=\"\($0.0)\">\(safe($0.1))</td>" }.joined() + "</tr>\n"
    }

    private static func seconds(_ value: Double) -> String {
        value < 10 ? String(format: "%.2f s", locale: Locale(identifier: "en_US_POSIX"), value)
            : String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static let css = """
    :root{color-scheme:light dark;--bg:#fff;--fg:#1d1d1f;--muted:#6e6e73;--card:#f5f5f7;--line:#d2d2d7;\
    --ok:#1a7f37;--bad:#c62828;--warn:#9a6700}\
    @media (prefers-color-scheme:dark){:root{--bg:#1c1c1e;--fg:#f5f5f7;--muted:#98989d;--card:#2c2c2e;\
    --line:#3a3a3c;--ok:#4cc38a;--bad:#ff6b6b;--warn:#e3b341}}\
    body{margin:0;padding:24px;background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,system-ui,sans-serif}\
    h1{font-size:20px;margin:0 0 4px}.meta{color:var(--muted);margin:0 0 16px}\
    .cards{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:20px}\
    .card{background:var(--card);border-radius:10px;padding:10px 14px;min-width:96px}\
    .value{font-size:18px;font-weight:600}.label{color:var(--muted);font-size:12px}\
    table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:6px 8px;\
    border-bottom:1px solid var(--line);vertical-align:top}th{color:var(--muted);font-weight:500}\
    .path,.note{word-break:break-all}.num{white-space:nowrap;font-variant-numeric:tabular-nums}\
    .succeeded{color:var(--ok)}.failed{color:var(--bad)}.skipped,.cancelled,.warning{color:var(--warn)}
    """
}
