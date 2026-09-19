import Foundation

/// SINGLE PLACE for app identity (brief §Naming / acceptance 9).
/// build_app.sh reads these constants to generate Info.plist.
enum AppInfo {
    static let displayName = "QuickScribe"
    static let bundleID = "local.quickscribe"

    /// Sidecar contract (runbook §Contracts) — localhost only, port fixed.
    static let sidecarBase = "http://127.0.0.1:8790"

    /// Tap vs hold discrimination threshold (seconds). Hold wins on press:
    /// press always starts capture; only a *quick release* switches to toggle.
    static let tapThreshold: TimeInterval = 0.25

    /// Streaming chunk boundary for /transcribe partial (runbook: ~1–2 s).
    /// Chunks are NON-overlapping: partial results concatenate verbatim,
    /// which makes final assembly exact (see docs/decisions/ADR-001).
    static let chunkSeconds: Double = 1.5

    /// TTI budgets from brief §Speed (seconds) — polish wait is bounded by bucket.
    static let ttiBudgets: [(maxSeconds: Double, p50: Double)] = [
        (10, 1.5), (30, 2.5), (60, 5.0)
    ]
    static func ttiBudget(utteranceSeconds: Double) -> Double {
        for b in ttiBudgets where utteranceSeconds <= b.maxSeconds { return b.p50 }
        return 10.0
    }
}
