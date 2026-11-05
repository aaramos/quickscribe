import AppKit

// Menu-bar-only native dictation app (brief: native Swift, LSUIElement).
MainActor.assumeIsolated {
    // Carry settings across from the old data folder BEFORE anything reads it.
    DataMigration.runAtLaunch()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
