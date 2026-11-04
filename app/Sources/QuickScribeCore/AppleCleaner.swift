import Foundation
import FoundationModels

public enum CleanupFailure: Error, Equatable, Sendable {
    case refused
    case tooLong
    case unavailable(String)
    case blank
    case timedOut
    case other(String)
}

/// Text cleanup on Apple's on-device model. Every request gets a fresh session,
/// so nothing said in one dictation can color the next.
public struct AppleCleaner: Sendable {
    public enum Filter: Sendable { case standard, permissive }

    private let filter: Filter

    /// Permissive is Apple's filter setting for rewriting the user's own text, which
    /// is all this does. Dictation about ordinary hard topics must still come out.
    public init(filter: Filter = .permissive) {
        self.filter = filter
    }

    private var model: SystemLanguageModel {
        switch filter {
        case .standard: return SystemLanguageModel()
        case .permissive: return SystemLanguageModel(guardrails: .permissiveContentTransformations)
        }
    }

    /// nil when ready; otherwise a sentence a person can act on.
    public static func unavailableReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "This Mac can't run Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings to use cleanup."
        case .unavailable(.modelNotReady): return "Apple's AI model is still downloading."
        case .unavailable: return "Apple's AI model isn't available right now."
        }
    }

    public func prewarm() {
        LanguageModelSession(model: model).prewarm()
    }

    public func clean(_ text: String, instructions: String) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: instructions)
        // Greedy gives the same output for the same words, which suits cleanup.
        let options = GenerationOptions(samplingMode: .greedy, temperature: 0)
        let output: String
        do {
            output = try await session.respond(to: "Dictation:\n\(text)", options: options).content
        } catch {
            throw Self.classify(error)
        }
        let trimmed = Self.withoutTrailingSpaces(output).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw CleanupFailure.blank }
        return trimmed
    }

    /// The model ends lines with invisible Markdown spaces, which shouldn't reach a document.
    static func withoutTrailingSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: #"[ \t]+(?=\n|$)"#, with: "", options: .regularExpression)
    }

    public var contextSize: Int { model.contextSize }

    private static func classify(_ error: Error) -> CleanupFailure {
        if let e = error as? LanguageModelError {
            switch e {
            case .guardrailViolation, .refusal: return .refused
            case .contextSizeExceeded: return .tooLong
            case .timeout: return .timedOut
            default: return .other(e.localizedDescription)
            }
        }
        return .other(error.localizedDescription)
    }
}
