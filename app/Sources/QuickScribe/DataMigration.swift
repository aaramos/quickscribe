import Foundation

/// One-time carry-over of settings from the old "QuickScribe Native" data folder
/// to the folder named after the current display name.
///
/// Rules: move the old folder only when the new one does not exist yet. If both
/// exist, keep the new one and leave the old one alone — never delete or
/// overwrite anything, so custom prompts can not be lost either way.
enum DataMigration {
    /// What happened, for logging and tests.
    enum Outcome: Equatable {
        case moved
        case nothingToMove        // old folder absent
        case newFolderExists      // both present: keep the new one, old untouched
        case failed               // move refused; both folders left exactly as they were
    }

    static func migrate(oldFolder: URL, newFolder: URL, fm: FileManager = .default) -> Outcome {
        guard fm.fileExists(atPath: oldFolder.path) else { return .nothingToMove }
        guard !fm.fileExists(atPath: newFolder.path) else { return .newFolderExists }
        do {
            try fm.createDirectory(at: newFolder.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: oldFolder, to: newFolder)
            return .moved
        } catch {
            // Leave both folders exactly as they were; the app still runs, it
            // just starts from default prompts rather than risk any loss.
            NSLog("QuickScribe: could not move the old data folder — keeping both")
            return .failed
        }
    }

    /// Runs against the real folders, once, at launch before anything reads them.
    @discardableResult
    static func runAtLaunch() -> Outcome {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let outcome = migrate(oldFolder: appSupport.appendingPathComponent(AppInfo.legacyDataFolderName, isDirectory: true),
                              newFolder: AppInfo.dataFolder)
        switch outcome {
        case .moved:          NSLog("QuickScribe: moved settings from the old data folder")
        case .nothingToMove:  break  // silent for the common fresh-install case
        case .newFolderExists: NSLog("QuickScribe: kept the current data folder; left the old one untouched")
        case .failed:         break  // migrate() already logged why
        }
        return outcome
    }
}
