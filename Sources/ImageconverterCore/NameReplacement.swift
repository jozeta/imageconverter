import Foundation

/// Find and replace on a rendered file name, plain or regular expression.
public enum NameReplacement {
    /// Replaces every match of `find` in `name`. An empty `find`, an invalid regex or one that takes too long
    /// (`BoundedRegex`) leaves the name as is.
    public static func apply(_ name: String, find: String, replace: String, regex: Bool) -> String {
        var timedOut = false
        return apply(name, find: find, replace: replace, regex: regex, timedOut: &timedOut)
    }

    /// As `apply`, setting `timedOut` when the pattern was stopped.
    static func apply(_ name: String, find: String, replace: String, regex: Bool, timedOut: inout Bool) -> String {
        guard !find.isEmpty else { return name }
        if !regex { return name.replacingOccurrences(of: find, with: replace) }
        guard let expression = try? NSRegularExpression(pattern: find) else { return name }
        guard let replaced = BoundedRegex.replacing(expression, in: name, with: replace) else {
            timedOut = true
            return name
        }
        return replaced
    }

    /// A short message when `pattern` is not a valid regular expression, otherwise nil.
    public static func regexError(_ pattern: String) -> String? {
        guard !pattern.isEmpty else { return nil }
        return (try? NSRegularExpression(pattern: pattern)) == nil ? "Invalid regular expression" : nil
    }
}

extension RenameOptions {
    /// Applies this step's rules, in order, to a raw rendered name (before sanitising).
    func replacing(in name: String) -> String {
        var timedOut = false
        return replacing(in: name, timedOut: &timedOut)
    }

    /// As `replacing(in:)`; `timedOut` is set when a
    /// pattern was stopped (that rule changes nothing).
    func replacing(in name: String, timedOut: inout Bool) -> String {
        var current = name
        for rule in replacements {
            current = NameReplacement.apply(current, find: rule.find, replace: rule.replace, regex: rule.useRegex,
                                            timedOut: &timedOut)
        }
        return current
    }
}
