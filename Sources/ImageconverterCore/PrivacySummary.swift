import Foundation

/// Wording for the privacy chip, panel and preview row, kept out of the views so it can be tested.
public enum PrivacySummary {
    /// The findings of several images as one set (a kind is present when any image has it), for the
    /// "Remove these from the output" suggestion.
    public static func merged(_ all: [PrivacyFindings]) -> PrivacyFindings {
        var fields: [PrivacyFinding.Kind: [String]] = [:]
        for findings in all {
            for finding in findings.findings {
                for field in finding.fields where !(fields[finding.kind] ?? []).contains(field) {
                    fields[finding.kind, default: []].append(field)
                }
            }
        }
        return PrivacyFindings(findings: fields.map { PrivacyFinding(kind: $0.key, fields: $0.value) })
    }

    /// The chip in the count row: names the most severe thing found, with how many images have it.
    /// Nil when nothing was found.
    public static func chip(_ all: [PrivacyFindings]) -> (text: String, severity: PrivacySeverity)? {
        let withFindings = all.filter { !$0.isEmpty }
        guard let top = withFindings.compactMap(\.highestSeverity).max() else { return nil }
        let order = PrivacyFinding.Kind.allCases.filter { $0.severity == top }
        // The kind found in most images among the most severe ones; ties go to the earlier kind.
        let counts = order.map { kind in (kind, withFindings.filter { $0.findings.contains { $0.kind == kind } }.count) }
        guard let (kind, count) = counts.filter({ $0.1 > 0 }).max(by: { $0.1 < $1.1 }) else { return nil }
        let noun = count == 1 ? "image" : "images"
        let verb = count == 1 ? "shares" : "share"
        let text: String
        switch kind {
        case .location: text = "\(count) \(noun) \(verb) their location"
        case .serialNumbers: text = "\(count) \(noun) \(count == 1 ? "has" : "have") serial numbers"
        case .thumbnailMismatch: text = "\(count) \(noun) may show the uncropped photo"
        case .owner: text = "\(count) \(noun) name \(count == 1 ? "its" : "their") owner"
        case .editHistory: text = "\(count) \(noun) \(count == 1 ? "has" : "have") edit history"
        case .captureDate, .device: text = "\(count) \(noun) \(count == 1 ? "has" : "have") date or device info"
        }
        return (text, top)
    }

    /// One short line for the preview table: the kinds found, most severe first; "None found" when clean.
    public static func line(_ findings: PrivacyFindings) -> String {
        guard !findings.isEmpty else { return "None found" }
        return findings.findings.map { short($0.kind) }.joined(separator: ", ")
    }

    private static func short(_ kind: PrivacyFinding.Kind) -> String {
        switch kind {
        case .location: return "location"
        case .serialNumbers: return "serial numbers"
        case .owner: return "owner"
        case .editHistory: return "edit history"
        case .thumbnailMismatch: return "uncropped thumbnail"
        case .captureDate: return "date"
        case .device: return "device"
        }
    }
}
