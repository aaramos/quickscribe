import AppKit

// Menu-bar-only native dictation app (brief: native Swift, LSUIElement).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
