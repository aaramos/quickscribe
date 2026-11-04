import Foundation

/// SINGLE PLACE for app identity. build_app.sh reads these constants to generate
/// Info.plist. Its own name and bundle id keep its permissions and data apart from
/// the original QuickScribe.
enum AppInfo {
    static let displayName = "QuickScribe Native"
    static let bundleID = "local.quickscribe.native"

    /// Both apps listen for the same hotkey, so running them together would paste twice.
    static let originalBundleID = "local.quickscribe"

    static var dataFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(displayName, isDirectory: true)
    }

    /// Hold ⌃⌘ to capture (after `holdDwell` with no key press); release either
    /// modifier to stop, clean up and insert. Flag masks live in HotkeyManager.
    static let holdLabel = "⌃⌘"
    static let holdRewriteLabel = "⌃⌘⇧"
    /// Key press before the dwell elapses aborts the start and passes through, so
    /// ⌃⌘F, ⌃⌘Q and ⌃⌘Space keep working normally.
    static let holdDwell: TimeInterval = 0.15

    /// Audio is judged for silence in windows this long.
    static let silenceWindowSeconds: Double = 1.5

    /// About -48 dBFS: well under conversational speech, well over the digital
    /// silence of a virtual device like BlackHole.
    static let silenceRmsFloor: Double = 0.004

    /// How long a dictation of each length may take after release, in seconds. Past
    /// this, the rule-tidied text is inserted without waiting for the model.
    static let ttiBudgets: [(maxSeconds: Double, p50: Double)] = [
        (10, 1.5), (30, 2.5), (60, 5.0)
    ]
    static func ttiBudget(utteranceSeconds: Double) -> Double {
        for b in ttiBudgets where utteranceSeconds <= b.maxSeconds { return b.p50 }
        return 10.0
    }
}
