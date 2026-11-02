import Foundation

/// SINGLE PLACE for app identity (brief §Naming / acceptance 9).
/// build_app.sh reads these constants to generate Info.plist.
enum AppInfo {
    static let displayName = "QuickScribe"
    static let bundleID = "local.quickscribe"

    /// Sidecar contract (runbook §Contracts) — localhost only, port fixed.
    static let sidecarBase = "http://127.0.0.1:8790"

    /// PRIMARY hotkey chord (owner UX change 2026-09-18: modifier-only hold;
    /// the old ⌘⌥Space binding was removed — it collided with other apps).
    /// Hold ⌃⌘ = capture start (after `holdDwell` with no key press);
    /// release either modifier = stop, polish, insert. The actual flag masks
    /// live in HotkeyManager (the single behavioral source of truth); these
    /// unused constants used to duplicate them and have been removed.
    /// Human-readable labels — defined ONCE here (brief §Naming / acceptance 9).
    static let holdLabel = "⌃⌘"
    static let holdRewriteLabel = "⌃⌘⇧"
    /// Both modifiers must be held this long, with NO key press in between,
    /// before capture starts. Key press before dwell elapses → abort start and
    /// pass through (⌃⌘F / ⌃⌘Q / ⌃⌘Space keep working normally).
    static let holdDwell: TimeInterval = 0.15

    /// Streaming chunk boundary for /transcribe partial (runbook: ~1–2 s).
    /// Chunks are NON-overlapping: partial results concatenate verbatim,
    /// which makes final assembly exact (see docs/decisions/ADR-001).
    static let chunkSeconds: Double = 1.5

    /// Silence gate (t_b3e7802c "silent-input-must-not-lie"): chunks whose
    /// RMS is below this floor never reach the decoder. ~-48 dBFS — well
    /// under conversational speech (~-30..-20 dBFS), well over BlackHole
    /// digital silence. Mirrored in sidecar stt.py as defense-in-depth.
    static let silenceRmsFloor: Double = 0.004

    /// TTI budgets from brief §Speed (seconds) — polish wait is bounded by bucket.
    static let ttiBudgets: [(maxSeconds: Double, p50: Double)] = [
        (10, 1.5), (30, 2.5), (60, 5.0)
    ]
    static func ttiBudget(utteranceSeconds: Double) -> Double {
        for b in ttiBudgets where utteranceSeconds <= b.maxSeconds { return b.p50 }
        return 10.0
    }
}
