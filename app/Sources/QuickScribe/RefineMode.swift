import Foundation
import QuickScribeCore

/// The everyday cleanup modes. Prompt text lives in PromptLibrary.
struct RefineMode: Equatable {
    let id: String
    let title: String

    static let all = [
        RefineMode(id: "polish", title: "Polish"),
        RefineMode(id: "concise", title: "Concise"),
        RefineMode(id: "active_voice", title: "Active Voice"),
    ]
    static let rewriteProfile = "rewrite"
    static let defaultProfile = "polish"
    private static let storageKey = "QuickScribeDefaultProfile"

    static func title(forProfile profile: String) -> String {
        profile == rewriteProfile ? "Rewrite" : (all.first { $0.id == profile }?.title ?? profile)
    }

    /// The saved default, or Polish when nothing valid was saved.
    static func savedProfile(in defaults: UserDefaults = .standard) -> String {
        guard let saved = defaults.string(forKey: storageKey),
              saved == rewriteProfile || all.contains(where: { $0.id == saved }) else {
            return defaultProfile
        }
        return saved
    }

    static func saveProfile(_ profile: String, in defaults: UserDefaults = .standard) {
        defaults.set(profile, forKey: storageKey)
    }
}

/// A spoken "switch to concise". Only the start of a dictation counts, and only
/// when the phrase stands alone or ends in punctuation, so ordinary sentences
/// such as "switch to concise emails next quarter" are dictated as written.
enum VoiceModeCommand {
    struct Match: Equatable {
        let modeID: String
        let remainder: String
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"^\s*switch to (?:the )?(polish|concise|active[ -]voice)(?: mode)?\s*(?:[.!?,:;]+\s*(.*))?$"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])

    static func parse(_ raw: String) -> Match? {
        let whole = NSRange(raw.startIndex..., in: raw)
        guard let m = pattern.firstMatch(in: raw, range: whole),
              let nameRange = Range(m.range(at: 1), in: raw) else { return nil }
        let spoken = raw[nameRange].lowercased().replacingOccurrences(of: "-", with: " ")
        guard let mode = RefineMode.all.first(where: { $0.title.lowercased() == spoken }) else { return nil }
        let rest = Range(m.range(at: 2), in: raw).map { String(raw[$0]) } ?? ""
        return Match(modeID: mode.id, remainder: rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// What the prompt editor is showing: the saved prompts plus unsaved edits.
/// Drafts survive moving between modes, so switching never loses typing.
struct PromptDrafts {
    private(set) var entries: [PromptEntry] = []
    private var drafts: [String: String] = [:]

    mutating func load(_ fresh: [PromptEntry]) {
        entries = fresh
    }

    func entry(_ modeID: String) -> PromptEntry? {
        entries.first { $0.id == modeID }
    }

    func text(_ modeID: String) -> String {
        drafts[modeID] ?? entry(modeID)?.prompt ?? ""
    }

    func isDirty(_ modeID: String) -> Bool {
        guard let entry = entry(modeID) else { return false }
        return text(modeID) != entry.prompt
    }

    mutating func edit(_ modeID: String, text: String) {
        drafts[modeID] = text
    }

    /// A save or a reset went through: the stored prompt replaces the draft.
    mutating func commit(_ saved: PromptEntry) {
        drafts[saved.id] = nil
        if let i = entries.firstIndex(where: { $0.id == saved.id }) {
            entries[i] = saved
        }
    }
}
