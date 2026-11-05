import Foundation

/// Checks that the model cleaned the dictation rather than doing something else
/// with it. Apple's model sometimes answers a dictated question or obeys a dictated
/// command, and no prompt fully stops that, so its output is checked before it can
/// reach the person's document. When in doubt the tidied text is inserted: losing a
/// cleanup is cheap, and inserting an answer nobody dictated is not.
public enum CleanupGuard {
    private struct Limits {
        let maxNewWords: Double
        let minLength: Double
        var maxGrowth = 1.5
        var extraWords = 8.0
        var maxNewInSentence = 0.5
    }

    private static func limits(_ mode: String) -> Limits? {
        switch mode {
        case "polish": return Limits(maxNewWords: 0.34, minLength: 0.4)
        case "concise": return Limits(maxNewWords: 0.5, minLength: 0.25, maxNewInSentence: 0.75)
        case "active_voice": return Limits(maxNewWords: 0.5, minLength: 0.4)
        // Rewrite is meant to change the wording, so only output that's nearly all new
        // words counts as something other than a rewrite, like an obeyed "tell me a joke".
        // It's meant to tighten too, so it can't grow much: that catches a joke or an
        // invented summary with the speaker's own words stuck on the front.
        case FactoryPrompts.rewriteID: return Limits(maxNewWords: 0.75, minLength: 0.25, maxGrowth: 1.2, extraWords: 4, maxNewInSentence: 0.85)
        default: return nil
        }
    }

    /// Which rule stamped an answer, so the pill can say something true.
    public enum Refusal: String, CaseIterable, Equatable, Sendable {
        case changedNumbers, addedMoney, addedTimeOfDay, answeredTheQuestion, emptied,
             droppedTooMuch, grewTooMuch, rewordedTooMuch, addedASentence, addedAName
    }

    /// The model's output only reaches the document if it passes every rule.
    /// Returns nil when it passes, the broken rule's name otherwise.
    public static func refusal(output rawOutput: String, input rawInput: String, mode: String) -> Refusal? {
        guard digitsComeFromInput(output: rawOutput, input: rawInput) else { return .changedNumbers }
        guard !inventsCurrency(output: rawOutput, input: rawInput) else { return .addedMoney }
        guard !inventsTimeOfDay(output: rawOutput, input: rawInput) else { return .addedTimeOfDay }
        // Dots in am/pm must not read as brand-new words when the model restyled
        // "three pm" as "3 p.m."; both sides fold to the same tokens first.
        let output = foldTimeDots(rawOutput), input = foldTimeDots(rawInput)
        // A question that came back as a statement has been answered.
        if input.contains("?"), !output.contains("?") { return .answeredTheQuestion }
        guard let limits = limits(mode) else { return nil }
        // Numbers have their own check above, and "five five five" can rightly
        // become "555", so they don't count as words here.
        let given = words(input).filter(isNotNumber), produced = words(output).filter(isNotNumber)
        guard !produced.isEmpty || given.isEmpty else { return .emptied }
        if Double(produced.count) < Double(given.count) * limits.minLength { return .droppedTooMuch }
        if Double(produced.count) > Double(given.count) * limits.maxGrowth + limits.extraWords { return .grewTooMuch }
        let known = Set(given)
        let new = produced.filter { !known.contains($0) }
        if !produced.isEmpty, Double(new.count) / Double(produced.count) > limits.maxNewWords { return .rewordedTooMuch }
        if addsASentence(output: output, known: known, limit: limits.maxNewInSentence) { return .addedASentence }
        return addsAName(output: output, known: known) ? .addedAName : nil
    }

    public static func accepts(output rawOutput: String, input rawInput: String, mode: String) -> Bool {
        refusal(output: rawOutput, input: rawInput, mode: mode) == nil
    }

    /// The whole-text limits can't see one invented sentence in a long dictation, like
    /// the "I am a foundation model developed by Apple." the model sometimes puts first,
    /// so each sentence is also judged alone. Very short ones are too easy to trip.
    private static func addsASentence(output: String, known: Set<String>, limit: Double) -> Bool {
        output.split(whereSeparator: { ".!?\n".contains($0) }).contains { sentence in
            let spoken = words(String(sentence)).filter(isNotNumber)
            guard spoken.count >= 4 else { return false }
            return Double(spoken.filter { !known.contains($0) }.count) / Double(spoken.count) > limit
        }
    }

    private static func isNotNumber(_ word: String) -> Bool {
        units[word] == nil && scales[word] == nil && !word.allSatisfy(\.isNumber)
    }

    private static func foldTimeDots(_ text: String) -> String {
        var folded = text
        for (dotted, plain) in [("a.m.", "am"), ("p.m.", "pm")] {
            folded = folded.replacingOccurrences(of: dotted, with: plain, options: .caseInsensitive)
            folded = folded.replacingOccurrences(of: dotted.replacingOccurrences(of: ".", with: ". "),
                                                 with: plain, options: .caseInsensitive)
        }
        return folded
    }

    /// Marker shapes, on both sides: dotted or spaced "a. m."/"p m", a bare
    /// pm, or one pressed against a digit. The verb in "I am" matches none of
    /// them, and "3 am I right" is a question glued to the hour, not a.m.:
    /// a.m. never stands before "I".
    private static let spokenTimeMarker = try! NSRegularExpression(
        pattern: #"\b[ap][.\s]+m\b|\bpm\b|[0-9]\s*a\s*m\b(?!\s+[Ii]\b)|[0-9]\s*p\s*m\b"#,
        options: [.caseInsensitive])

    /// A time of day written onto the answer: the same shapes, plus the hour
    /// word worn onto am ("three am"), which speech writes without a digit.
    /// The verb after "I" ("3 am I right", "I am") is never a shape.
    private static let writtenTimeSuffix = try! NSRegularExpression(
        pattern: #"\b[ap][.\s]+m\.?\b|\bpm\b|[0-9]\s*p\s*m\b|\b(?:[a-hj-z]+|[0-9]+)\s*a\s*m\b(?!\s+[Ii]\b)"#,
        options: [.caseInsensitive])

    /// A model that has seen "three on Friday" loves to hand back "3 p.m.",
    /// and the reader cannot tell the invented half from the real one. An
    /// answer may write a.m./p.m. only where the speaker said one; "tonight"
    /// and "in the morning" are not saying it.
    public static func inventsTimeOfDay(output: String, input: String) -> Bool {
        let range = NSRange(output.startIndex..., in: output)
        guard writtenTimeSuffix.firstMatch(in: output, range: range) != nil else { return false }
        let given = NSRange(input.startIndex..., in: input)
        return spokenTimeMarker.firstMatch(in: input, range: given) == nil
    }

    private static let currencySymbols = CharacterSet(charactersIn: "$€£¥₹")
    private static let currencyWords: Set<String> = [
        "dollar", "dollars", "euro", "euros", "cent", "cents", "penny", "pennies",
        "pound", "pounds", "yen", "yuan", "rupee", "rupees", "franc", "francs",
        "peso", "pesos", "krona", "kronor", "krone", "kroner", "bucks", "usd", "eur",
        "gbp", "cad", "aud", "jpy", "inr", "chf", "rmb", "bitcoin", "bitcoins",
    ]

    /// A dollar sign on a number the speaker never gave a currency to is a
    /// wrong number wearing a right one: "4.2 million" must not come back as
    /// "$4.2 million". With a currency word or symbol in the dictation, the
    /// symbol is just formatting ("4.2 million dollars" to "$4.2 million").
    static func inventsCurrency(output: String, input: String) -> Bool {
        guard output.rangeOfCharacter(from: currencySymbols) != nil else { return false }
        if input.rangeOfCharacter(from: currencySymbols) != nil { return false }
        return !words(input).contains { currencyWords.contains($0) }
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
