import AppKit

// Drives the real Settings window against the running sidecar: edit, save, test,
// switch modes, reset. Exits non-zero on the first broken promise.
// Usage: settings-proof <folder for screenshots>

let shots = URL(fileURLWithPath: CommandLine.arguments[1])

@MainActor func spin(until done: () -> Bool, timeout: TimeInterval = 40) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    return done()
}

func views<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
    root.subviews.flatMap { views($0, type) + (($0 as? T).map { [$0] } ?? []) }
}

func polish(_ text: String, _ profile: String) -> String {
    var req = URLRequest(url: URL(string: "\(AppInfo.sidecarBase)/polish")!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try! JSONSerialization.data(withJSONObject: ["text": text, "profile": profile])
    let sema = DispatchSemaphore(value: 0)
    var out = ""
    URLSession.shared.dataTask(with: req) { data, _, _ in
        out = ((try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any])?["text"] as? String ?? ""
        sema.signal()
    }.resume()
    sema.wait()
    return out
}

/// This runs against the live sidecar, so a failed run must not leave its test prompt behind.
func restoreFactory() {
    var req = URLRequest(url: URL(string: "\(AppInfo.sidecarBase)/prompts/concise")!)
    req.httpMethod = "DELETE"
    let sema = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { _, _, _ in sema.signal() }.resume()
    sema.wait()
}

@MainActor func check(_ ok: Bool, _ what: String) {
    print((ok ? "ok   " : "FAIL ") + what)
    if !ok {
        restoreFactory()
        exit(1)
    }
}

@MainActor func snapshot(_ window: NSWindow, _ name: String) {
    let view = window.contentView!
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: shots.appendingPathComponent(name))
}

@MainActor func run() {
    NSApplication.shared.setActivationPolicy(.accessory)
    let settings = SettingsWindow()
    settings.show()
    let window = settings.window!
    let root = window.contentView!
    let picker = views(root, NSSegmentedControl.self)[0]
    let texts = views(root, NSTextView.self).sorted { $0.convert(NSPoint.zero, to: nil).y > $1.convert(NSPoint.zero, to: nil).y }
    let (editor, sample, output) = (texts[0], texts[1], texts[2])
    func button(_ title: String) -> NSButton { views(root, NSButton.self).first { $0.title == title }! }
    let status = views(root, NSTextField.self).first { !$0.isEditable && $0.stringValue.isEmpty || $0.stringValue.contains("tokens") }!
    func pick(_ i: Int) { picker.selectedSegment = i; _ = picker.sendAction(picker.action, to: picker.target) }
    func replace(_ text: String) {
        window.makeFirstResponder(editor)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    check(spin { editor.string.contains("publication-ready") }, "opens on the Polish factory prompt")
    check(status.stringValue.contains("Factory default"), "status says factory default: \(status.stringValue)")
    check(!button("Save").isEnabled && !button("Reset to Default").isEnabled, "nothing to save or reset yet")
    snapshot(window, "1-opened.png")

    pick(1)
    check(editor.string.contains("shortest version"), "Concise shows its own prompt")
    pick(2)
    check(editor.string.contains("active voice"), "Active Voice shows its own prompt")
    pick(1)

    let factory = editor.string
    replace("Reply with the dictated text in ALL CAPITAL LETTERS. Output only that text.")
    check(button("Save").isEnabled && status.stringValue.contains("Unsaved"), "typing enables Save")
    pick(0); pick(1)
    check(editor.string.hasPrefix("Reply with"), "unsaved typing survives switching modes")

    sample.string = "hello there my friend"
    button("Test Prompt").performClick(nil)
    check(spin { output.string == "HELLO THERE MY FRIEND" }, "sandbox runs the unsaved draft: \(output.string)")
    check(polish("hello there", "concise").uppercased() != polish("hello there", "concise"), "sandbox did not change real dictation")
    snapshot(window, "2-tested.png")

    button("Save").performClick(nil)
    check(spin { status.stringValue.contains("Saved") }, "Save confirms")
    check(polish("hello there my friend", "concise") == "HELLO THERE MY FRIEND", "very next dictation uses the saved prompt")

    replace(String(repeating: "x", count: 8001))
    check(!button("Save").isEnabled && status.textColor == .systemRed, "over the limit: Save off, count red")
    snapshot(window, "3-over-limit.png")
    replace("Reply with the dictated text in ALL CAPITAL LETTERS. Output only that text.")

    // A process started from a shell may never become the active app, so key
    // routing can't be driven here. Check the menu exists and the editor handles it.
    let edit = NSApp.mainMenu?.items.first?.submenu
    let wanted = ["x", "c", "v", "a"]
    check(wanted.allSatisfy { key in edit?.items.contains { $0.keyEquivalent == key && editor.responds(to: $0.action) } == true },
          "Edit menu offers cut, copy, paste and select all to the editor")

    button("Reset to Default").performClick(nil)
    check(spin { status.stringValue.contains("Restored") }, "Reset confirms")
    check(editor.string == factory, "Reset restores the factory text exactly")
    check(polish("HELLO THERE my friend, um, how are you", "concise") != "HELLO THERE MY FRIEND, HOW ARE YOU?", "after reset the capitals prompt is gone")
    print("PASS")
    exit(0)
}

MainActor.assumeIsolated { run() }
