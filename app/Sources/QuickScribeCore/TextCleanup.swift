import Foundation

/// The always-on tidy-up. It can only remove clear fillers and fix the spacing
/// that leaves behind, so it can never reword anything.
public enum TextCleanup {
    // Case-sensitive on purpose: "er" is a filler, "the ER" is a place, and "UM"
    // is a university. "mm" is left alone because "5 mm" is a measurement.
    private static let filler = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}'’-])(?:[Uu]m+|[Uu]h+|[Ee]rm+|er|[Aa]h+|[Hh]mm+|[Mm]mm+)(?![\p{L}\p{N}'’-])"#)

    private static let repairs: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: #"[ \t]+"#), " "),
        (try! NSRegularExpression(pattern: #"\s+([,.;:!?])"#), "$1"),
        (try! NSRegularExpression(pattern: #",(?:\s*,)+"#), ","),
        (try! NSRegularExpression(pattern: #"[,;:]\s*([.!?])"#), "$1"),
        (try! NSRegularExpression(pattern: #"([.!?])\s*[,;:]+"#), "$1"),
        (try! NSRegularExpression(pattern: #"^[\s,;:.!?]+"#), ""),
    ]

    public static func tidy(_ text: String) -> String {
        let whole = NSRange(text.startIndex..., in: text)
        guard filler.firstMatch(in: text, range: whole) != nil else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var out = filler.stringByReplacingMatches(in: text, range: whole, withTemplate: "")
        for (pattern, template) in repairs {
            out = pattern.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                   withTemplate: template)
        }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.hasSuffix(",") { out = String(out.dropLast()) + "." }
        return capitalizingStart(out)
    }

    /// Removing a leading "Um" can leave a lowercase start. "iPhone" keeps its case.
    private static func capitalizingStart(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        let second = text.dropFirst().first
        if let second, second.isUppercase { return text }
        return first.uppercased() + text.dropFirst()
    }
}
