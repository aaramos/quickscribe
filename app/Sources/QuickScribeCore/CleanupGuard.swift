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

    // Fold a dotted time marker to its plain form. Match the marker itself, NOT
    // "the marker plus a trailing space": an end-of-sentence "3 p. m." has no
    // space after it to match, and consuming a following space would glue the next
    // word on ("p. m. today" into "pmtoday"). Both must fold to "pm today", so a
    // faithful cleanup of a spaced marker is never refused. Inventors are caught
    // separately by inventsTimeOfDay, which does not lean on this fold.
    private static func foldTimeDots(_ text: String) -> String {
        var folded = text
        for dotted in ["a.m.", "a. m.", "p.m.", "p. m."] {
            folded = folded.replacingOccurrences(of: dotted, with: dotted.first == "a" ? "am" : "pm",
                                                 options: .caseInsensitive)
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

    /// One number in a text: the digits it stands for, and the slices of the
    /// lowercased text sitting right before it and right after it, so a
    /// marker found in the tail can be placed back in the text. A marker is
    /// judged against its own number, never against the dictation as a
    /// whole: one said dollar does not license the account number at the end.
    private struct Numeral {
        let digits: String      // "4.2 million" and "fifty thousand" arrive comparable
        let end: String.Index   // where the number itself finishes, in the lowercased text
        let head: Substring     // up to 4 characters before it
        let tail: Substring     // up to 30 after it
    }

    /// Number tokens: written digits, spoken numbers, scale words. The words
    /// keep their boundaries, or "often" holds a ten and "someone" a one;
    /// the digits wear none on purpose, since "3pm" and "5dollars" are
    /// shapes real answers write. Ordinals ("twelfth") are absent: a number
    /// in a shape we cannot compare is a match in doubt, and doubt falls back.
    private static let numberToken = try! NSRegularExpression(
        pattern: #"(?:\b(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve"#
            + "|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty"
            + #"|thirty|forty|fifty|hundred|thousand|million|billion)\b"#
            + #"|[0-9]+(?:[.,][0-9]+)*)"#,
        options: [.caseInsensitive])

    /// A marker pressed right after a number, starting at the number's tail.
    private static let afterMarker = try! NSRegularExpression(
        pattern: #"^\s*[.,;:]?\s*([ap])([.\s]*)m\b\s*([a-z]*)"#, options: [.caseInsensitive])

    /// Every a.m./p.m. shape standing as its own words, glued to a number or
    /// not: "p.m.", "P.M.", "p m". "3pm" with no space is only ever spotted
    /// by the pressed-against rule above, never twice.
    private static let markerWord = try! NSRegularExpression(pattern: #"\b([ap])([.\s]*)m\b"#)

    private static func numerals(in text: String) -> [Numeral] {
        let lower = text.lowercased()
        let found = numberToken.matches(in: lower, range: NSRange(lower.startIndex..., in: lower))
        var runs: [(String.Index, String.Index)] = []
        for match in found {
            guard let r = Range(match.range, in: lower) else { continue }
            if let last = runs.last {
                let gap = lower[last.1..<r.lowerBound]
                let plainSpace = !gap.isEmpty && gap.allSatisfy { $0 == " " || $0 == "\t" }
                let digitColon = gap == ":"
                    && last.1 > lower.startIndex && lower[lower.index(before: last.1)].isNumber
                    && r.lowerBound < lower.endIndex && lower[r.lowerBound].isNumber
                if plainSpace || digitColon {
                    runs[runs.count - 1].1 = r.upperBound            // same spoken number
                    continue
                }
            }
            runs.append((r.lowerBound, r.upperBound))
            // A line break, a dash, a spaced colon, or a sign between tokens
            // ends the phrase: "3: 212" and "3 - 212" and a number under a
            // heading are two numbers, each judged on its own.
        }
        return runs.map { start, end in
            let headStart = lower.index(start, offsetBy: -4, limitedBy: lower.startIndex) ?? lower.startIndex
            let tailEnd = lower.index(end, offsetBy: 30, limitedBy: lower.endIndex) ?? lower.endIndex
            return Numeral(digits: digitString(String(lower[start..<end])),
                           end: end,
                           head: lower[headStart..<start],
                           tail: lower[end..<tailEnd])
        }
    }

    private static func isSymbol(_ c: Character) -> Bool {
        c.unicodeScalars.first.map(currencySymbols.contains) ?? false
    }

    /// A sign on its number, before or after: "$212" and "212€" wear it.
    private static func hasSymbolOn(_ n: Numeral) -> Bool {
        if let before = n.head.last(where: { !$0.isWhitespace }), isSymbol(before) { return true }
        if let after = n.tail.first(where: { !$0.isWhitespace }), isSymbol(after) { return true }
        return false
    }

    private static func currencyWordAfter(_ n: Numeral) -> Bool {
        let token = String(n.tail.drop { $0.isWhitespace }.prefix { $0.isLetter })
        return currencyWords.contains(token)
    }

    /// The marker pressed against a number: which kind, and where it starts
    /// inside the tail so it can be recognised again in a full scan. On the
    /// speaker's side the verb is not a marker: "three am I right" says no
    /// a.m. On the written side every am glues itself to its hour and
    /// claims a time, doubt included: the fallback to the person's own
    /// words costs nothing.
    private static func attachedMarker(_ n: Numeral,
                                       allowingVerbException: Bool) -> (kind: Character, offset: Int)? {
        let tail = String(n.tail)
        guard let m = afterMarker.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
              let kindR = Range(m.range(at: 1), in: tail),
              let middleR = Range(m.range(at: 2), in: tail),
              let nextR = Range(m.range(at: 3), in: tail),
              let kind = tail[kindR].first
        else { return nil }
        if allowingVerbException, kind == "a", !tail[middleR].contains("."), tail[nextR] == "i" {
            return nil
        }
        return (kind, tail.distance(from: tail.startIndex, to: kindR.lowerBound))
    }

    private static func verbNeighbor(leftOf idx: String.Index, in lower: String) -> Bool {
        var i = idx
        while i > lower.startIndex, lower[lower.index(before: i)].isWhitespace {
            i = lower.index(before: i)
        }
        let wordEnd = i
        while i > lower.startIndex {
            let before = lower[lower.index(before: i)]
            if before == "'" { i = lower.index(before: i); continue }        // "I'm"-style apostrophes
            if !before.isLetter { break }
            i = lower.index(before: i)
        }
        return lower[i..<wordEnd] == "i"
    }

    private static func verbNeighbor(rightOf idx: String.Index, in lower: String) -> Bool {
        var i = idx
        while i < lower.endIndex, lower[i].isWhitespace || lower[i] == "," || lower[i] == "?" {
            i = lower.index(after: i)
        }
        var end = i
        while end < lower.endIndex, lower[end].isLetter { end = lower.index(after: end) }
        return end > i && lower[i..<end] == "i"
    }

    /// A text's markers in two sorts: tied to a number, with that number's
    /// digits, and free-standing words. An answer may tie a marker only
    /// where its own number earned it, and may write a free marker only
    /// where the speaker wrote one free. Attached lookups on the answer
    /// side refuse a verb's am; the speaker's side keeps the exception.
    private static func markers(in text: String,
                                allowingVerbException: Bool) -> (tied: [(digits: String, kind: Character)], free: [Character]) {
        let lower = text.lowercased()
        var tied: [(digits: String, kind: Character)] = []
        var attachedAt: Set<String.Index> = []
        for n in numerals(in: text) {
            guard let m = attachedMarker(n, allowingVerbException: allowingVerbException) else { continue }
            tied.append((n.digits, m.kind))
            attachedAt.insert(lower.index(n.end, offsetBy: m.offset))
        }
        var free: [Character] = []
        for m in markerWord.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
            guard let whole = Range(m.range, in: lower),
                  let kindR = Range(m.range(at: 1), in: lower),
                  let middleR = Range(m.range(at: 2), in: lower),
                  !attachedAt.contains(kindR.lowerBound)
            else { continue }
            // A bare "am" leaning on the pronoun I is the verb wherever it
            // stands: "I am grabbing dinner" and "am I right" claim no time.
            // Dots ("a.m.") and p are always the time shape.
            if lower[whole] == "am", !lower[middleR].contains(".") {
                if verbNeighbor(leftOf: whole.lowerBound, in: lower)
                    || verbNeighbor(rightOf: whole.upperBound, in: lower) { continue }
            }
            free.append(lower[kindR].first!)
        }
        return (tied, free)
    }

    /// A dollar sign, or a money word, must ride the number that was spoken
    /// with money: an answer's "212 dollars" is a claim just as much as
    /// "212€" or "$212" is. One exception, because it is the speaker's own
    /// correction: when the text before a number names the amount in money and
    /// a correction word joins the two ("$1,200, actually 1450"), the corrected
    /// amount may take that same marker. Nothing else is inherited.
    static func inventsCurrency(output: String, input: String) -> Bool {
        let marked = numerals(in: output).filter { hasSymbolOn($0) || currencyWordAfter($0) }
        guard !marked.isEmpty else { return false }
        let given = numerals(in: input)
        let corrected = moneyInheritedAcrossCorrections(in: input)
        return marked.contains { n in
            if given.contains(where: { m in
                m.digits == n.digits && (hasSymbolOn(m) || currencyWordAfter(m))
            }) { return false }
            // A corrected amount may wear a marker its own number was not said
            // with, but only the marker of the amount it replaces, and only
            // that one: "$1,200, actually 1450" cannot become "€1,450".
            guard let inherited = corrected[n.digits] else { return true }
            return !moneyMarkers(n).isSubset(of: inherited)
        }
    }

    /// Every marker on one number as a currency, never as a shape: "$" and
    /// "dollars" are the same money, and "$" and "€" are not. That way a
    /// corrected amount may keep the money it was said with, and the model
    /// still cannot turn dollars into euros while it is correcting itself.
    private static func moneyMarkers(_ n: Numeral) -> Set<String> {
        var markers: Set<String> = []
        if let before = n.head.last(where: { !$0.isWhitespace }), isSymbol(before) {
            markers.insert(currency(before))
        }
        if let after = n.tail.first(where: { !$0.isWhitespace }), isSymbol(after) {
            markers.insert(currency(after))
        }
        let token = String(n.tail.drop { $0.isWhitespace }.prefix { $0.isLetter })
        if currencyWords.contains(token) { markers.insert(currency(token)) }
        return markers
    }

    /// Which money a marker names. A word with no group of its own stands for
    /// itself, so the comparison never guesses: unknown money matches only its
    /// own spelling.
    private static func currency(_ marker: Character) -> String {
        if let identity = symbolCurrencies[marker] { return identity }
        return currency(String(marker))
    }

    private static func currency(_ marker: String) -> String {
        wordCurrencies[marker.lowercased()] ?? marker.lowercased()
    }

    private static let symbolCurrencies: [Character: String] = ["$": "usd", "€": "eur", "£": "gbp", "¥": "jpy", "₹": "inr"]
    private static let wordCurrencies: [String: String] = [
        "dollar": "usd", "dollars": "usd", "buck": "usd", "bucks": "usd", "usd": "usd",
        "euro": "eur", "euros": "eur", "eur": "eur",
        "pound": "gbp", "pounds": "gbp", "gbp": "gbp",
        "yen": "jpy", "jpy": "jpy",
        "yuan": "cny", "rmb": "cny",
        "rupee": "inr", "rupees": "inr", "inr": "inr",
        "franc": "chf", "francs": "chf", "chf": "chf",
        "peso": "mxn", "pesos": "mxn", "krona": "sek", "kronor": "sek", "krone": "nok", "kroner": "nok",
        "bitcoin": "btc", "bitcoins": "btc", "cad": "cad", "aud": "aud",
        "cent": "cent", "cents": "cent", "penny": "cent", "pennies": "cent",
    ]

    private static let correctionWords: Set<String> = ["actually", "sorry", "no"]

    /// The amount a correction is moving to, and the markers of the amount it
    /// replaces: "the total is $1,200, actually 1450" inherits the sign for
    /// "1450". Only the number right before the correction word carries over,
    /// so a long chain falls back to the speaker's own words.
    private static func moneyInheritedAcrossCorrections(in text: String) -> [String: Set<String>] {
        let numbers = numerals(in: text)
        guard numbers.count > 1 else { return [:] }
        let lower = text.lowercased()
        var inherited: [String: Set<String>] = [:]
        for index in numbers.indices.dropLast() {
            let replaced = numbers[index], corrected = numbers[index + 1]
            let markers = moneyMarkers(replaced)
            guard !markers.isEmpty else { continue }
            // The gap runs from the end of one number to the start of the next.
            // A Numeral's head always ends exactly where its number begins.
            let gap = lower[replaced.end..<corrected.head.endIndex]
            guard joinsACorrection(gap) else { continue }
            inherited[corrected.digits, default: []].formUnion(markers)
        }
        return inherited
    }

    /// A correction word standing between two amounts, and nothing else that
    /// could carry meaning: "actually", "sorry", "no", "I mean". A gap with
    /// other words in it ("for 14 people, no") is not a correction of the
    /// amount, and doubt falls back to the speaker's own words.
    private static func joinsACorrection(_ gap: Substring) -> Bool {
        var tokens = words(String(gap))
        // The connective a person actually says around a correction, and the
        // punctuation the words() split throws away anyway. The money word
        // that follows the replaced amount ("1,200 dollars, actually 1450")
        // is part of that amount, not part of the gap.
        let filler: Set<String> = Set(["and", "but", "or", "it", "is", "was", "the", "a", "an", "that", "this", "of"])
            .union(currencyWords)
        tokens.removeAll { filler.contains($0) }
        guard !tokens.isEmpty else { return false }
        if tokens == ["i", "mean"] { return true }
        return tokens.count == 1 && correctionWords.contains(tokens[0])
    }

    /// A model that has seen "three on Friday" loves to hand back "3 p.m."
    /// or "Friday p.m.", and the reader cannot tell the invented half from
    /// the real one. Each tied marker needs its own digits wearing the same
    /// kind; a stated a.m. does not clear a written p.m., not on this hour
    /// or any other. Each free-standing marker needs the speaker to have
    /// written one free-standing too: "tonight" and "in the morning" say
    /// neither word, and an hour said bare stays bare.
    public static func inventsTimeOfDay(output: String, input: String) -> Bool {
        let written = markers(in: output, allowingVerbException: false)
        let given = markers(in: input, allowingVerbException: true)
        return written.tied.contains { claim in
                   !given.tied.contains { $0.digits == claim.digits && $0.kind == claim.kind }
               } || written.free.contains { !given.free.contains($0) }
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
