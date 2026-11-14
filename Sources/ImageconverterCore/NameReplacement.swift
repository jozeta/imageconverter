import Foundation

/// Find and replace on a rendered file name, plain or regular expression.
public enum NameReplacement {
    /// Replaces every match of `find` in `name`. An empty `find` or an invalid regex leaves the name as is.
    public static func apply(_ name: String, find: String, replace: String, regex: Bool) -> String {
        guard !find.isEmpty else { return name }
        if !regex { return name.replacingOccurrences(of: find, with: replace) }
        guard let expression = try? NSRegularExpression(pattern: find) else { return name }
        let range = NSRange(location: 0, length: (name as NSString).length)
        return expression.stringByReplacingMatches(in: name, options: [], range: range, withTemplate: replace)
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
        replacements.reduce(name) { current, rule in
            NameReplacement.apply(current, find: rule.find, replace: rule.replace, regex: rule.useRegex)
        }
    }
}
