import Foundation

/// One model a service offers, and what the service says it is for. The type
/// is optional because plain OpenAI-style servers do not send one.
public struct ModelEntry: Equatable, Sendable {
    public let id: String
    public let modelType: String?

    public init(id: String, modelType: String? = nil) {
        self.id = id
        self.modelType = modelType
    }
}

/// Which models the menu offers for speech and for cleanup, and which it
/// leaves out. One small pure function, so the rule can be read, tested and
/// argued with without a server or a window.
public enum ModelCatalog {
    public struct Lists: Equatable, Sendable {
        public let speech: [String]
        public let cleanup: [String]
        public let hidden: [String]
    }

    /// Types a service can name. A stated type is believed, and nothing is
    /// guessed around it: a model typed "embedding" is hidden even when its
    /// name says speech.
    static let speechTypes: Set<String> = ["audio_stt", "stt", "asr"]
    static let cleanupTypes: Set<String> = ["llm", "vlm"]

    /// Names used when the service says nothing. A name that looks like speech
    /// is speech; a name that looks like something else entirely is left out;
    /// everything else is offered for cleanup, so nothing useful disappears.
    static let speechWords = ["whisper", "transcribe", "parakeet", "voxtral", "asr", "stt", "speech"]
    static let hiddenWords = ["embed", "rerank", "tts", "image"]

    /// Splits a service's list, keeping the order it was given. Duplicates
    /// collapse to the first sighting, so a service that lists a model twice
    /// cannot produce two menu entries with one name.
    public static func split(_ entries: [ModelEntry]) -> Lists {
        var speech: [String] = [], cleanup: [String] = [], hidden: [String] = []
        var seen: Set<String> = []
        for entry in entries {
            let id = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            switch kind(of: entry) {
            case .speech: speech.append(id)
            case .cleanup: cleanup.append(id)
            case .hidden: hidden.append(id)
            }
        }
        return Lists(speech: speech, cleanup: cleanup, hidden: hidden)
    }

    public enum Kind: Equatable, Sendable { case speech, cleanup, hidden }

    /// One model's place. A stated type decides alone; without one, the name
    /// decides. A name matching nothing is cleanup, never dropped.
    public static func kind(of entry: ModelEntry) -> Kind {
        let type = entry.modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let type, !type.isEmpty {
            if speechTypes.contains(type) { return .speech }
            if cleanupTypes.contains(type) { return .cleanup }
            return .hidden
        }
        let name = entry.id.lowercased()
        if speechWords.contains(where: name.contains) { return .speech }
        if hiddenWords.contains(where: name.contains) { return .hidden }
        return .cleanup
    }
}
