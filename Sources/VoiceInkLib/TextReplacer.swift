import Foundation

/// Applies user-defined word replacements to ASR output.
/// Use case: Whisper consistently mis-transcribes a name/term and the user wants
/// to fix it automatically (e.g. "Демале" → "ДеМоле").
///
/// Matching is:
/// - Word-boundary aware (does not match inside longer words)
/// - Case-insensitive on the search side
/// - Verbatim on the replacement side (user-supplied case is preserved)
public enum TextReplacer {

    /// Apply all replacements from `dictionary` to `text` in a single pass.
    /// Empty keys are ignored. Replacements are applied in the order Swift's Dictionary
    /// iterates (effectively unordered) — overlapping rules should be designed to be
    /// non-conflicting by the user.
    public static func apply(_ text: String, replacements dictionary: [String: String]) -> String {
        guard !dictionary.isEmpty, !text.isEmpty else { return text }

        var result = text
        for (from, to) in dictionary {
            guard !from.isEmpty else { continue }
            result = replaceWordBoundary(in: result, from: from, to: to)
        }
        return result
    }

    /// Replace all occurrences of `from` (word-bounded, case-insensitive) with `to`.
    /// Word boundary uses Unicode-aware regex \b which works for both Latin and Cyrillic.
    private static func replaceWordBoundary(in text: String, from: String, to: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: from)
        let pattern = "\\b\(escaped)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        // Escape $ in the replacement so it doesn't get interpreted as backreference
        let safeTo = to.replacingOccurrences(of: "$", with: "\\$")
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: safeTo)
    }
}
