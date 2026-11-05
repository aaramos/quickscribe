import Foundation

public struct PromptEntry: Equatable, Sendable {
    public let id: String
    public let label: String
    public let prompt: String
    public let factory: String
    public let custom: Bool
    public init(id: String, label: String, prompt: String, factory: String, custom: Bool) {
        self.id = id; self.label = label; self.prompt = prompt; self.factory = factory; self.custom = custom
    }
}

public enum PromptProblem: Error, Equatable, LocalizedError {
    case empty
    case tooLong(tokens: Int)
    case unknownMode
    public var errorDescription: String? {
        switch self {
        case .empty: return "Prompt can't be empty."
        case .tooLong(let tokens): return "Prompt is about \(tokens) tokens; the limit is \(PromptLibrary.maxTokens)."
        case .unknownMode: return "Unknown mode."
        }
    }
}

/// Factory prompts plus the user's edits. Edits live in their own file, so an
/// app update can improve a factory prompt without touching what someone wrote.
public final class PromptLibrary {
    public static let maxTokens = 2000
    public static let labels: [(id: String, label: String)] = [
        ("polish", "Polish"), ("concise", "Concise"), ("active_voice", "Active Voice"),
    ]

    private let fileURL: URL
    private var overrides: [String: String]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        overrides = Self.load(fileURL)
    }

    public static func estimateTokens(_ text: String) -> Int {
        Int((Double(text.utf16.count) / 4).rounded(.up))
    }

    public static func validate(_ text: String) throws {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw PromptProblem.empty }
        let tokens = estimateTokens(text)
        if tokens > maxTokens { throw PromptProblem.tooLong(tokens: tokens) }
    }

    /// Apple's short prompts fit Apple's model; a general service gets the
    /// longer sidecar set. A person's own prompt for a mode wins on BOTH
    /// routes, because it is their wording, not our tuning.
    public func prompt(_ mode: String, route: CleanupRoute = .apple) -> String {
        if mode == FactoryPrompts.rewriteID {
            return route == .service ? ServicePrompts.rewrite : FactoryPrompts.rewrite
        }
        if let custom = overrides[mode] { return custom }
        if route == .service { return ServicePrompts.all[mode] ?? ServicePrompts.polish }
        return FactoryPrompts.all[mode] ?? FactoryPrompts.polish
    }

    public func entries() -> [PromptEntry] { Self.labels.compactMap { entry($0.id) } }

    public func entry(_ mode: String) -> PromptEntry? {
        guard let factory = FactoryPrompts.all[mode],
              let label = Self.labels.first(where: { $0.id == mode })?.label else { return nil }
        return PromptEntry(id: mode, label: label, prompt: overrides[mode] ?? factory,
                           factory: factory, custom: overrides[mode] != nil)
    }

    @discardableResult
    public func save(_ mode: String, text: String) throws -> PromptEntry {
        guard let factory = FactoryPrompts.all[mode] else { throw PromptProblem.unknownMode }
        try Self.validate(text)
        overrides[mode] = text == factory ? nil : text
        try persist()
        return entry(mode)!
    }

    @discardableResult
    public func reset(_ mode: String) throws -> PromptEntry {
        guard FactoryPrompts.all[mode] != nil else { throw PromptProblem.unknownMode }
        overrides[mode] = nil
        try persist()
        return entry(mode)!
    }

    /// A damaged file must never stop dictation: run on factory text instead.
    private static func load(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var clean: [String: String] = [:]
        for (mode, value) in raw where FactoryPrompts.all[mode] != nil {
            if let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                clean[mode] = text
            }
        }
        return clean
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: overrides, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: fileURL, options: .atomic)
    }
}
