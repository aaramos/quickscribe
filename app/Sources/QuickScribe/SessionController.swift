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
    /// How long the last utterance ran; feeds the Apple-route budget.
    var captureSeconds: Double = 0
    /// hotkey-release: TTI starts here (brief §Speed). Internal so tests can
    /// fix the release instant and watch who resets it.
    var releaseAt: Date?
    private var insertOnce = false              // guarantees insert happens exactly once
    private(set) var generation = 0             // invalidates in-flight work after cancel
    /// A one-line notice (a failed service, the length limit) that must stay
    /// readable after the words land. It becomes the final pill instead of
    /// being stamped over by "Inserted".
    /// A sentence the session may owe the person once the words land. Stems
    /// are short by rule: one pill line, no operating system error text. The
    /// tail depends on where the words actually went, so the sentence can
    /// never contradict the pill it replaces.
    enum SessionNotice: Equatable {
        /// Why a route changed or refused; nothing was lost.
        case reason(String)
        /// Custom speech failed and Apple's words carried the session.
        case speechFellBack
        /// Custom cleanup failed at the short reason, e.g. "Bad API key."
        case cleanupFailed(String)

        nonisolated func display(copied: Bool) -> String {
            switch self {
            case .reason(let why):
                return copied ? "\(why) Copied to clipboard." : why
            case .speechFellBack:
                return copied ? "Your speech service failed. Apple's words copied to the clipboard."
                              : "Your speech service failed. Used Apple's words."
            case .cleanupFailed(let why):
                return copied ? "\(why) Your words copied to the clipboard." : "\(why) Your words went in."
            }
        }
    }
    private var pendingNotice: SessionNotice?

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
    /// Custom cleanup's own deadline, flat at every clip length: a service may
    /// be loading a model or answering from across the room, and Apple's
    /// per-length budget was tuned for a model that is always warm on device.
    static var serviceCleanupTimeout: TimeInterval = 6.0

    /// Overrides the cleaner both routes, so tests see the choice around it.
    var cleaner: (any Cleaning)?
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
    /// The pill is free only when nothing is on it. Any state, dictation or
    /// not, means someone may be reading it: a permission warning carries
    /// no hide timer and must never be replaced and hidden under their
    /// eyes. Outside notices wait for a genuinely empty pill.
    var pillIsFree: Bool { overlay.state == .hidden }

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
        // A fresh session starts with no notice carried over.
        pendingNotice = nil
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
        if overflowed { return .appleOnly("Over the 5-minute limit. Apple speech answered.") }
        if silent { return .appleOnly("") }                       // nothing to hear; never upload silence
        if !hasClip { return .appleOnly("The clip came out empty. Apple speech answered.") }
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
            pendingNotice = why.isEmpty ? nil : .reason(why)
            speechTask = Task { [weak self] in
                guard let self else { return }
                defer { if self.generation == gen { self.speechTask = nil } }   // never drop a newer session's task
                do {
                    let raw = try await live.finish()   // wind-down started at release; this only waits
                    guard self.generation == gen else { return }
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
                    // The notice goes last, so it stays readable, and the
                    // failed upload does not spend the cleanup budget.
                    self.pendingNotice = .speechFellBack
                    self.releaseAt = self.clock()
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
        pendingNotice = nil           // a cancelled session tells no tales
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
            // A notice set for this session (the length limit) explains the
            // emptiness better than a generic line, so it wins here too.
            if modePickedThisSession {
                pendingNotice = nil
                announceProfile()
            } else if let why = pendingNotice {
                pendingNotice = nil
                pill(.error(why.display(copied: false)), autoHideAfter: 3.5)
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

    /// Whose model cleans this dictation. Custom cleanup only counts with an
    /// address set, same rule as speech.
    nonisolated static func cleanupRoute(settings: EndpointSettings) -> CleanupRoute {
        settings.cleanupUsesEndpoint ? .service : .apple
    }

    private func polishAndInsert(raw: String) {
        let gen = generation
        let prof = profile
        let settings = endpointStore.load()
        let route = Self.cleanupRoute(settings: settings)
        let spent = releaseAt.map { clock().timeIntervalSince($0) } ?? 0
        // Apple's model only gates Apple's route. A service route always
        // asks: its own failures fall back below, budgeted the same way.
        let modelReady = route == .service || (appleModelReadyOverride ?? (AppleCleaner.unavailableReason() == nil))
        let step = PolishPlanner.firstStep(raw: raw, tidied: TextCleanup.tidy(raw),
                                           modelReady: modelReady,
                                           budget: AppInfo.ttiBudget(utteranceSeconds: captureSeconds),
                                           spent: spent,
                                           serviceTimeout: route == .service ? Self.serviceCleanupTimeout : nil)
        guard case .askModel(let timeout, let tidied) = step else {
            carryOut(step)
            return
        }
        // The person's own prompt applies to both routes; the factory texts
        // differ: Apple's short tuned set, or the longer sidecar set.
        let instructions = prompts.prompt(prof, route: route)
        let cleaner = cleaner ?? activeCleaner(settings: settings, route: route)
        Task { [weak self] in
            let result: Result<String, Error>
            do {
                result = .success(try await withDeadline(timeout) {
                    try await cleaner.clean(tidied, instructions: instructions)
                })
            } catch {
                result = .failure(error)
            }
            guard let self, self.generation == gen else { return }
            switch result {
            case .success(let output):
                let step = PolishPlanner.stepAfterModel(output: output, tidied: tidied, mode: prof)
                if case .insert(_, cleaned: false) = step, PolishPlanner.usable(output),
                   let refusal = CleanupGuard.refusal(output: output, input: tidied, mode: prof) {
                    // The guard stamped a real answer, and a silent skip reads
                    // as though nothing happened. Say which rule, briefly.
                    self.pendingNotice = .cleanupFailed(Self.guardRefusalWhy(refusal))
                }
                self.carryOut(step)
            case .failure(let failure):
                if route == .service {
                    // Never a lost word, but the person learns why the line
                    // landed unpolished.
                    self.pendingNotice = .cleanupFailed(Self.cleanupFailureWhy(failure))
                }
                self.carryOut(PolishPlanner.stepAfterModel(output: nil, tidied: tidied, mode: prof))
            }
        }
    }

    /// The route's own cleaner. The Keychain is read here and only for the
    /// service route: an Apple cleanup never touches it.
    private func activeCleaner(settings: EndpointSettings, route: CleanupRoute) -> any Cleaning {
        guard route == .service else { return appleCleaner }
        return EndpointCleaner(client: OpenAICompatClient(settings: settings,
                                                          apiKey: endpointStore.apiKey(), timeout: 120),
                               model: settings.cleanupModel)
    }

    /// Short stems, each one true of its rule: they share the cleanupFailed
    /// tails, so "Your words went in." or the clipboard line follows them.
    nonisolated static func guardRefusalWhy(_ refusal: CleanupGuard.Refusal) -> String {
        switch refusal {
        case .changedNumbers: return "Cleanup changed a number."
        case .addedMoney: return "Cleanup added money."
        case .addedTimeOfDay: return "Cleanup added a time of day."
        case .answeredTheQuestion: return "Cleanup dropped the question."
        case .emptied: return "Cleanup gave nothing."
        case .droppedTooMuch, .grewTooMuch, .rewordedTooMuch: return "Cleanup changed the wording."
        case .addedASentence: return "Cleanup added words."
        case .addedAName: return "Cleanup added a name."
        }
    }

    /// The short reason half of a cleanup notice. Deliberately NOT
    /// EndpointError.message: those carry detail (and the OS's own words)
    /// that belongs in Settings, not on a one-line pill.
    nonisolated static func cleanupFailureWhy(_ error: Error) -> String {
        if error is DeadlinePassed { return "Cleanup timed out." }
        if let e = error as? EndpointError {
            switch e {
            case .noAddress: return "No service address set."
            case .badAddress: return "Bad service address."
            case .notReached: return "Can't reach the service."
            case .unauthorized: return "Bad API key."
            case .notFound: return "Wrong service path."
            case .serverError(let code): return "Service error \(code)."
            case .timedOut: return "The service took too long."
            case .invalidReply: return "Bad reply from the service."
            case .emptyReply: return "The service answered nothing."
            case .truncated: return "The answer was cut off."
            }
        }
        return "Cleanup failed."
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
                // The notice, if this session earned one, is the message the
                // person needs: it shows AFTER the words are in, and stays
                // up long enough to read.
                if let why = self.pendingNotice {
                    self.pendingNotice = nil
                    self.pill(.error(why.display(copied: false)), autoHideAfter: 3.0)
                } else {
                    self.pill(degraded ? .degraded : .inserted, autoHideAfter: 1.4)
                }
                if lostImages {
                    NSLog("QuickScribe: clipboard image could not be restored (accepted edge case)")
                }
            } else {
                self.pendingNotice = nil   // a failed insert has its own, more urgent news
                self.pill(.error("Insert failed. Check Accessibility permission."), autoHideAfter: 2.5)
            }
        }
    }

    private func showClipboardResult(_ ok: Bool) {
        if let why = pendingNotice {
            pendingNotice = nil
            // The notice stays readable, and the person still learns the
            // words landed on the clipboard rather than in the document.
            pill(.error(ok ? why.display(copied: true) : "Couldn't copy to the clipboard."),
                 autoHideAfter: 3.0)
        } else {
            pill(ok ? .copied : .error("Couldn't copy to the clipboard."), autoHideAfter: 2.0)
        }
    }

    // Expose overlay + hotkey start to the app delegate.
    /// Returns true only if the event tap is live — the delegate must NOT
    /// pretend hotkeys work otherwise.
    @discardableResult
    func activate() -> Bool { hotkeys.start() }
    func showOverlay(_ s: OverlayController.State, autoHide: TimeInterval? = nil) { overlay.show(s, autoHideAfter: autoHide) }
}