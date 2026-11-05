import AppKit
import QuickScribeCore

/// One-screen Settings: the custom service connection, the editable "Refine
/// Prompts" for each mode, and a sandbox that runs the text on screen without
/// saving it.
@MainActor
final class SettingsWindow: NSObject, NSTextViewDelegate, NSComboBoxDelegate {   // NSComboBoxDelegate inherits NSTextFieldDelegate
    private static let sampleDictation =
        "um so basically the report was written by Sarah and uh we should meet at 2, actually 3, to go over it"

    private(set) var window: NSWindow?
    private let library: PromptLibrary
    private let endpointStore: EndpointSettingsStore
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

    // Custom service controls.
    private let addressField = NSTextField(string: "")
    private let keyField = NSSecureTextField(string: "")
    private let speechChoice = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cleanupChoice = NSPopUpButton(frame: .zero, pullsDown: false)
    private let speechModelField = NSComboBox()
    private let cleanupModelField = NSComboBox()
    private let wordsOutLabel = NSTextField(wrappingLabelWithString: "")
    private let connectionTestButton = NSButton(title: "Test Connection", target: nil, action: nil)
    private let connectionStatus = NSTextField(wrappingLabelWithString: "")
    /// Bumped per address change so a late model list cannot overwrite a newer one.
    private var modelsFetchGeneration = 0

    init(library: PromptLibrary, endpointStore: EndpointSettingsStore) {
        self.library = library
        self.endpointStore = endpointStore
        super.init()
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

    // MARK: - Custom service

    private func reloadConnection() {
        let s = endpointStore.load()
        addressField.stringValue = s.address
        keyField.stringValue = endpointStore.apiKey() ?? ""
        speechChoice.selectItem(at: s.useCustomSpeech ? 1 : 0)
        cleanupChoice.selectItem(at: s.useCustomCleanup ? 1 : 0)
        speechModelField.stringValue = s.speechModel
        cleanupModelField.stringValue = s.cleanupModel
        refreshWordsOutWarning()
        if s.isEnabled { fetchModels() }
    }

    /// Reads every control back into a settings value. The person's typed model
    /// names survive whatever the list fetch does.
    private func collectConnection() -> EndpointSettings {
        EndpointSettings(address: addressField.stringValue,
                         speechModel: speechModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                         cleanupModel: cleanupModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                         useCustomSpeech: speechChoice.indexOfSelectedItem == 1,
                         useCustomCleanup: cleanupChoice.indexOfSelectedItem == 1)
    }

    private func connectionChanged(saveKey: Bool = false) {
        let s = collectConnection()
        endpointStore.save(s)
        if saveKey {
            do {
                try endpointStore.setAPIKey(keyField.stringValue)
            } catch {
                connectionStatus.stringValue = error.localizedDescription
            }
        }
        refreshWordsOutWarning()
        if s.isEnabled { fetchModels() } else { connectionStatus.stringValue = "" }
    }

    /// When words will leave the Mac for a non-local address, the screen says so.
    private func refreshWordsOutWarning() {
        let s = collectConnection()
        if let problem = s.addressProblem {
            wordsOutLabel.stringValue = problem
            wordsOutLabel.textColor = .systemRed
            wordsOutLabel.isHidden = false
        } else if s.speechUsesEndpoint || s.cleanupUsesEndpoint, !EndpointSettings.isLocal(host: s.hostName) {
            // Only a route actually set to Custom moves words. Plain http to
            // a remote address never reaches here: the check above refuses it.
            wordsOutLabel.stringValue = "Your words will leave this Mac and travel to \(s.hostName)."
            wordsOutLabel.textColor = .secondaryLabelColor
            wordsOutLabel.isHidden = false
        } else {
            wordsOutLabel.isHidden = true
        }
    }

    /// Fills the model pickers from GET /models. Services that do not list
    /// models are fine: the fields stay typed by hand.
    private func fetchModels() {
        modelsFetchGeneration += 1
        let generation = modelsFetchGeneration
        let s = collectConnection()
        let client = OpenAICompatClient(settings: s, apiKey: endpointStore.apiKey(), timeout: 8)
        Task { [weak self] in
            let models = await client.listModels()
            guard let self, generation == self.modelsFetchGeneration, !models.isEmpty else { return }
            self.fill(speechModelField, with: models)
            self.fill(self.cleanupModelField, with: models)
        }
    }

    private func fill(_ box: NSComboBox, with models: [String]) {
        let typed = box.stringValue
        box.removeAllItems()
        box.addItems(withObjectValues: models)
        box.stringValue = typed
    }

    // MARK: - Connection actions

    @objc private func connectionFieldEndedEditing(_ sender: NSTextField) {
        connectionChanged(saveKey: sender === keyField)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField,
           field === addressField || field === keyField || field === speechModelField || field === cleanupModelField {
            connectionFieldEndedEditing(field)
        }
    }

    @objc private func connectionChoiceChanged() {
        connectionChanged()
    }

    @objc private func testConnectionTapped() {
        connectionTestButton.isEnabled = false
        connectionStatus.stringValue = "Testing…"
        let s = collectConnection()
        // A pasted key often carries spaces or line breaks; the service wants
        // exactly what it handed out.
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        connectionChanged(saveKey: true)
        Task { [weak self] in
            let report = await Self.runConnectionTest(settings: s, apiKey: key)
            self?.connectionStatus.stringValue = report
            self?.connectionTestButton.isEnabled = true
        }
    }

    /// Reports plainly: reached the address, key accepted, speech works,
    /// cleanup works. Each line stands on its own. Internal for tests.
    static func runConnectionTest(settings: EndpointSettings, apiKey: String) async -> String {
        var lines: [String] = []
        if let problem = settings.addressProblem {
            return problem
        }
        guard settings.isEnabled else {
            return "No address set, so everything runs on Apple's own models on this Mac."
        }
        // A server may load the model on its first call; the original app
        // allowed 120 s for that, so this must not read a slow load as failure.
        let client = OpenAICompatClient(settings: settings, apiKey: apiKey, timeout: 120)
        var reached = false, keyOK = false
        switch await client.checkModels() {
        case .success(let models):
            reached = true
            keyOK = true
            lines.append(models.isEmpty
                ? "Reached the address, but it does not list models. You can still type the names."
                : "Reached the address. It has \(models.count) model\(models.count == 1 ? "" : "s").")
        case .failure(let error):
            if case .unauthorized = error {
                reached = true
                lines.append("Reached the address.")
                lines.append("The service refused the key (401). Check the API key.")
            } else {
                lines.append(error.message)
            }
        }
        guard reached else { return lines.joined(separator: "\n") }
        if keyOK { lines.append("Key accepted.") }
        if !keyOK { return lines.joined(separator: "\n") }
        if settings.useCustomSpeech {
            if settings.speechModel.isEmpty {
                lines.append("Speech: no model name typed yet.")
            } else {
                do {
                    _ = try await client.transcribe(wav: silenceWAV(), model: settings.speechModel)
                    lines.append("Speech works.")
                } catch {
                    lines.append("Speech: \((error as? EndpointError)?.message ?? error.localizedDescription)")
                }
            }
        } else {
            lines.append("Speech: Apple's on-device model is chosen, not the service.")
        }
        if settings.useCustomCleanup {
            if settings.cleanupModel.isEmpty {
                lines.append("Cleanup: no model name typed yet.")
            } else {
                do {
                    _ = try await client.clean(text: "The connection test is a plain sentence.",
                                               model: settings.cleanupModel,
                                               systemPrompt: "Repeat the sentence back exactly.")
                    lines.append("Cleanup works.")
                } catch {
                    lines.append("Cleanup: \((error as? EndpointError)?.message ?? error.localizedDescription)")
                }
            }
        } else {
            lines.append("Cleanup: Apple's on-device model is chosen, not the service.")
        }
        return lines.joined(separator: "\n")
    }

    /// A short silence as 16 kHz mono 16-bit PCM in a WAV container. Test
    /// Connection uses it instead of recorded words.
    nonisolated static func silenceWAV(seconds: Double = 0.3, sampleRate: Int = 16_000) -> Data {
        let samples = Int(seconds * Double(sampleRate))
        let pcmLength = samples * 2
        var data = Data()
        func ascii(_ s: String) { data.append(Data(s.utf8)) }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(36 + pcmLength); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        ascii("data"); u32(pcmLength)
        data.append(Data(count: pcmLength))
        return data
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

        // Custom service wiring: typed fields commit on focus loss or Enter,
        // the two choices on click.
        addressField.placeholderString = "http://192.168.1.20:1234/v1"
        keyField.placeholderString = "Only if your service needs one"
        for field in [addressField, keyField] as [NSTextField] {
            field.delegate = self
            field.target = self
            field.action = #selector(connectionFieldEndedEditing(_:))
        }
        for box in [speechModelField, cleanupModelField] {
            box.isEditable = true
            box.completes = false
            box.placeholderString = "Type a name, or pick from the list"
            box.delegate = self
            box.target = self
            box.action = #selector(connectionFieldEndedEditing(_:))
        }
        speechChoice.addItems(withTitles: ["Apple (on this Mac)", "Custom service"])
        cleanupChoice.addItems(withTitles: ["Apple (on this Mac)", "Custom service"])
        speechChoice.target = self
        speechChoice.action = #selector(connectionChoiceChanged)
        cleanupChoice.target = self
        cleanupChoice.action = #selector(connectionChoiceChanged)
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
            heading("Custom service"),
            noteLabel("Blank by default. With no address everything runs on Apple's on-device models, on this Mac."),
            row("Address", addressField),
            row("API key", keyField),
            row("Speech", speechChoice),
            row("Speech model", speechModelField),
            row("Cleanup", cleanupChoice),
            row("Cleanup model", cleanupModelField),
            wordsOutLabel,
            connectionRow,
        ])
        serviceStack.orientation = .vertical
        serviceStack.alignment = .leading
        serviceStack.spacing = 6
        for field in [addressField, keyField, speechModelField, cleanupModelField] {
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
