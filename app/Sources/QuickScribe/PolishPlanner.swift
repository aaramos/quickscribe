import Foundation

/// Pure polish-orchestration policy (t_a0fb24bb) — the HotkeyManager.reduce /
/// SidecarHealth pattern: SessionController's async glue only EXECUTES the
/// returned steps; every decision (budget, blank handling, retry allowance,
/// stale-callback rejection) lives here and is unit-tested in
/// Tests/QuickScribeTests.
///
/// Hard rules encoded:
/// • Neither request may receive a timeout exceeding the REMAINING budget
///   (old code guaranteed a 200 ms request even after the bucket expired).
/// • Exhausted budget → insert raw immediately, degraded — NO request.
/// • At most ONE retry, and only when time remains after the first failure.
/// • degraded=true from the sidecar and a blank (empty/whitespace) 200 result
///   are both "unusable polish" → same ladder (owner decision 2026-11-01:
///   keep raw fallback, including filler-only speech — never silently drop
///   the transcript).
/// • A callback from a superseded generation (cancel/new session) is a no-op.
enum PolishPlanner {
    enum Step: Equatable {
        case stale                        // generation moved on — do nothing
        case request(timeout: TimeInterval)
        case insertPolished(String)       // usable result — insert it, not degraded
        case insertRaw                    // budget gone or polish unusable — raw, degraded
    }

    /// A result is usable only when NOT degraded and non-blank.
    static func usable(polished: String?, degraded: Bool) -> Bool {
        guard !degraded, let t = polished else { return false }
        return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// First attempt: request only while budget remains; else raw immediately.
    static func firstStep(budget: Double, spent: TimeInterval) -> Step {
        let remaining = budget - spent
        guard remaining > 0 else { return .insertRaw }
        return .request(timeout: remaining)   // ≤ budget by construction
    }

    /// After an attempt returns. `attempt` is 1-based; a second (or later)
    /// unusable result falls back to raw regardless of any leftover budget.
    static func stepAfterResult(budget: Double, spent: TimeInterval, attempt: Int,
                                stale: Bool, polished: String?, degraded: Bool) -> Step {
        if stale { return .stale }
        if usable(polished: polished, degraded: degraded) { return .insertPolished(polished!) }
        guard attempt < 2 else { return .insertRaw }
        return firstStep(budget: budget, spent: spent)   // retry only if time remains
    }
}
