import AppKit
import QuickScribeCore

/// The capture-session state machine: hold ⌃⌘, record while Apple's recognizer
/// listens, release, tidy with rules, clean with Apple's model within the time budget,
/// insert exactly once. Any key press or Esc cancels. Whatever the
/// model does, the person's words get inserted.
@MainActor
final class SessionController {
    enum Mode { case idle, pushToTalk, toggled }

    private(set) var mode: Mode = .idle
    /// ⌃⌘⇧ hold: Rewrite for this session only (brief §4).
    private var forcedRewrite = false
    var profile: String { forcedRewrite ? RefineMode.rewriteProfile : defaultProfile }
    /// The chosen default profile, kept across launches. Read when polish
    /// starts, so a mode picked mid-dictation applies to that dictation.
    private(set) var defaultProfile = RefineMode.savedProfile()
    /// A mode was picked during this capture, so an empty result is not a failure.
    private var modePickedThisSession = false
    var onProfileChange: (() -> Void)?

    private let capture = AudioCapture()
    private let overlay = OverlayController()
    let hotkeys = HotkeyManager()

    private let prompts: PromptLibrary
    private let cleaner = AppleCleaner()
    private var transcription: LiveTranscription?
    private var captureSeconds: Double = 0
    private var releaseAt: Date?           // hotkey-release: TTI starts here (brief §Speed)
    private var insertOnce = false              // guarantees insert happens exactly once
    private var generation = 0                  // invalidates in-flight work after cancel

    /// Menu bar needs to know when sessions start/end (icon state, menu disable).
    var onPhaseChange: ((Bool) -> Void)?

    init(prompts: PromptLibrary) {
        self.prompts = prompts
        hotkeys.onIntent = { [weak self] intent in
            Task { @MainActor in self?.handle(intent: intent) }
        }
        overlay.onEscape = { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
        // LEVEL TAP → WF1 ticker. Read-only; chunk pipeline
        // untouched.
        capture.onLevel = { [weak self] lvl in
            self?.overlay.pushLevel(lvl)
        }
        // Device hot-plug / default-change: re-resolve AND drop
        // the engine instance the OS pinned to the old device — re-resolving
        // alone is pointless while a stale engine survives (that was the
        // "new mic ignored until relaunch" defect). Idle-only: mid-capture
        // the bind/restore pair keeps the running session stable.
        InputDeviceResolver.registerChangeCallback { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                if let d = InputDeviceResolver.resolve() {
                    NSLog("QuickScribe: input devices changed — next capture will use '\(d.name)'")
                } else {
                    NSLog("QuickScribe: input devices changed — NO real input device available")
                }
                self.capture.invalidateEngine()
            }
        }
    }

    var isRecording: Bool { mode != .idle }

    /// Gets both Apple models ready so the first dictation isn't the slow one. A
    /// missing speech model downloads through the OS here.
    func prepare() {
        cleaner.prewarm()
        Task.detached {
            do {
                try await AppleSpeechSession.ensureInstalled()
                try await AppleSpeechSession.prewarm()
            } catch {
                NSLog("QuickScribe: speech model not ready: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Hotkey intent FSM (hold-only; see HotkeyManager)

    private func handle(intent: HotkeyManager.Intent) {
        switch intent {
        case .start(let rewrite):
            guard mode == .idle else { return } // toggled session: keyboard stays out of it
            start(rewrite: rewrite)
        case .stop(let rewrite):
            // Only a push-to-talk session ends on modifier release.
            guard mode == .pushToTalk else { return }
            _ = rewrite
            finish()
        case .cancel:
            // Key pressed mid-capture → cancel, nothing inserted. In toggled
            // (hands-free) mode ordinary typing must NOT kill the session.
            guard mode == .pushToTalk else { return }
            cancel()
        case .selectMode(let index):
            guard RefineMode.all.indices.contains(index) else { return }
            selectProfile(RefineMode.all[index].id)
        }
    }

    /// Every way of picking a mode ends here: menu, shortcut, voice.
    func selectProfile(_ profile: String) {
        defaultProfile = profile
        forcedRewrite = false
        RefineMode.saveProfile(profile)
        onProfileChange?()
        if mode == .idle {
            announceProfile()
        } else {
            modePickedThisSession = true
        }
    }

    private func announceProfile() {
        overlay.show(.modeChanged(RefineMode.title(forProfile: defaultProfile)), autoHideAfter: 1.5)
    }

    /// Menu-bar hands-free toggle: "Start/Stop Recording (hands-free)".
    func toggleHandsFree() {
        switch mode {
        case .idle:
            start(rewrite: defaultProfile == "rewrite")
            // start() failed (mic denied) → mode stays .idle; don't lie.
            if mode == .pushToTalk { mode = .toggled }
        case .pushToTalk, .toggled:
            finish()
        }
    }

    // MARK: - Session lifecycle

    private func start(rewrite: Bool) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: AppInfo.originalBundleID).isEmpty else {
            overlay.show(.error("Quit the original QuickScribe first, or both would paste."), autoHideAfter: 3.0)
            return
        }
        // Fresh generation invalidates any stragglers from a prior session.
        generation += 1
        forcedRewrite = rewrite
        modePickedThisSession = false
        insertOnce = false
        let gen = generation
        let live = LiveTranscription { [weak self] words in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.showWords(words, generation: gen) }
            }
        }
        transcription = live
        capture.onBuffer = { live.append($0) }

        do {
            try capture.start()
        } catch let e as AudioCapture.CaptureError {
            // Honest failure surface: no real mic vs permission/engine problem.
            let msg = e.why.contains("no microphone")
                ? "No microphone detected"
                : "Mic unavailable. Check Microphone permission."
            overlay.show(.error(msg), autoHideAfter: 2.5)
            NSLog("QuickScribe: capture start failed: \(e.why)")
            abandonTranscription()
            return
        } catch {
            overlay.show(.error("Mic unavailable. Check Microphone permission."), autoHideAfter: 2.5)
            abandonTranscription()
            return
        }
        mode = .pushToTalk
        overlay.resetLevels()
        overlay.show(.recording(mode: RefineMode.title(forProfile: profile)))   // same tick as the hotkey, so it feels instant
        onPhaseChange?(true)
    }

    private func finish() {
        guard mode != .idle else { return }
        mode = .idle
        releaseAt = Date()
        captureSeconds = capture.stop()
        capture.onBuffer = nil
        overlay.show(.processing)
        onPhaseChange?(false)
        let gen = generation
        guard let live = transcription else { return }
        transcription = nil
        Task { [weak self] in
            do {
                let raw = try await live.finish()
                self?.resolveFinalText(raw, generation: gen)
            } catch {
                self?.transcriptionFailed(error, generation: gen)
            }
        }
    }

    func cancel() {
        guard mode != .idle || overlay.state == .processing else { return }
        generation += 1               // drop in-flight transcription and cleanup results
        mode = .idle
        captureSeconds = capture.stop()
        capture.onBuffer = nil
        abandonTranscription()
        insertOnce = true             // a late finish must not insert anymore
        overlay.show(.cancelled, autoHideAfter: 1.2)
        onPhaseChange?(false)
    }

    private func abandonTranscription() {
        transcription?.cancel()
        transcription = nil
    }

    // MARK: - Transcript

    private func showWords(_ words: String, generation gen: Int) {
        guard generation == gen, mode != .idle, !words.isEmpty else { return }
        overlay.show(.recording(mode: RefineMode.title(forProfile: profile), words: words))
    }

    private func transcriptionFailed(_ error: Error, generation gen: Int) {
        guard generation == gen else { return }
        NSLog("QuickScribe: transcription failed: \(error.localizedDescription)")
        overlay.show(.error("Apple speech recognition isn't available right now."), autoHideAfter: 3.0)
    }

    private func resolveFinalText(_ transcript: String, generation gen: Int) {
        guard generation == gen else { return }
        var raw = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // A mic that never rose above the floor heard nothing, so anything the
        // recognizer made of that noise must not be inserted.
        if capture.sessionWasFullySilent || raw.isEmpty {
            if modePickedThisSession {
                announceProfile()
            } else if capture.sessionWasFullySilent {
                let device = capture.activeDevice.map { " (device: \($0.name))" } ?? ""
                overlay.show(.error("Couldn't hear you. Check your mic\(device)."), autoHideAfter: 3.0)
            } else {
                overlay.show(.error("Nothing captured"), autoHideAfter: 1.5)
            }
            return
        }
        if let command = VoiceModeCommand.parse(raw) {
            selectProfile(command.modeID)
            guard !command.remainder.isEmpty else {
                announceProfile()
                return
            }
            raw = command.remainder
        }
        polishAndInsert(raw: raw)
    }

    // MARK: - Cleanup + insert

    private func polishAndInsert(raw: String) {
        let gen = generation
        let prof = profile
        let spent = releaseAt.map { Date().timeIntervalSince($0) } ?? 0
        let step = PolishPlanner.firstStep(raw: raw, tidied: TextCleanup.tidy(raw),
                                           modelReady: AppleCleaner.unavailableReason() == nil,
                                           budget: AppInfo.ttiBudget(utteranceSeconds: captureSeconds),
                                           spent: spent)
        guard case .askModel(let timeout, let tidied) = step else {
            carryOut(step)
            return
        }
        let instructions = prompts.prompt(prof)
        let cleaner = cleaner
        Task { [weak self] in
            let output = try? await withDeadline(timeout) {
                try await cleaner.clean(tidied, instructions: instructions)
            }
            guard let self, self.generation == gen else { return }
            self.carryOut(PolishPlanner.stepAfterModel(output: output, tidied: tidied, mode: prof))
        }
    }

    private func carryOut(_ step: PolishPlanner.Step) {
        guard case .insert(let text, let cleaned) = step else { return }
        insertText(text, degraded: !cleaned)
    }

    private func insertText(_ text: String, degraded: Bool) {
        guard !insertOnce else { return }   // exactly-once guarantee
        insertOnce = true
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            overlay.show(.error("Nothing usable to insert"), autoHideAfter: 2.0)
            return
        }
        switch InsertionTarget.current() {
        case .textField: break
        case .notText:
            showClipboardResult(Insertion.copy(text))
            return
        case .unsure:
            showClipboardResult(Insertion.pasteAndKeep(text))
            return
        }
        Insertion.insert(text) { [weak self] ok, lostImages in
            guard let self else { return }
            if ok {
                self.overlay.show(degraded ? .degraded : .inserted, autoHideAfter: 1.4)
                if lostImages {
                    NSLog("QuickScribe: clipboard image could not be restored (accepted edge case)")
                }
            } else {
                self.overlay.show(.error("Insert failed. Check Accessibility permission."), autoHideAfter: 2.5)
            }
        }
    }

    private func showClipboardResult(_ ok: Bool) {
        overlay.show(ok ? .copied : .error("Couldn't copy to the clipboard."), autoHideAfter: 2.0)
    }

    // Expose overlay + hotkey start to the app delegate.
    /// Returns true only if the event tap is live — the delegate must NOT
    /// pretend hotkeys work otherwise.
    @discardableResult
    func activate() -> Bool { hotkeys.start() }
    func showOverlay(_ s: OverlayController.State, autoHide: TimeInterval? = nil) { overlay.show(s, autoHideAfter: autoHide) }
}
