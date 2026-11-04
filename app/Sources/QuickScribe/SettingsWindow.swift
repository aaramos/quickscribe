import AppKit

/// One-screen Settings: the editable "Refine Prompts" for each mode, plus a
/// sandbox that runs the text on screen without saving it.
@MainActor
final class SettingsWindow: NSObject, NSTextViewDelegate {
    private static let sampleDictation =
        "um so basically the report was written by Sarah and uh we should meet at 2, actually 3, to go over it"

    private(set) var window: NSWindow?
    private var drafts = PromptDrafts()
    private var maxTokens = 2000
    private var modeID = RefineMode.all[0].id

    private let modePicker = NSSegmentedControl(labels: RefineMode.all.map(\.title),
                                                trackingMode: .selectOne, target: nil, action: nil)
    private let editor = SettingsWindow.makeTextView()
    private let status = NSTextField(labelWithString: "")
    private let resetButton = NSButton(title: "Reset to Default", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let sampleInput = SettingsWindow.makeTextView()
    private let testButton = NSButton(title: "Test Prompt", target: nil, action: nil)
    private let testOutput = SettingsWindow.makeTextView()

    func show() {
        if window == nil { window = buildWindow() }
        installEditMenu()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        reload()
    }

    // MARK: - Loading and display

    private func reload() {
        SidecarClient.shared.listPrompts { [weak self] list in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let list = list else {
                    self.status.stringValue = "Sidecar is down, so prompts can't be loaded."
                    self.setEditing(false)
                    return
                }
                self.drafts.load(list.modes)
                self.maxTokens = list.max_tokens
                self.setEditing(true)
                self.showCurrentMode()
            }
        }
    }

    private func setEditing(_ on: Bool) {
        editor.isEditable = on
        testButton.isEnabled = on
        modePicker.isEnabled = on
        if !on {
            saveButton.isEnabled = false
            resetButton.isEnabled = false
        }
    }

    private func showCurrentMode() {
        editor.string = drafts.text(modeID)
        refreshStatus()
    }

    private func refreshStatus(message: String? = nil) {
        guard let entry = drafts.entry(modeID) else { return }
        let tokens = PromptDrafts.estimateTokens(editor.string)
        let dirty = drafts.isDirty(modeID)
        let state = dirty ? "Unsaved changes" : (entry.custom ? "Your prompt" : "Factory default")
        status.stringValue = "\(message ?? state)  ·  about \(tokens) of \(maxTokens) tokens"
        status.textColor = tokens > maxTokens ? .systemRed : .secondaryLabelColor
        saveButton.isEnabled = dirty && tokens <= maxTokens
        resetButton.isEnabled = entry.custom || dirty
    }

    // MARK: - Actions

    @objc private func modeChanged() {
        modeID = RefineMode.all[modePicker.selectedSegment].id
        showCurrentMode()
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === editor else { return }
        drafts.edit(modeID, text: editor.string)
        refreshStatus()
    }

    @objc private func saveTapped() {
        let target = modeID
        SidecarClient.shared.savePrompt(mode: target, text: drafts.text(target)) { [weak self] saved, problem in
            DispatchQueue.main.async {
                self?.finishChange(target, saved: saved, problem: problem, success: "Saved. The next dictation uses it.")
            }
        }
    }

    @objc private func resetTapped() {
        let target = modeID
        SidecarClient.shared.resetPrompt(mode: target) { [weak self] saved, problem in
            DispatchQueue.main.async {
                self?.finishChange(target, saved: saved, problem: problem, success: "Restored the factory prompt.")
            }
        }
    }

    private func finishChange(_ target: String, saved: SidecarClient.PromptEntry?,
                              problem: String?, success: String) {
        guard let saved = saved else {
            refreshStatus(message: problem ?? "Couldn't reach the sidecar. Nothing changed.")
            return
        }
        drafts.commit(saved)
        if target == modeID {
            showCurrentMode()
            refreshStatus(message: success)
        }
    }

    @objc private func testTapped() {
        testButton.isEnabled = false
        testOutput.string = "Running…"
        SidecarClient.shared.testPrompt(text: sampleInput.string, prompt: editor.string) { [weak self] output, degraded, problem in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.testButton.isEnabled = true
                if let output = output, !degraded {
                    self.testOutput.string = output
                } else if degraded {
                    self.testOutput.string = "The model didn't answer, so a dictation would insert the raw text."
                } else {
                    self.testOutput.string = problem ?? "Couldn't reach the sidecar."
                }
            }
        }
    }

    // MARK: - Layout

    /// A menu-bar app has no main menu, and text fields only get ⌘C, ⌘V, ⌘A and
    /// ⌘Z from one. It stays out of sight because the app has no menu bar.
    private func installEditMenu() {
        guard NSApp.mainMenu == nil else { return }
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let holder = NSMenuItem()
        holder.submenu = edit
        let main = NSMenu()
        main.addItem(holder)
        NSApp.mainMenu = main
    }

    private static func makeTextView() -> NSTextView {
        let view = NSTextView()
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.textContainerInset = NSSize(width: 4, height: 4)
        return view
    }

    private func scrolling(_ view: NSTextView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private func buildWindow() -> NSWindow {
        modePicker.target = self
        modePicker.action = #selector(modeChanged)
        modePicker.selectedSegment = RefineMode.all.firstIndex { $0.id == modeID } ?? 0
        editor.delegate = self
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command
        resetButton.target = self
        resetButton.action = #selector(resetTapped)
        testButton.target = self
        testButton.action = #selector(testTapped)
        sampleInput.string = Self.sampleDictation
        testOutput.isEditable = false
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let buttons = NSStackView(views: [status, NSView(), resetButton, saveButton])
        let stack = NSStackView(views: [
            heading("Refine Prompts"),
            modePicker,
            scrolling(editor, height: 250),
            buttons,
            heading("Try it on sample dictation (uses the text above, without saving)"),
            scrolling(sampleInput, height: 60),
            testButton,
            scrolling(testOutput, height: 90),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in stack.arrangedSubviews where view is NSScrollView || view === buttons {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "\(AppInfo.displayName) Settings"
        win.isReleasedWhenClosed = false
        win.contentView = stack
        win.center()
        return win
    }
}
