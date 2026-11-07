import AppKit
import QuickScribeCore

/// The back half of a dictation: the transcript leaves the pill, cleanup runs
/// within the time budget, and the words reach the document exactly once.
/// Moved whole from SessionController.swift; the few `private` marks that
/// crossed the file boundary came off, nothing else changed.
@MainActor
extension SessionController {

    // MARK: - Transcript

    /// Every pill state goes through here: it shows and remembers, so tests
    /// can check the ORDER states appeared in, not just the last one.
    func pill(_ state: OverlayController.State, autoHideAfter: TimeInterval? = nil) {
        pillLog.append(state)
        overlay.show(state, autoHideAfter: autoHideAfter)
    }

    func showWords(_ words: String, generation gen: Int) {
        guard generation == gen, mode != .idle, !words.isEmpty else { return }
        pill(.recording(mode: RefineMode.title(forProfile: profile), words: words))
    }

    func transcriptionFailed(_ error: Error, generation gen: Int) {
        guard generation == gen else { return }
        NSLog("QuickScribe: transcription failed: \(error.localizedDescription)")
        pill(.error("Apple speech recognition isn't available right now."), autoHideAfter: 3.0)
    }

    func resolveFinalText(_ transcript: String, generation gen: Int) {
        guard generation == gen else { return }
        var raw = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // A mic that never rose above the floor heard nothing, so anything the
        // recognizer made of that noise must not be inserted. A service that
        // says every segment was not speech has heard nothing too, even when
        // the room was loud enough to clear the floor: a fan, traffic.
        let heardNothing = silentSessionOverride ?? capture.sessionWasFullySilent
        let serviceSaidNoSpeech = serviceHeardNoSpeech
        if heardNothing || serviceSaidNoSpeech || raw.isEmpty {
            serviceHeardNoSpeech = false   // spent with this session, whatever it said
            // A notice set for this session (the length limit) explains the
            // emptiness better than a generic line, so it wins here too.
            if modePickedThisSession {
                pendingNotice = nil
                announceProfile()
            } else if let why = pendingNotice {
                pendingNotice = nil
                pill(.error(why.display(copied: false)), autoHideAfter: 3.5)
            } else if heardNothing || serviceSaidNoSpeech {
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
        // This dictation's settings, not whatever the menu says now.
        let settings = routeSettings()
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
        // differ: Apple's short tuned set, or the longer set written for general services.
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
}
