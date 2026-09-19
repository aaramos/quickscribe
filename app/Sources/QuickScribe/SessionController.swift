import AppKit

/// The capture-session state machine. Owns the full lifecycle per brief:
/// press → record (+streaming partials) → release → tail → final STT →
/// polish (bounded by TTI budget, PM: degraded→retry once→raw) →
/// insert exactly once → history. Esc cancels, sidecar-down never crashes.
@MainActor
final class SessionController {
    enum Mode { case idle, pushToTalk, toggled }

    private(set) var mode: Mode = .idle
    private var rewriteProfile = false
    var profile: String { rewriteProfile ? "rewrite" : "polish" }
    /// Menu-selected default profile ("polish" | "rewrite"); the
    /// ⌘⌥⌃Space hotkey overrides per-session (brief §4).
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

    /// Menu bar needs to know when sessions start/end (icon state, menu disable).
    var onPhaseChange: ((Bool) -> Void)?

    init() {
        hotkeys.onHotkey = { [weak self] down, rewrite in
            Task { @MainActor in self?.hotkey(down: down, rewrite: rewrite) }
        }
        overlay.onEscape = { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
        capture.onChunk = { [weak self] wav, secs in
            DispatchQueue.main.async { self?.streamChunk(wav: wav, secs: secs) }
        }
    }

    var isRecording: Bool { mode != .idle }

    // MARK: - Hotkey FSM (hold wins on press)

    func hotkey(down: Bool, rewrite: Bool) {
        if down {
            guard mode == .idle else {
                // Press while toggled-on → toggle off (end session).
                if mode == .toggled { finish() }
                return
            }
            start(rewrite: rewrite)
        } else { // up
            guard mode == .pushToTalk else { return }
            let held = Date().timeIntervalSince(sessionStart)
            if held < AppInfo.tapThreshold {
                // Quick tap → toggle mode: recording continues.
                mode = .toggled
            } else {
                // Held past threshold → push-to-talk ends here.
                finish()
            }
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
        sessionStart = Date()

        do {
            try capture.start()
        } catch {
            overlay.show(.error("Mic unavailable — check Microphone permission"), autoHideAfter: 2.5)
            return
        }
        mode = .pushToTalk
        overlay.show(.recording)   // same runloop tick as hotkey → <100ms (brief)
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
                if let text = text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.partialText = self.join(self.partialText, text)
                    if self.mode != .idle { self.overlay.show(.partial(self.partialText)) }
                } else if !partial || self.mode == .idle {
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
                overlay.show(.error("Nothing captured"), autoHideAfter: 1.5)
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
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            overlay.show(.error("Nothing to insert"), autoHideAfter: 1.5)
            return
        }
        Insertion.insert(text) { [weak self] ok, lostImages in
            guard let self = self else { return }
            self.insertOnce = true
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
    func activate() { hotkeys.start() }
    func showOverlay(_ s: OverlayController.State, autoHide: TimeInterval? = nil) { overlay.show(s, autoHideAfter: autoHide) }
}
