import AppKit
import QuickScribeCore

/// One-screen Settings: the editable "Refine Prompts" for each mode, plus a
/// sandbox that runs the text on screen without saving it.
@MainActor
final class SettingsWindow: NSObject, NSTextViewDelegate {
    private static let sampleDictation =
        "um so basically the report was written by Sarah and uh we should meet at 2, actually 3, to go over it"

    private(set) var window: NSWindow?
    private let library: PromptLibrary
    private let cleaner = AppleCleaner()
    private var drafts = PromptDrafts()
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

    init(library: PromptLibrary) {
        self.library = library
        super.init()
    }

    func show() {
        if window == nil { window = buildWindow() }
        installEditMenu()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        reload()
    }

    // MARK: - Loading and display

    private func reload() {
        drafts.load(library.entries())
        showCurrentMode()
    }

    private func showCurrentMode() {
        editor.string = drafts.text(modeID)
        refreshStatus()
    }

    private func refreshStatus(message: String? = nil) {
        guard let entry = drafts.entry(modeID) else { return }
        let tokens = PromptLibrary.estimateTokens(editor.string)
        let dirty = drafts.isDirty(modeID)
        let state = dirty ? "Unsaved changes" : (entry.custom ? "Your prompt" : "Factory default")
        status.stringValue = "\(message ?? state)  ·  about \(tokens) of \(PromptLibrary.maxTokens) tokens"
        status.textColor = tokens > PromptLibrary.maxTokens ? .systemRed : .secondaryLabelColor
        saveButton.isEnabled = dirty && tokens <= PromptLibrary.maxTokens
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
        change(success: "Saved. The next dictation uses it.") { try library.save(modeID, text: drafts.text(modeID)) }
    }

    @objc private func resetTapped() {
        change(success: "Restored the factory prompt.") { try library.reset(modeID) }
    }

    private func change(success: String, _ action: () throws -> PromptEntry) {
        do {
            drafts.commit(try action())
            showCurrentMode()
            refreshStatus(message: success)
        } catch {
            refreshStatus(message: "\(error.localizedDescription) Nothing changed.")
        }
    }

    @objc private func testTapped() {
        testButton.isEnabled = false
        testOutput.string = "Running…"
        let sample = TextCleanup.tidy(sampleInput.string)
        let prompt = editor.string
        let cleaner = cleaner
        Task { [weak self] in
            let message: String
            do {
                try PromptLibrary.validate(prompt)
                if let reason = AppleCleaner.unavailableReason() { throw TestProblem(message: reason) }
                message = try await cleaner.clean(sample, instructions: prompt)
            } catch let failure as CleanupFailure {
                message = Self.explain(failure)
            } catch {
                message = (error as? TestProblem)?.message ?? error.localizedDescription
            }
            self?.testOutput.string = message
            self?.testButton.isEnabled = true
        }
    }

    private struct TestProblem: Error { let message: String }

    private static func explain(_ failure: CleanupFailure) -> String {
        switch failure {
        case .refused: return "Apple's model declined this text, so a dictation would insert it with fillers removed."
        case .tooLong: return "This prompt plus the sample is too long for Apple's model."
        case .blank: return "The model returned nothing, so a dictation would insert the text with fillers removed."
        default: return "The model didn't answer, so a dictation would insert the text with fillers removed."
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
