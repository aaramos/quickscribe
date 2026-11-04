import AppKit

/// The capture-session state machine. Owns the full lifecycle per brief:
/// hold ⌃⌘ → record (+streaming partials) → release → tail → final STT →
/// polish (PolishPlanner: timeout ≤ remaining budget; degraded OR blank result
/// → retry once, only while budget remains → raw; exhausted budget = no request) →
/// insert exactly once → history. Any key press or Esc cancels, sidecar-down
/// never crashes. (Owner UX change 2026-09-18: hold-only keyboard gesture;
/// hands-free toggle lives in the menu bar.)
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

    // Live partial transcription state.
    private var partialText: String = ""       // committed partials (concatenated verbatim)
    private var partialInFlight = false
    /// Coalesce by CONCATENATION, never by replacement: chunks are
    /// non-overlapping audio, so a replaced pending chunk used to silently
    /// lose its words whenever the sidecar fell behind real time.
    private var pendingChunks: [Data] = []
    private var chunkFails = 0
    private var captureSeconds: Double = 0
    private var sessionStart = Date()
    private var releaseAt: Date?           // hotkey-release: TTI starts here (brief §Speed)
    private var insertOnce = false              // guarantees insert happens exactly once
    private var generation = 0                  // invalidates in-flight work after cancel
    private var lastPartialRaw = ""            // repeat suppression: identical decoded partial >=2x = hallucination (t_b3e7802c)
    private var repeatSuppressed = false
    private var lastInsertedText = ""         // back-to-back identical insert suppression

    /// Menu bar needs to know when sessions start/end (icon state, menu disable).
    var onPhaseChange: ((Bool) -> Void)?

    init() {
        hotkeys.onIntent = { [weak self] intent in
            Task { @MainActor in self?.handle(intent: intent) }
        }
        overlay.onEscape = { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
        capture.onChunk = { [weak self] wav, secs, _ in
            DispatchQueue.main.async { self?.streamChunk(wav: wav, secs: secs) }
        }
        // LEVEL TAP → WF1 ticker (t_3db202e7). Read-only; chunk pipeline
        // untouched.
        capture.onLevel = { [weak self] lvl in
            self?.overlay.pushLevel(lvl)
        }
        // Device hot-plug / default-change (t_eec52a7e): re-resolve AND drop
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
        // Fresh generation invalidates any stragglers from a prior session.
        generation += 1
        forcedRewrite = rewrite
        modePickedThisSession = false
        partialText = ""
        partialInFlight = false
        pendingChunks.removeAll()
        chunkFails = 0
        insertOnce = false
        lastPartialRaw = ""
        repeatSuppressed = false
        sessionStart = Date()

        do {
            try capture.start()
        } catch let e as AudioCapture.CaptureError {
            // Honest failure surface: no real mic vs permission/engine problem.
            let msg = e.why.contains("no microphone")
                ? "No microphone detected"
                : "Mic unavailable — check Microphone permission"
            overlay.show(.error(msg), autoHideAfter: 2.5)
            NSLog("QuickScribe: capture start failed: \(e.why)")
            return
        } catch {
            overlay.show(.error("Mic unavailable — check Microphone permission"), autoHideAfter: 2.5)
            return
        }
        mode = .pushToTalk
        overlay.resetWave()
        overlay.show(.recording(device: capture.activeDevice?.name))   // same runloop tick as hotkey → <100ms (brief)
        onPhaseChange?(true)
    }

    private func finish() {
        guard mode != .idle else { return }
        mode = .idle
        releaseAt = Date()
        captureSeconds = capture.stop()   // removes tap first; buffered PCM survives
        capture.flushTail()               // emits the still-buffered tail as final chunk
        overlay.show(.processing)
        onPhaseChange?(false)
        // Deferred so the tail chunk's sendChunk (queued during flushTail,
        // which blocks main inside flushQueue.sync → onChunk → main.async)
        // registers as in-flight BEFORE we resolve.
        DispatchQueue.main.async { [weak self] in self?.resolveFinalText() }
    }

    func cancel() {
        guard mode != .idle || overlay.state == .processing else { return }
        generation += 1               // drop in-flight transcribe/polish results
        mode = .idle
        captureSeconds = capture.stop()   // removes tap first
        insertOnce = true            // a late finish must not insert anymore
        overlay.show(.cancelled, autoHideAfter: 1.2)
        onPhaseChange?(false)
    }

    // MARK: - Streaming

    private func streamChunk(wav: Data, secs: Double) {
        // Always forward — includes the tail flushed after release (runbook:
        // only the tail is transcribed post-release). Overlay updates are
        // gated on recording state below.
        sendChunk(wav: wav, partial: true)
    }

    private func sendChunk(wav: Data, partial: Bool) {
        if partialInFlight {
            // Buffer instead of replacing — dropping audio drops words.
            pendingChunks.append(wav)
            return
        }
        partialInFlight = true
        let gen = generation
        SidecarClient.shared.transcribe(wav: wav, partial: partial) { [weak self] text, _ in
            DispatchQueue.main.async {
                guard let self = self, self.generation == gen else { return }
                self.partialInFlight = false
                let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    // Repeat suppression (t_b3e7802c): Whisper on silent/near-
                    // silent audio emits the SAME polite phrase every chunk.
                    // An identical decoded partial twice in a row is a
                    // hallucination — drop it and every further repeat.
                    if trimmed.caseInsensitiveCompare(self.lastPartialRaw) == .orderedSame {
                        self.repeatSuppressed = true
                        NSLog("QuickScribe: repeat partial '\(trimmed)' suppressed (hallucination guard)")
                    } else {
                        self.lastPartialRaw = trimmed
                        self.repeatSuppressed = false
                        self.partialText = self.join(self.partialText, trimmed)
                        if self.mode != .idle {
                            self.overlay.show(.partial(self.partialText, device: self.capture.activeDevice?.name))
                        }
                    }
                } else if text == nil {
                    // Only a failed REQUEST counts as a chunk failure; an empty
                    // success (silence tail) is normal — t_955de3e6.
                    self.chunkFails += 1
                }
                if !self.pendingChunks.isEmpty {
                    let merged = self.takePendingChunks()
                    self.sendChunk(wav: merged, partial: self.mode != .idle)
                }
            }
        }
    }

    /// Merge the buffered chunks into one WAV: PCM payloads concatenated
    /// (all chunks come from WavWriter — fixed-size header), one fresh header.
    private func takePendingChunks() -> Data {
        let list = pendingChunks
        pendingChunks.removeAll()
        guard list.count > 1 else { return list.first ?? Data() }
        var pcm = Data()
        for w in list { pcm.append(w.dropFirst(WavWriter.headerSize)) }
        return WavWriter.wav(int16LE: pcm, sampleRate: 16000)
    }

    /// After release: raw = concatenated partials (chunks were streamed live,
    /// including the tail flushed in finish()). If any chunk failed, log it and
    /// proceed with what we have; fully-empty → insert nothing (brief §7).
    /// (No full-audio re-transcribe exists: audio is streamed and discarded
    /// chunk by chunk, so recovery is "assemble from partials" or nothing.)
    private func resolveFinalText() {
        let gen = generation
        if partialInFlight {
            // Wait for the in-flight straggler; pending chunks are dispatched
            // by its completion handler.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self, self.generation == gen else { return }
                self.resolveFinalText()
            }
            return
        }
        if !pendingChunks.isEmpty {
            sendChunk(wav: takePendingChunks(), partial: false)
            return
        }
        var raw = partialText
        if chunkFails > 0 || raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Sidecar hiccup during streaming → one full re-transcribe attempt.
            raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // We no longer hold full audio (streamed incrementally). If a chunk
            // failed AND no partial arrived, insert nothing (brief §7: empty → nothing).
            if raw.isEmpty {
                if modePickedThisSession {
                    announceProfile()
                    return
                }
                // Honest silence path (t_b3e7802c): if EVERY chunk that left the
                // app was below the RMS floor (or nothing was emitted at all),
                // the mic heard nothing — say so, name the device, insert nothing.
                if capture.sessionWasFullySilent || capture.silentChunks + capture.voicedChunks == 0 {
                    let dev = capture.activeDevice.map { " (device: \($0.name))" } ?? ""
                    overlay.show(.error("Couldn't hear you — check your mic\(dev)"), autoHideAfter: 3.0)
                } else if repeatSuppressed && partialText.isEmpty {
                    overlay.show(.error("Couldn't hear you — check your mic"), autoHideAfter: 3.0)
                } else if chunkFails > 0 {
                    // Audio reached the service but transcribe requests FAILED
                    // (500/timeout/refused) — the honest cause is the STT
                    // service, not the mic. (2026-11-03: unmounted cache
                    // volume 500'd every chunk and the user got the
                    // misleading "Nothing captured".)
                    overlay.show(.error("Transcription unavailable — check the sidecar"), autoHideAfter: 3.0)
                    NSLog("QuickScribe: \(chunkFails) transcribe request(s) failed; no text assembled")
                } else {
                    overlay.show(.error("Nothing captured"), autoHideAfter: 1.5)
                }
                return
            }
            // Partial data exists despite a failed chunk — proceed with what we have,
            // logged as degraded capture.
            NSLog("QuickScribe: \(chunkFails) stream chunk(s) failed; assembling from \(raw.count) chars of partials")
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

    // MARK: - Polish + insert

    private func polishAndInsert(raw: String) {
        let gen = generation
        let prof = profile
        let t0 = Date()
        // Honest STT metric: wall time hotkey-release → raw text ready
        // (tail decode). The old value summed EVERY chunk's decode ms,
        // double-counting work that overlapped the recording itself.
        let msStt = releaseAt.map { Int(t0.timeIntervalSince($0) * 1000) } ?? 0
        // TTI budget counts from hotkey-RELEASE (releaseAt set in finish());
        // polish may only use what the bucket leaves after tail STT (PM note 2:
        // late polish must not stretch insertion beyond brief §8). Exhausted
        // budget means NO request — insert raw, degraded (t_a0fb24bb).
        let budget = AppInfo.ttiBudget(utteranceSeconds: captureSeconds)
        let spent = releaseAt.map { t0.timeIntervalSince($0) } ?? 0
        runPolish(PolishPlanner.firstStep(budget: budget, spent: spent), raw: raw, prof: prof,
                  gen: gen, budget: budget, t0: t0, msStt: msStt, attempt: 1)
    }

    /// Executes one planner decision. All policy — timeout ≤ remaining budget,
    /// degraded-or-blank → retry once (only while time remains) → raw, and
    /// stale-callback rejection — is owned by PolishPlanner and unit-tested
    /// there; this is async plumbing only (t_a0fb24bb). Exactly-once insertion
    /// remains enforced by `insertOnce` inside insertText.
    private func runPolish(_ step: PolishPlanner.Step, raw: String, prof: String, gen: Int,
                           budget: Double, t0: Date, msStt: Int, attempt: Int) {
        switch step {
        case .stale:
            break   // session cancelled / new generation — insertOnce stands
        case .insertRaw:
            insertText(raw, raw: raw, profile: prof, degraded: true, polishStarted: t0, msStt: msStt)
        case .insertPolished(let text):
            insertText(text, raw: raw, profile: prof, degraded: false, polishStarted: t0, msStt: msStt)
        case .request(let timeout):
            SidecarClient.shared.polish(text: raw, profile: prof, timeout: timeout) { [weak self] polished, degraded in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    let spent = self.releaseAt.map { Date().timeIntervalSince($0) } ?? 0
                    let next = PolishPlanner.stepAfterResult(budget: budget, spent: spent, attempt: attempt,
                                                             stale: self.generation != gen,
                                                             polished: polished, degraded: degraded)
                    self.runPolish(next, raw: raw, prof: prof, gen: gen, budget: budget,
                                   t0: t0, msStt: msStt, attempt: attempt + 1)
                }
            }
        }
    }

    private func insertText(_ text: String, raw: String, profile prof: String,
                            degraded: Bool, polishStarted: Date, msStt: Int) {
        guard !insertOnce else { return }   // exactly-once guarantee
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            // Only reachable when the RAW text itself is blank — resolveFinalText
            // never sends an empty raw down, and a blank polish result now falls
            // back to raw upstream. Don't blame the mic for the polish step.
            overlay.show(.error("Nothing usable to insert"), autoHideAfter: 2.0)
            return
        }
        // Back-to-back identical insert suppression (t_b3e7802c): the same
        // text twice in a row means the same hallucination survived the
        // partial gate — refuse the second insert, never the first.
        if trimmedText.caseInsensitiveCompare(lastInsertedText) == .orderedSame {
            overlay.show(.error("Duplicate text suppressed"), autoHideAfter: 2.0)
            NSLog("QuickScribe: identical repeat insert suppressed: '\(trimmedText)'")
            return
        }
        Insertion.insert(text) { [weak self] ok, lostImages in
            guard let self = self else { return }
            self.insertOnce = true
            if ok { self.lastInsertedText = trimmedText }
            let msPolish = Int(Date().timeIntervalSince(polishStarted) * 1000)
            if ok {
                self.overlay.show(degraded ? .degraded : .inserted, autoHideAfter: 1.4)
                if lostImages {
                    NSLog("QuickScribe: clipboard image could not be restored (v1 accepted edge case)")
                }
                SidecarClient.shared.capture(raw: raw, polished: text, profile: prof,
                                             msStt: msStt, msPolish: msPolish)
            } else {
                self.overlay.show(.error("Insert failed — Accessibility permission?"), autoHideAfter: 2.5)
            }
        }
    }

    private func join(_ a: String, _ b: String) -> String {
        let t = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return t }
        if t.isEmpty { return a }
        return a + " " + t
    }

    // Expose overlay + hotkey start to the app delegate.
    /// Returns true only if the event tap is live — the delegate must NOT
    /// pretend hotkeys work otherwise (dead-listener defect, t_49e2302f).
    @discardableResult
    func activate() -> Bool { hotkeys.start() }
    func showOverlay(_ s: OverlayController.State, autoHide: TimeInterval? = nil) { overlay.show(s, autoHideAfter: autoHide) }
}
