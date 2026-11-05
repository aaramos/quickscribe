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
    private let endpointStore: EndpointSettingsStore
    private let appleCleaner = AppleCleaner()
    /// The live recognizer for this session. start() installs the real one;
    /// tests attach a stub here so cancel() reaches it.
    var transcription: (any SpeechAccepting)?
    /// The whole recording, and it exists only when speech points at a
    /// service: an Apple-speech session must not pay for an audio copy, a
    /// conversion and a WAV it will never send. Rebuilt every session so
    /// buffers from a discarded one can never leak into the next.
    private(set) var recording: RecordingBuffer?
    private var speechTask: Task<Void, Never>?
    private var captureSeconds: Double = 0
    /// hotkey-release: TTI starts here (brief §Speed). Internal so tests can
    /// fix the release instant and watch who resets it.
    var releaseAt: Date?
    private var insertOnce = false              // guarantees insert happens exactly once
    private(set) var generation = 0             // invalidates in-flight work after cancel
    // MARK: - Test seams
    // The paths below reach the keyboard, the clipboard, Apple's model and
    // the clock, so every one of those sits behind a replaceable seam. The
    // defaults are exactly the production behavior.
    var clock: () -> Date = { Date() }
    private(set) var pillLog: [OverlayController.State] = []
    var targetReader: () -> InsertionTarget = { InsertionTarget.current() }
    var textInserter: (String, @escaping (Bool, Bool) -> Void) -> Void = { Insertion.insert($0, completion: $1) }
    var copyWriter: (String) -> Bool = { Insertion.copy($0) }
    var pasteKept: (String) -> Bool = { Insertion.pasteAndKeep($0) }
    var cleaner: any Cleaning = AppleCleaner()
    var appleModelReadyOverride: Bool?
    /// Overrides the "the mic heard nothing all session" reading, which is
    /// always true while no real capture ever ran (tests drive releases).
    var silentSessionOverride: Bool?

    /// Menu bar needs to know when sessions start/end (icon state, menu disable).
    var onPhaseChange: ((Bool) -> Void)?

    init(prompts: PromptLibrary, endpointStore: EndpointSettingsStore) {
        self.prompts = prompts
        self.endpointStore = endpointStore
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
        appleCleaner.prewarm()
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
        pill(.modeChanged(RefineMode.title(forProfile: defaultProfile)), autoHideAfter: 1.5)
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
            pill(.error("Quit the original QuickScribe first, or both would paste."), autoHideAfter: 3.0)
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
        // Only a session whose speech route is the service keeps the whole
        // recording; Apple speech needs nothing beyond the live recognizer.
        armRecording()
        let whole = recording
        capture.onBuffer = { buffer in
            live.append(buffer)
            whole?.append(buffer)
        }

        do {
            try capture.start()
        } catch let e as AudioCapture.CaptureError {
            // Honest failure surface: no real mic vs permission/engine problem.
            let msg = e.why.contains("no microphone")
                ? "No microphone detected"
                : "Mic unavailable. Check Microphone permission."
            pill(.error(msg), autoHideAfter: 2.5)
            NSLog("QuickScribe: capture start failed: \(e.why)")
            abandonTranscription()
            return
        } catch {
            pill(.error("Mic unavailable. Check Microphone permission."), autoHideAfter: 2.5)
            abandonTranscription()
            return
        }
        mode = .pushToTalk
        overlay.resetLevels()
        pill(.recording(mode: RefineMode.title(forProfile: profile)))   // same tick as the hotkey, so it feels instant
        onPhaseChange?(true)
    }

    /// start()'s buffer decision, split out so tests can watch both routes
    /// without a microphone.
    func armRecording() {
        recording = endpointStore.load().speechUsesEndpoint ? RecordingBuffer() : nil
    }

    /// What the whole recording gets used for. Kept pure so the rules the
    /// card sets down are testable without a microphone.
    enum SpeechRoute: Equatable {
        case customService      // send the whole clip; its text becomes the result
        case appleOnly(String)  // why custom was refused, "" for the plain default
    }

    static func speechRoute(customChosen: Bool, overflowed: Bool, silent: Bool,
                            hasClip: Bool) -> SpeechRoute {
        guard customChosen else { return .appleOnly("") }
        if overflowed { return .appleOnly("Recording passed the 5-minute service limit. This one used Apple speech.") }
        if silent { return .appleOnly("") }                       // nothing to hear; never upload silence
        if !hasClip { return .appleOnly("The recording came out empty, so Apple speech answered.") }
        return .customService
    }

    private func finish() {
        guard mode != .idle else { return }
        mode = .idle
        releaseAt = clock()
        captureSeconds = capture.stop()
        capture.onBuffer = nil
        pill(.processing)
        onPhaseChange?(false)
        guard let live = transcription else { return }
        // transcription is deliberately kept: pressing Esc while the result
        // lands must still close Apple's session; cancel() does that through
        // abandonTranscription. The next start() replaces the object anyway.
        processRelease(customChosen: recording != nil,
                       silent: capture.sessionWasFullySilent,
                       live: live)
    }

    /// Everything release does with the words: who answers, in what order,
    /// and when the cleanup budget starts. No hardware in here, so tests
    /// drive it directly with a stub recognizer and a fake service.
    func processRelease(customChosen: Bool, silent: Bool, live: any SpeechAccepting) {
        let gen = generation
        let clip = recording?.wav()       // waits for every buffer already in flight
        recording?.discard()              // discard, not clear: a late buffer must not grow it back
        recording = nil
        let settings = endpointStore.load()
        let route = Self.speechRoute(customChosen: customChosen,
                                     overflowed: clip?.overflowed ?? false,
                                     silent: silent,
                                     hasClip: (clip?.data.count ?? 0) > 44)
        if case .appleOnly(let why) = route {
            speechTask = Task { [weak self] in
                guard let self else { return }
                defer { if self.generation == gen { self.speechTask = nil } }   // never drop a newer session's task
                do {
                    let raw = try await live.finish()   // wind-down started at release; this only waits
                    guard self.generation == gen else { return }
                    if !why.isEmpty {
                        self.pill(.error(why), autoHideAfter: 3.5)
                    }
                    self.resolveFinalText(raw, generation: gen)
                } catch {
                    guard self.generation == gen else { return }
                    self.transcriptionFailed(error, generation: gen)
                }
            }
            return
        }
        guard let bytes = clip?.data else { return }
        // Apple's session starts winding down here, beside the upload: a good
        // service reply never waits on it, and if it hangs, it still does not.
        let windDown = Task { () -> String? in try? await live.finish() }
        speechTask = Task { [weak self] in
            guard let self else { return }
                defer { if self.generation == gen { self.speechTask = nil } }   // never drop a newer session's task
            do {
                // The key is read from the Keychain only for the route that
                // actually sends anything.
                let endpoint = OpenAICompatClient(settings: settings, apiKey: self.endpointStore.apiKey(), timeout: 120)
                let raw = try await endpoint.transcribe(wav: bytes, model: settings.speechModel)
                let words = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if words.isEmpty { throw EndpointError.emptyReply }   // blank is no words
                guard self.generation == gen, !Task.isCancelled else { return }
                // Cleanup's budget starts when the words are in hand. The
                // upload got its own 120 s; it spends none of this one.
                self.releaseAt = self.clock()
                self.resolveFinalText(words, generation: gen)
            } catch {
                guard self.generation == gen, !Task.isCancelled else { return }
                NSLog("QuickScribe: custom speech failed: \(error.localizedDescription)")
                // The fallback needs Apple's words, but a stuck Apple session
                // must not hang a dictation that already lost once.
                let fallback: String? = ((try? await withDeadline(Self.appleFallbackGrace) { await windDown.value }) ?? nil)
                // withDeadline abandons, never waits for, a stuck recognizer:
                // a dictation that already lost once must not hang as well.
                guard self.generation == gen else { return }
                let words = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if words.isEmpty {
                    self.pill(.error("Your speech service failed, and Apple speech gave no words either."),
                              autoHideAfter: 3.5)
                } else {
                    self.pill(.error("Your speech service failed. Used Apple's words."), autoHideAfter: 3.0)
                    self.releaseAt = self.clock()   // the failed upload spends none of it
                    self.resolveFinalText(fallback ?? "", generation: gen)
                }
            }
        }
    }

    /// How long the service-failure fallback waits on Apple's session before
    /// giving up on it. A stuck recognizer must not stack onto a stuck service.
    static var appleFallbackGrace: TimeInterval = 5.0

    func cancel() {
        guard mode != .idle || overlay.state == .processing else { return }
        generation += 1               // drop in-flight transcription and cleanup results
        mode = .idle
        captureSeconds = capture.stop()
        capture.onBuffer = nil
        abandonTranscription()
        speechTask?.cancel()          // stop the upload outright
        speechTask = nil
        recording?.discard()          // and free the audio
        insertOnce = true             // a late finish must not insert anymore
        pill(.cancelled, autoHideAfter: 1.2)
        onPhaseChange?(false)
    }

    private func abandonTranscription() {
        transcription?.cancel()
        transcription = nil
    }

    // MARK: - Transcript

    /// Every pill state goes through here: it shows and remembers, so tests
    /// can check the ORDER states appeared in, not just the last one.
    private func pill(_ state: OverlayController.State, autoHideAfter: TimeInterval? = nil) {
        pillLog.append(state)
        overlay.show(state, autoHideAfter: autoHideAfter)
    }

    private func showWords(_ words: String, generation gen: Int) {
        guard generation == gen, mode != .idle, !words.isEmpty else { return }
        pill(.recording(mode: RefineMode.title(forProfile: profile), words: words))
    }

    private func transcriptionFailed(_ error: Error, generation gen: Int) {
        guard generation == gen else { return }
        NSLog("QuickScribe: transcription failed: \(error.localizedDescription)")
        pill(.error("Apple speech recognition isn't available right now."), autoHideAfter: 3.0)
    }

    private func resolveFinalText(_ transcript: String, generation gen: Int) {
        guard generation == gen else { return }
        var raw = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // A mic that never rose above the floor heard nothing, so anything the
        // recognizer made of that noise must not be inserted.
        let heardNothing = silentSessionOverride ?? capture.sessionWasFullySilent
        if heardNothing || raw.isEmpty {
            if modePickedThisSession {
                announceProfile()
            } else if heardNothing {
                let device = capture.activeDevice.map { " (device: \($0.name))" } ?? ""
                pill(.error("Couldn't hear you. Check your mic\(device)."), autoHideAfter: 3.0)
            } else {
                pill(.error("Nothing captured"), autoHideAfter: 1.5)
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
        let spent = releaseAt.map { clock().timeIntervalSince($0) } ?? 0
        let step = PolishPlanner.firstStep(raw: raw, tidied: TextCleanup.tidy(raw),
                                           modelReady: appleModelReadyOverride ?? (AppleCleaner.unavailableReason() == nil),
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
            pill(.error("Nothing usable to insert"), autoHideAfter: 2.0)
            return
        }
        switch targetReader() {
        case .textField: break
        case .notText:
            showClipboardResult(copyWriter(text))
            return
        case .unsure:
            showClipboardResult(pasteKept(text))
            return
        }
        textInserter(text) { [weak self] ok, lostImages in
            guard let self else { return }
            if ok {
                self.pill(degraded ? .degraded : .inserted, autoHideAfter: 1.4)
                if lostImages {
                    NSLog("QuickScribe: clipboard image could not be restored (accepted edge case)")
                }
            } else {
                self.pill(.error("Insert failed. Check Accessibility permission."), autoHideAfter: 2.5)
            }
        }
    }

    private func showClipboardResult(_ ok: Bool) {
        pill(ok ? .copied : .error("Couldn't copy to the clipboard."), autoHideAfter: 2.0)
    }

    // Expose overlay + hotkey start to the app delegate.
    /// Returns true only if the event tap is live — the delegate must NOT
    /// pretend hotkeys work otherwise.
    @discardableResult
    func activate() -> Bool { hotkeys.start() }
    func showOverlay(_ s: OverlayController.State, autoHide: TimeInterval? = nil) { overlay.show(s, autoHideAfter: autoHide) }
}

/// Apple's on-device cleanup model behind a seam, so tests can see whether
/// cleanup was asked at all and what it made of the budget.
protocol Cleaning: Sendable {
    func clean(_ text: String, instructions: String) async throws -> String
}

extension AppleCleaner: Cleaning {}
