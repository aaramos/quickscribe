import Foundation

/// Checks that the model cleaned the dictation rather than doing something else
/// with it. Apple's model sometimes answers a dictated question or obeys a dictated
/// command, and no prompt fully stops that, so its output is checked before it can
/// reach the person's document. When in doubt the tidied text is inserted: losing a
/// cleanup is cheap, and inserting an answer nobody dictated is not.
public enum CleanupGuard {
    private struct Limits { let maxNewWords: Double; let minLength: Double }

    private static func limits(_ mode: String) -> Limits? {
        switch mode {
        case "polish": return Limits(maxNewWords: 0.34, minLength: 0.4)
        case "concise": return Limits(maxNewWords: 0.5, minLength: 0.25)
        case "active_voice": return Limits(maxNewWords: 0.5, minLength: 0.4)
        // Rewrite is meant to change the wording, so only output that's nearly all new
        // words counts as something other than a rewrite, like an obeyed "tell me a joke".
        case FactoryPrompts.rewriteID: return Limits(maxNewWords: 0.75, minLength: 0.25)
        default: return nil
        }
    }

    public static func accepts(output: String, input: String, mode: String) -> Bool {
        guard digitsComeFromInput(output: output, input: input) else { return false }
        // A question that came back as a statement has been answered.
        if input.contains("?"), !output.contains("?") { return false }
        guard let limits = limits(mode) else { return true }
        // Numbers have their own check above, and "five five five" can rightly
        // become "555", so they don't count as words here.
        let given = words(input).filter(isNotNumber), produced = words(output).filter(isNotNumber)
        guard !produced.isEmpty || given.isEmpty else { return false }
        if Double(produced.count) < Double(given.count) * limits.minLength { return false }
        if Double(produced.count) > Double(given.count) * 1.5 + 8 { return false }
        let known = Set(given)
        let new = produced.filter { !known.contains($0) }
        if !produced.isEmpty, Double(new.count) / Double(produced.count) > limits.maxNewWords { return false }
        return !addsAName(output: output, known: known)
    }

    private static func isNotNumber(_ word: String) -> Bool {
        units[word] == nil && scales[word] == nil && !word.allSatisfy(\.isNumber)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }

    /// A capitalized word mid-sentence that was never said, like the "Paris" in an
    /// answer to "what is the capital of France".
    private static func addsAName(output: String, known: Set<String>) -> Bool {
        let tokens = output.split(whereSeparator: \.isWhitespace).map(String.init)
        for (index, token) in tokens.enumerated() where index > 0 {
            let previous = tokens[index - 1]
            if previous.last.map({ ".!?:\n".contains($0) }) == true { continue }
            let bare = token.trimmingCharacters(in: .punctuationCharacters)
            guard let first = bare.first, first.isUppercase, first.isLetter else { continue }
            if !known.contains(bare.lowercased().replacingOccurrences(of: "’", with: "'")) { return true }
        }
        return false
    }

    /// Every digit the model writes has to come from something the person said, in
    /// order, so "2, actually 3" may become "3" but no sum can appear from nowhere.
    private static func digitsComeFromInput(output: String, input: String) -> Bool {
        var remaining = Substring(digitString(input))
        for digit in digitString(output) {
            guard let found = remaining.firstIndex(of: digit) else { return false }
            remaining = remaining[remaining.index(after: found)...]
        }
        return true
    }

    private static let units: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40,
        "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = ["hundred": 100, "thousand": 1000, "million": 1_000_000]

    /// All numbers in the text as one run of digits, spelled-out ones included.
    static func digitString(_ text: String) -> String {
        let cleaned = text.lowercased().replacingOccurrences(of: #"(?<=\d),(?=\d)"#, with: "", options: .regularExpression)
        var out = ""
        var value: Int?
        func flush() {
            if let value { out += String(value) }
            value = nil
        }
        for token in cleaned.components(separatedBy: CharacterSet.alphanumerics.inverted) where !token.isEmpty {
            if let unit = units[token] {
                // "five five five" stays three numbers; "twenty five" is one.
                if let current = value, current >= 20, current % 10 == 0, unit < 10, current < 100 {
                    value = current + unit
                } else {
                    flush()
                    value = unit
                }
            } else if let scale = scales[token], let current = value {
                value = current * scale
            } else {
                flush()
                let digits = token.filter(\.isNumber)
                if !digits.isEmpty { out += digits }
            }
        }
        flush()
        return out
    }
}
