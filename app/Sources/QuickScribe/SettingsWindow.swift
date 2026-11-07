import AppKit
import QuickScribeCore

/// One-screen Settings: the custom service connection, the editable "Refine
/// Prompts" for each mode, and a sandbox that runs the text on screen without
/// saving it.
@MainActor
final class SettingsWindow: NSObject, NSTextViewDelegate, NSTextFieldDelegate {
    private static let sampleDictation =
        "um so basically the report was written by Sarah and uh we should meet at 2, actually 3, to go over it"

    private(set) var window: NSWindow?
    private let library: PromptLibrary
    let endpointStore: EndpointSettingsStore
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

    // Inference server controls. Model choice lives in the menu bar, not here.
    let addressField = NSTextField(string: "")
    let keyField = NSSecureTextField(string: "")
    let wordsOutLabel = NSTextField(wrappingLabelWithString: "")
    let connectionTestButton = NSButton(title: "Test Connection", target: nil, action: nil)
    let connectionStatus = NSTextField(wrappingLabelWithString: "")
    /// Told after the address or the key changes, so the menu's model lists can
    /// be refreshed and a stale one dropped. (whether the address changed, whether the key changed)
    var onConnectionChanged: ((Bool, Bool) -> Void)?

    init(library: PromptLibrary, endpointStore: EndpointSettingsStore) {
        self.library = library
        self.endpointStore = endpointStore
        super.init()
    }

    /// A choice made in the menu bar changes which routes send words out, so an
    /// open Settings page refreshes what that changes: the words-out warning,
    /// and the prompt editor, which shows the factory of the route cleanup now
    /// uses. It deliberately does NOT touch the address or key fields (typed but
    /// uncommitted text must survive) and never reads the key: a menu choice is
    /// no reason to open the Keychain.
    func connectionChangedOutside() {
        guard window != nil else { return }
        refreshWordsOutWarning()
        showCurrentMode()
    }

    func show() {
        if window == nil { window = buildWindow() }
        installEditMenu()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        reload()
        reloadConnection()
    }

    // MARK: - Loading and display

    private func reload() {
        drafts.load(library.entries())
        showCurrentMode()
    }

    private var cleanupRoute: CleanupRoute {
        endpointStore.load().cleanupUsesEndpoint ? .service : .apple
    }

    func showCurrentMode() {
        // While a mode is factory text, the editor shows the factory of the
        // route that cleanup actually uses: Apple's short Polish is not the
        // starting point for a service, and saving either factory stays
        // factory. A custom prompt is the person's own on both routes.
        if drafts.isDirty(modeID) {
            editor.string = drafts.text(modeID)
        } else if let entry = drafts.entry(modeID), entry.custom {
            editor.string = entry.prompt
        } else {
            editor.string = library.prompt(modeID, route: cleanupRoute)
        }
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

    /// Seam for tests: (route, sample, instructions, settings, key) → the model's reply.
    var promptTester: ((CleanupRoute, String, String, EndpointSettings, String?) async throws -> String)?

    @objc private func testTapped() {
        testButton.isEnabled = false
        testOutput.string = "Running…"
        let sample = TextCleanup.tidy(sampleInput.string)
        let settings = endpointStore.load()
        let route = settings.cleanupUsesEndpoint ? CleanupRoute.service : CleanupRoute.apple
        // The test runs the same prompt the NEXT dictation would use: the
        // draft if edited, a saved custom prompt, else the factory text of
        // the route that is actually selected.
        let entry = drafts.entry(modeID)
        let instructions = (drafts.isDirty(modeID) || entry?.custom == true)
            ? editor.string : library.prompt(modeID, route: route)
        Task { [weak self] in
            guard let self else { return }
            let message: String
            do {
                try PromptLibrary.validate(instructions)
                let run = self.promptTester ?? Self.runPromptTest
                // The Keychain is opened only for the route that sends it a key.
                let key = route == .service ? self.endpointStore.apiKey() : nil
                message = try await run(route, sample, instructions, settings, key)
            } catch let failure as CleanupFailure {
                message = Self.explain(failure)
            } catch let failure as EndpointError {
                message = failure.message
            } catch {
                message = (error as? TestProblem)?.message ?? error.localizedDescription
            }
            self.testOutput.string = message
            self.testButton.isEnabled = true
        }
    }

    /// One cleanup on the route that is selected, through the same code a
    /// dictation would take: Apple's model, or the service with its address,
    /// key and cleanup model name.
    static func runPromptTest(_ route: CleanupRoute, _ sample: String, _ instructions: String,
                              _ settings: EndpointSettings, _ key: String?) async throws -> String {
        switch route {
        case .apple:
            if let reason = AppleCleaner.unavailableReason() { throw TestProblem(message: reason) }
            return try await AppleCleaner().clean(sample, instructions: instructions)
        case .service:
            let client = OpenAICompatClient(settings: settings, apiKey: key, timeout: 120)
            return try await client.clean(text: sample, model: settings.cleanupModel, systemPrompt: instructions)
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

        // Inference server wiring: typed fields commit on focus loss or Enter.
        addressField.placeholderString = "http://192.168.1.20:1234/v1"
        keyField.placeholderString = "Only if your service needs one"
        for field in [addressField, keyField] as [NSTextField] {
            field.delegate = self
            field.target = self
            field.action = #selector(connectionFieldEndedEditing(_:))
        }
        connectionTestButton.target = self
        connectionTestButton.action = #selector(testConnectionTapped)
        connectionStatus.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        connectionStatus.textColor = .secondaryLabelColor
        connectionStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wordsOutLabel.isHidden = true
        wordsOutLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        func row(_ label: String, _ control: NSView) -> NSStackView {
            let text = NSTextField(labelWithString: label)
            text.alignment = .right
            text.setContentHuggingPriority(.required, for: .horizontal)
            text.widthAnchor.constraint(equalToConstant: 110).isActive = true
            control.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let line = NSStackView(views: [text, control])
            line.orientation = .horizontal
            line.spacing = 8
            line.widthAnchor.constraint(equalToConstant: 608).isActive = true
            return line
        }
        let connectionRow = NSStackView(views: [connectionTestButton, connectionStatus])
        connectionRow.orientation = .horizontal
        connectionRow.spacing = 10
        connectionRow.widthAnchor.constraint(equalToConstant: 608).isActive = true

        let serviceStack = NSStackView(views: [
            heading("Inference server"),
            noteLabel("Leave the address empty to use Apple Native only. Choose your models from the menu bar icon."),
            row("Address", addressField),
            row("API key", keyField),
            wordsOutLabel,
            connectionRow,
        ])
        serviceStack.orientation = .vertical
        serviceStack.alignment = .leading
        serviceStack.spacing = 6
        for field in [addressField, keyField] {
            field.widthAnchor.constraint(equalToConstant: 470).isActive = true
        }
        for wide in [wordsOutLabel, connectionRow] {
            wide.widthAnchor.constraint(equalToConstant: 608).isActive = true
        }

        let buttons = NSStackView(views: [status, NSView(), resetButton, saveButton])
        // Top-aligned inside the window's scroller: the report can grow and
        // the window still fits a small screen.
        let stack = FlippedStackView(views: [
            serviceStack,
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

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true
        stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor).isActive = true
        stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        // The page is never shorter than the viewport and never clipped:
        // these two let the scroller derive the content size from the layout.
        stack.bottomAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.bottomAnchor).isActive = true
        let fill = stack.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor)
        fill.priority = .defaultLow
        fill.isActive = true

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 800),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "\(AppInfo.displayName) Settings"
        win.isReleasedWhenClosed = false
        win.contentView = scroll
        // Fit a 13-inch MacBook Air at its default 1440x900 (visible height
        // about 800 points) even when the Test Connection report is full: the
        // window stays put and the page scrolls inside it.
        win.layoutIfNeeded()
        let needed = stack.fittingSize.height
        let screenCap = (win.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        win.setContentSize(NSSize(width: 640, height: min(max(needed, 360), min(680, screenCap - 60))))
        win.center()
        return win
    }

    /// Draws its row list from the top, the way a page does.
    private final class FlippedStackView: NSStackView {
        override var isFlipped: Bool { true }
    }

    private func noteLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 608).isActive = true
        return label
    }
}
