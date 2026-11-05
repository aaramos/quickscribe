import Foundation
import QuickScribeCore

/// When to ask the model and which text to insert. SessionController only carries
/// these decisions out, so the policy can be tested without audio or a model.
///
/// There is one attempt, not a retry: cleanup output is deterministic, so a refusal
/// would simply repeat. A failure always falls back to the rule-tidied text, because
/// the person's words must never be lost. (Filler-only
/// speech is kept too, so a tidied result that comes out empty falls back to raw.)
enum PolishPlanner {
    enum Step: Equatable {
        case askModel(timeout: TimeInterval, tidied: String)
        case insert(String, cleaned: Bool)
    }

    static func firstStep(raw: String, tidied: String, modelReady: Bool, budget: Double, spent: TimeInterval) -> Step {
        guard !tidied.isEmpty else { return .insert(raw, cleaned: false) }
        let remaining = budget - spent
        guard modelReady, remaining > 0 else { return .insert(tidied, cleaned: false) }
        return .askModel(timeout: remaining, tidied: tidied)
    }

    static func usable(_ output: String?) -> Bool {
        guard let output else { return false }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The model's output only reaches the document if it passes CleanupGuard. Otherwise
    /// the person's own tidied words go in, so an answer or a refusal can never be pasted.
    static func stepAfterModel(output: String?, tidied: String, mode: String) -> Step {
        guard usable(output), let output,
              CleanupGuard.accepts(output: output, input: tidied, mode: mode) else {
            return .insert(tidied, cleaned: false)
        }
        return .insert(output, cleaned: true)
    }
}
