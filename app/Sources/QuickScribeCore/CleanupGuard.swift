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

    // MARK: - Per-number honesty: money and a time of day

    private static let currencySymbols = CharacterSet(charactersIn: "$€£¥₹")
    private static let currencyWords: Set<String> = [
        "dollar", "dollars", "euro", "euros", "cent", "cents", "penny", "pennies",
        "pound", "pounds", "yen", "yuan", "rupee", "rupees", "franc", "francs",
        "peso", "pesos", "krona", "kronor", "krone", "kroner", "bucks", "usd", "eur",
        "gbp", "cad", "aud", "jpy", "inr", "chf", "rmb", "bitcoin", "bitcoins",
    ]

    /// One number in a text: the digits it stands for, and the characters
    /// sitting right before it and right after it. A marker is judged against
    /// its own number, never against the dictation as a whole: one said
    /// dollar does not license a sign on the account number at the end.
    private struct Numeral {
        let digits: String      // "4.2 million" and "fifty thousand" both arrive comparable
        let head: String        // up to 4 characters before the number
        let tail: String        // up to 30 after it
    }

    /// Number phrases: digit and number-word tokens with only plain gaps
    /// between them ("four" then "million"; a sentence period separates).
    /// Ordinals ("twelfth") are not in the list: a number written a shape we
    /// cannot compare is a match in doubt, and doubt falls back.
    private static let numberToken = try! NSRegularExpression(
        pattern: #"[0-9]+(?:[.,][0-9]+)*|one|two|three|four|five|six|seven|eight|nine|ten"#
            + "|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen"
            + "|twenty|thirty|forty|fifty|hundred|thousand|million|billion",
        options: [.caseInsensitive])

    /// A marker pressed right against a number, on either side of it.
    private static let afterMarker = try! NSRegularExpression(
        pattern: #"^\s*[.,;:]?\s*([ap])([.\s]*)m\b\s*([a-z]*)"#, options: [.caseInsensitive])

    private static func numerals(in text: String) -> [Numeral] {
        let lower = text.lowercased()
        let found = numberToken.matches(in: lower, range: NSRange(lower.startIndex..., in: lower))
        var runs: [(String.Index, String.Index)] = []
        for match in found {
            guard let r = Range(match.range, in: lower) else { continue }
            if let last = runs.last,
               !lower[last.1..<r.lowerBound].contains(where: { $0.isLetter || $0 == "." || $0 == "," }) {
                runs[runs.count - 1].1 = r.upperBound            // same spoken number
            } else {
                runs.append((r.lowerBound, r.upperBound))
            }
        }
        return runs.map { start, end in
            let headStart = lower.index(start, offsetBy: -4, limitedBy: lower.startIndex) ?? lower.startIndex
            let tailEnd = lower.index(end, offsetBy: 30, limitedBy: lower.endIndex) ?? lower.endIndex
            return Numeral(digits: digitString(String(lower[start..<end])),
                           head: String(lower[headStart..<start]),
                           tail: String(lower[end..<tailEnd]))
        }
    }

    private static func hasSymbolOn(_ n: Numeral) -> Bool {
        n.head.last(where: { !$0.isWhitespace }).map {
            $0.unicodeScalars.first.map(currencySymbols.contains) ?? false
        } ?? false
    }

    private static func currencyWordAfter(_ n: Numeral) -> Bool {
        let token = String(n.tail.drop { $0.isWhitespace }.prefix { $0.isLetter })
        return currencyWords.contains(token)
    }

    /// Which marker stands right after a number, a or p, or none. On the
    /// speaker's side, the verb is not a marker: "three am I right" says no
    /// a.m., and "I am" never said one either. On the written side every am
    /// glues itself to its hour and claims a time, doubt included: an answer
    /// the guard drops falls back to the person's own words, which is cheap.
    private static func markerOn(_ n: Numeral, allowingVerbException: Bool) -> Character? {
        let tail = n.tail
        guard let m = afterMarker.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
              let kindR = Range(m.range(at: 1), in: tail),
              let middleR = Range(m.range(at: 2), in: tail),
              let nextR = Range(m.range(at: 3), in: tail),
              let kind = tail[kindR].first
        else { return nil }
        if allowingVerbException, kind == "a", !tail[middleR].contains("."), tail[nextR] == "i" {
            return nil
        }
        return kind
    }

    /// A dollar sign must ride the number that was spoken with money.
    static func inventsCurrency(output: String, input: String) -> Bool {
        let signs = numerals(in: output).filter(hasSymbolOn)
        guard !signs.isEmpty else { return false }
        let given = numerals(in: input)
        return signs.contains { n in
            !given.contains { m in
                m.digits == n.digits && (hasSymbolOn(m) || currencyWordAfter(m))
            }
        }
    }

    /// A model that has seen "three on Friday" loves to hand back "3 p.m.",
    /// and the reader cannot tell the invented half from the real one. Each
    /// marker is allowed only on the number that was spoken wearing that same
    /// kind: a stated a.m. does not clear a written p.m., and "tonight" or
    /// "in the morning" says neither word.
    public static func inventsTimeOfDay(output: String, input: String) -> Bool {
        let written = numerals(in: output).compactMap { n in
            markerOn(n, allowingVerbException: false).map { (n.digits, $0) }
        }
        guard !written.isEmpty else { return false }
        let given = numerals(in: input)
        return written.contains { digits, kind in
            !given.contains { m in
                m.digits == digits && markerOn(m, allowingVerbException: true) == kind
            }
        }
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
