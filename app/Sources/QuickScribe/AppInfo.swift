import Foundation
import QuickScribeCore

/// SINGLE PLACE for app identity. build_app.sh reads these constants to generate
/// Info.plist. The bundle id stays the one from the first release, so people who
/// installed that one keep their permissions and settings.
enum AppInfo {
    static let displayName = "QuickScribe"
    static let bundleID = "local.quickscribe.native"

    /// The only version number. build_app.sh reads it into the app's Info.plist.
    static let version = "2.1.0"

    /// The build number and source commit build_app.sh stamped into Info.plist.
    /// A copy run outside an app bundle (tests, swift run) has neither.
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev" }
    static var commit: String? { Bundle.main.infoDictionary?["QuickScribeCommit"] as? String }

    /// What About QuickScribe says: "2.1.0", and "Build 57 (e2e5183)".
    static func aboutLines(version: String, build: String, commit: String?) -> (version: String, build: String) {
        let source = commit.flatMap { $0.isEmpty || $0 == "unknown" ? nil : $0 }
        return (version, source.map { "Build \(build) (\($0))" } ?? "Build \(build)")
    }

    /// Where releases live. The update check reads this repo's latest release;
    /// the menu's update item installs that release's QuickScribe.zip, or
    /// links to its page when the release has only a disk image.
    static let githubRepo = "aaramos/quickscribe"

    /// The environment variable that points the update check at a rehearsal
    /// feed on this Mac (127.0.0.1 or localhost only). See RELEASING.md. A
    /// download from it must still carry this app's own signature.
    static let testFeedVariable = "QUICKSCRIBE_UPDATE_FEED"

    static var updateFeed: UpdateFeed? {
        if let base = ProcessInfo.processInfo.environment[testFeedVariable], !base.isEmpty {
            return UpdateFeed.local(base: base)    // a bad value checks nowhere, never GitHub by surprise
        }
        return UpdateFeed.github(repo: githubRepo)
    }

    /// Earlier releases showed as "QuickScribe Native" and kept their data in a
    /// folder named after that. DataMigration moves it on first launch.
    static let legacyDataFolderName = "QuickScribe Native"

    /// Both apps share the hotkey, so running them together would paste twice.
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
