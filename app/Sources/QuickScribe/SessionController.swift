import AppKit

/// The capture-session state machine. Owns the full lifecycle per brief:
/// hold ⌃⌘ → record (+streaming partials) → release → tail → final STT →
/// polish (bounded by TTI budget, PM: degraded→retry once→raw) →
/// insert exactly once → history. Any key press or Esc cancels, sidecar-down
/// never crashes. (Owner UX change 2026-09-18: hold-only keyboard gesture;
/// hands-free toggle lives in the menu bar.)
@MainActor
final class SessionController {
    enum Mode { case idle, pushToTalk, toggled }

    private(set) var mode: Mode = .idle
    private var rewriteProfile = false
    var profile: String { rewriteProfile ? "rewrite" : "polish" }
    /// Menu-selected default profile ("polish" | "rewrite"); the
    /// ⌃⌘⇧ hold overrides per-session (brief §4).
    var defaultProfile = "polish"

    private let capture = AudioCapture()
    private let overlay = OverlayController()
    let hotkeys = HotkeyManager()

    // Live partial transcription state.
    private var partialText: String = ""       // committed partials (concatenated verbatim)
    private var partialInFlight = false
    private var pendingChunk: (Data, Double)?  // coalesce: only newest matters while one is in flight
    private var finalText: String?              // tail result (or full re-transcribe fallback)
    private var chunkFails = 0
    private var captureSeconds: Double = 0
    private var sessionStart = Date()
    private var releaseAt: Date?           // hotkey-release: TTI starts here (brief §Speed)
    private var sttMs = 0
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
        }
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
        rewriteProfile = rewrite || defaultProfile == "rewrite"
        partialText = ""
        partialInFlight = false
        pendingChunk = nil
        finalText = nil
        chunkFails = 0
        insertOnce = false
        sttMs = 0
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
        captureSeconds = capture.stop()   // removes tap first
        capture.flushTail()               // enqueues tail-chunk dispatch on main
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
            pendingChunk = (wav, 0)
            return
        }
        partialInFlight = true
        let gen = generation
        SidecarClient.shared.transcribe(wav: wav, partial: partial) { [weak self] text, ms in
            DispatchQueue.main.async {
                guard let self = self, self.generation == gen else { return }
                self.sttMs += ms
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
                if let (pwav, _) = self.pendingChunk {
                    self.pendingChunk = nil
                    self.sendChunk(wav: pwav, partial: self.mode != .idle)
                }
            }
        }
    }

    /// After release: raw = concatenated partials (chunks were streamed live,
    /// including the tail flushed in finish()). If any chunk failed, log it and
    /// proceed with what we have; fully-empty → insert nothing (brief §7).
    private func resolveFinalText() {
        let gen = generation
        if partialInFlight {
            // Wait for the in-flight straggler; pendingChunk (if any) is
            // dispatched by its completion handler.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self, self.generation == gen else { return }
                self.resolveFinalText()
            }
            return
        }
        if let (pwav, _) = pendingChunk {
            pendingChunk = nil
            sendChunk(wav: pwav, partial: false)
            return
        }
        var raw = partialText
        if chunkFails > 0 || raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Sidecar hiccup during streaming → one full re-transcribe attempt.
            raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // We no longer hold full audio (streamed incrementally). If a chunk
            // failed AND no partial arrived, insert nothing (brief §7: empty → nothing).
            if raw.isEmpty {
                // Honest silence path (t_b3e7802c): if EVERY chunk that left the
                // app was below the RMS floor (or nothing was emitted at all),
                // the mic heard nothing — say so, name the device, insert nothing.
                if capture.sessionWasFullySilent || capture.silentChunks + capture.voicedChunks == 0 {
                    let dev = capture.activeDevice.map { " (device: \($0.name))" } ?? ""
                    overlay.show(.error("Couldn't hear you — check your mic\(dev)"), autoHideAfter: 3.0)
                } else if repeatSuppressed && partialText.isEmpty {
                    overlay.show(.error("Couldn't hear you — check your mic"), autoHideAfter: 3.0)
                } else {
                    overlay.show(.error("Nothing captured"), autoHideAfter: 1.5)
                }
                return
            }
            // Partial data exists despite a failed chunk — proceed with what we have,
            // logged as degraded capture.
            NSLog("QuickScribe: \(chunkFails) stream chunk(s) failed; assembling from \(raw.count) chars of partials")
        }
        polishAndInsert(raw: raw)
    }

    // MARK: - Polish + insert

    private func polishAndInsert(raw: String) {
        let gen = generation
        let prof = profile
        let t0 = Date()
        // TTI budget counts from hotkey-RELEASE (releaseAt set in finish());
        // polish may only use what the bucket leaves after tail STT (PM note 2:
        // late polish must not stretch insertion beyond brief §8).
        let budget = AppInfo.ttiBudget(utteranceSeconds: captureSeconds)
        let spent = releaseAt.map { Date().timeIntervalSince($0) } ?? 0
        let remaining = min(budget, max(0.2, budget - spent))

        SidecarClient.shared.polish(text: raw, profile: prof, timeout: remaining) { [weak self] polished, degraded in
            DispatchQueue.main.async {
                guard let self = self, self.generation == gen else { return }
                if degraded {
                    // PM guidance: retry once, then raw (brief §8 — never block past budget).
                    let spent = self.releaseAt.map { Date().timeIntervalSince($0) } ?? 0
                    let retryBudget = min(budget, max(0.2, budget - spent))
                    SidecarClient.shared.polish(text: raw, profile: prof, timeout: retryBudget) { [weak self] p2, deg2 in
                        DispatchQueue.main.async {
                            guard let self = self, self.generation == gen else { return }
                            self.insertText(deg2 ? raw : (p2 ?? raw),
                                           raw: raw, profile: prof, degraded: deg2,
                                           polishStarted: t0)
                        }
                    }
                } else {
                    self.insertText(polished ?? raw, raw: raw, profile: prof,
                                  degraded: false, polishStarted: t0)
                }
            }
        }
    }

    private func insertText(_ text: String, raw: String, profile prof: String,
                            degraded: Bool, polishStarted: Date) {
        guard !insertOnce else { return }   // exactly-once guarantee
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            overlay.show(.error("Couldn't hear you — check your mic"), autoHideAfter: 2.5)
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
            let msSTT = self.sttMs
            if ok {
                self.overlay.show(degraded ? .degraded : .inserted, autoHideAfter: 1.4)
                if lostImages {
                    NSLog("QuickScribe: clipboard image could not be restored (v1 accepted edge case)")
                }
                SidecarClient.shared.capture(raw: raw, polished: text, profile: prof,
                                             msStt: msSTT, msPolish: msPolish)
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
