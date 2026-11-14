import Foundation

/// Unit of the size field in the Output row.
public enum SizeUnit: String, CaseIterable, Sendable {
    case kilobytes = "KB", megabytes = "MB"
    /// Decimal like Finder (1 KB = 1000 bytes).
    public var bytes: Double { self == .kilobytes ? 1000 : 1_000_000 }
}

/// Parses a size field: a positive finite number, comma or point as the separator.
/// Nil for anything else, so the caller keeps the previous value.
public func parseSizeBytes(_ text: String, unit: SizeUnit) -> Int? {
    let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    guard let value = Double(cleaned), value.isFinite, value > 0 else { return nil }
    let bytes = (value * unit.bytes).rounded()
    return bytes >= 1 && bytes < 1e12 ? Int(bytes) : nil
}

/// " at 74 %" for modes that searched for a quality (plain Quality mode already shows its slider), else empty.
public func qualitySuffix(_ quality: Double?, mode: CompressionMode) -> String {
    if mode == .quality { return "" }
    return quality.map { " at \(Int(($0 * 100).rounded())) %" } ?? ""
}
