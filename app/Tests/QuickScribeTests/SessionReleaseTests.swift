import AVFoundation
import XCTest
@testable import QuickScribe
@testable import QuickScribeCore

/// Drives the release path (processRelease) without a microphone: stubbed
/// recognizer, fake service, fake keyboard and clipboard. Every ordering rule
/// is checked here as it would happen on a real release, one ordering rule
/// at a time.
@MainActor
final class SessionReleaseTests: XCTestCase {
    private var session: SessionController!
    private var service: FakeService!
    private var secrets: CountingSecrets!
    private var defaults: UserDefaults!
    private var suite = ""
    private var store: EndpointSettingsStore!

    // Observations
    private var insertedAfter: String?
    private var insertedAtPillCount: Int = -1
    private var copied: [String] = []
    private var fakeCleaner: FakeCleaner!

    private let base = Date(timeIntervalSinceReferenceDate: 100)

    override func setUpWithError() throws {
        service = try FakeService()
        try service.start()
        secrets = CountingSecrets()
        suite = "quickscribe.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        store = EndpointSettingsStore(defaults: defaults, secrets: secrets)
        let prompts = PromptLibrary(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qs-prompts-\(UUID().uuidString).json"))
        session = SessionController(prompts: prompts, endpointStore: store)
        fakeCleaner = FakeCleaner()
        session.cleaner = fakeCleaner
        session.targetReader = { .textField }
        session.textInserter = { [weak self] text, done in
            self?.insertedAfter = text
            self?.insertedAtPillCount = self?.session.pillLog.count ?? -1
            done(true, false)
        }
        session.copyWriter = { [weak self] text in self?.copied.append(text); return true }
        session.silentSessionOverride = false       // a real session heard audio; tests have no mic
        session.pasteKept = { [weak self] text in self?.copied.append(text); return true }
    }

    override func tearDown() {
        service.stop()
        session = nil
        fakeCleaner = nil
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        store = nil
        service = nil
    }

    // MARK: - Wiring helpers

    private func chooseCustomSpeech() {
        store.save(EndpointSettings(address: service.baseURL, speechModel: "speechy",
                                    useCustomSpeech: true))
    }

    private func chooseAppleSpeech() {
        store.save(EndpointSettings())
    }

    /// start()'s decision: only a service route keeps the whole recording.
    private func armedClip(seconds: Double = 0.5) {
        session.armRecording()
        guard let recording = session.recording else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050)!   // 0.5 s
        b.frameLength = 22_050
        recording.append(b)
        _ = seconds
    }

    private func okTranscription(_ words: String, delay: TimeInterval = 0) {
        service.queue(service.text(#"{"text":"\#(words)"}"#, delay: delay),
                      forPath: "/v1/audio/transcriptions")
    }

    private func failingTranscription(delay: TimeInterval = 0) {
        service.queue(service.text("nope", status: 500, delay: delay),
                      forPath: "/v1/audio/transcriptions")
    }

    private func waitUntil(_ done: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while !done() {
            if Date() > deadline { XCTFail("condition never happened", file: file, line: line); return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Only the service route pays for the recording

    func testAppleRouteKeepsNoWholeRecordingAndNeverReadsTheKey() async {
        chooseAppleSpeech()
        session.armRecording()
        XCTAssertNil(session.recording, "an Apple-speech session must not hold an audio buffer")
        session.releaseAt = base
        session.appleModelReadyOverride = false
        let live = StubSpeech(.words("Apple said this."))
        session.processRelease(customChosen: false, silent: false, live: live)
        await waitUntil { self.insertedAfter != nil }
        XCTAssertEqual(self.insertedAfter, "Apple said this.")
        XCTAssertEqual(secrets.reads, 0, "the Keychain is untouched on the Apple route")
        XCTAssertEqual(session.pillLog.last, .degraded, "no notice earned, so the plain result pill shows")
    }

    // MARK: - Z4: a choice applies to the next dictation, never this one

    /// The settings are taken once when the dictation starts. A menu choice
    /// made while it records (easy in hands-free) must not change the route or
    /// the model of the dictation already running.
    func testAChoiceMadeMidSessionDoesNotChangeTheDictationInProgress() async {
        chooseAppleSpeech()                        // this dictation is an Apple one
        session.sessionSettings = store.load()     // what start() would have taken
        session.clock = { self.base }
        session.releaseAt = base
        session.appleModelReadyOverride = false
        let live = StubSpeech(.words("Apple words for this one."))
        session.processRelease(customChosen: false, silent: false, live: live)
        await waitUntil { self.insertedAfter != nil }
        XCTAssertEqual(self.insertedAfter, "Apple words for this one.")

        // The person now switches cleanup (and speech) to the service, mid-way
        // through nothing: the NEXT dictation must use it.
        var s = store.load()
        s.address = "http://127.0.0.1:1234/v1"
        s.useCustomSpeech = true
        s.useCustomCleanup = true
        s.speechModel = "speechy"
        s.cleanupModel = "tidier"
        store.save(s)
        XCTAssertTrue(store.load().cleanupUsesEndpoint, "the saved choice did change")
        XCTAssertFalse(session.routeSettings().cleanupUsesEndpoint,
                       "the finished session kept the settings it started with")

        // A fresh session takes the new ones.
        session.sessionSettings = nil
        session.sessionSettings = store.load()
        XCTAssertTrue(session.routeSettings().cleanupUsesEndpoint,
                      "the next dictation starts with the new choice")
    }

    /// The speech half stays put too: a model chosen while the dictation
    /// records must not change the model the upload uses, nor the route.
    func testASpeechModelChosenMidSessionIsNotTheOneUploaded() async {
        chooseCustomSpeech()                        // speech model "speechy"
        session.sessionSettings = store.load()
        session.armRecording()                      // what start() would have armed
        guard let recording = session.recording else { return XCTFail("no buffer") }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050)!
        b.frameLength = 22_050
        recording.append(b)
        okTranscription("speechy words")
        // Switched mid-session to another model, and to Apple cleanup.
        var s = store.load()
        s.speechModel = "some-other-model"
        s.useCustomCleanup = false
        store.save(s)
        session.appleModelReadyOverride = false
        session.releaseAt = base
        let live = StubSpeech(.hangs(returnsOnCancel: nil))
        session.processRelease(customChosen: session.recording != nil, silent: false, live: live)
        await waitUntil { self.insertedAfter != nil }
        XCTAssertEqual(self.insertedAfter, "speechy words")
        let upload = try? XCTUnwrap(service.received.first { $0.path.contains("transcriptions") })
        let body = String(decoding: upload?.body ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nspeechy"), body)
        XCTAssertFalse(body.contains("some-other-model"),
                       "the model chosen mid-session must not be the one uploaded")
    }

    func testCustomSessionDiscardsItsBufferAtRelease() async {
        chooseCustomSpeech()
        armedClip()
        XCTAssertNotNil(session.recording, "a service session must hold the whole recording")
        let buffer = session.recording!
        okTranscription("Service words.")
        session.appleModelReadyOverride = false
        session.releaseAt = base
        let live = StubSpeech(.hangs(returnsOnCancel: nil))
        session.processRelease(customChosen: true, silent: false, live: live)
        await waitUntil { self.insertedAfter != nil }
        XCTAssertNil(session.recording, "the session lets go of the buffer at release")
        XCTAssertEqual(buffer.wav().data.count, 44, "discarded, so a late buffer cannot grow it back")
    }

    // MARK: - Apple winds down at release; a good reply never waits on it

    func testServiceReplyIsInsertedEvenWhileAppleHangs() async {
        chooseCustomSpeech()
        armedClip()
        okTranscription("Service words.", delay: 0.5)
        session.appleModelReadyOverride = false
        session.releaseAt = base
        let live = StubSpeech(.hangs(returnsOnCancel: nil))
        session.processRelease(customChosen: true, silent: false, live: live)
        // The wind-down starts alongside the upload, not after it.
        await waitUntil { live.finishStarted }
        XCTAssertNil(self.insertedAfter, "the upload has not answered yet: no premature insert")
        await waitUntil { self.insertedAfter != nil }
        XCTAssertEqual(self.insertedAfter, "Service words.")
        XCTAssertFalse(live.finishResolved, "the reply did not wait for the stuck Apple session")
        XCTAssertEqual(session.pillLog.last, .degraded)   // cleanup skipped by override; the insert happened anyway
    }

    // MARK: - Neither service outcome spends the cleanup budget

    func testSlowFailureStillLetsCleanupUseTheWholeBudget() async {
        chooseCustomSpeech()
        armedClip()
        failingTranscription()
        // The clock stands 10 seconds past release: an unrepaired budget
        // would read as spent and the model would never be asked.
        let late = base.addingTimeInterval(10)
        session.clock = { late }
        session.releaseAt = base
        session.appleModelReadyOverride = true
        let live = StubSpeech(.words("Apple said this."))
        session.processRelease(customChosen: true, silent: false, live: live)
        await waitUntil { self.insertedAfter != nil }
        XCTAssertEqual(self.insertedAfter, "Apple said this.")
        XCTAssertEqual(fakeCleaner.calls, 1, "the fallback must still be offered to the cleanup model")
    }

    func testSlowSuccessStillLetsCleanupUseTheWholeBudget() async {
        chooseCustomSpeech()
        armedClip()
        okTranscription("Service words.")
        let late = base.addingTimeInterval(30)
        session.clock = { late }
        session.releaseAt = base
        session.appleModelReadyOverride = true
        let live = StubSpeech(.hangs(returnsOnCancel: nil))
        session.processRelease(customChosen: true, silent: false, live: live)
        await waitUntil { self.insertedAfter != nil }
        XCTAssertEqual(self.insertedAfter, "Service words.")
        XCTAssertEqual(fakeCleaner.calls, 1, "speech time never counts against cleanup")
    }

    // MARK: - Blank is no words

    func testBlankReplyFromTheServiceIsTreatedAsFailure() async {
        chooseCustomSpeech()
        armedClip()
        okTranscription("   \n  ")
        session.clock = { self.base }
        session.releaseAt = base
        session.appleModelReadyOverride = false
        let live = StubSpeech(.words("Apple said this."))
        session.processRelease(customChosen: true, silent: false, live: live)
        await waitUntil { self.insertedAfter != nil }
        XCTAssertEqual(self.insertedAfter, "Apple said this.",
                       "'   ' is no words; Apple's answer is used, not 'Nothing captured'")
        XCTAssertNotEqual(session.pillLog.last, .error("Nothing captured"))
    }

    // MARK: - A noisy room is not a dictation

    /// The reported failure: a fan or traffic above the floor, nothing said,
    /// and the service hands back "Thank you for watching." The service's own
    /// verdict must stop it before the cleanup model or the document sees it.
    func testNoSpeechVerdictFromTheServiceInsertsNothing() async {
        chooseCustomSpeech()
        armedClip()
        service.queue(service.text(#"""
        {"text":" Thank you for watching.","segments":[{"no_speech_prob":0.823,"text":" Thank you for watching."}]}
        """#), forPath: "/v1/audio/transcriptions")
        session.clock = { self.base }
        session.releaseAt = base
        session.appleModelReadyOverride = false
        let live = StubSpeech(.words("Apple invented something."))
        session.processRelease(customChosen: true, silent: false, live: live)
        await waitUntil { self.session.pillLog.last != nil && self.session.pillLog.count > 0 }
        // Give the insert path a moment to prove it never runs.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(self.insertedAfter, "an invented phrase from a noisy room must never be typed")
        XCTAssertTrue(self.copied.isEmpty, "and must not reach the clipboard either")
        XCTAssertEqual(fakeCleaner.calls, 0, "the cleanup model is not asked to polish words nobody said")
        guard case .error(let why)? = session.pillLog.last else { return XCTFail("\(String(describing: session.pillLog.last))") }
        XCTAssertTrue(why.contains("Couldn't hear you"), why)
        XCTAssertFalse(why.contains("Thank you"), "the notice must never repeat the invented words")
    }

    /// Real speech in the same clip shape is inserted exactly as before.
    func testSpeechVerdictFromTheServiceStillInserts() async {
        chooseCustomSpeech()
        armedClip()
        service.queue(service.text(#"""
        {"text":"Let's meet at three.","segments":[{"no_speech_prob":0.004,"text":"Let's meet at three."}]}
        """#), forPath: "/v1/audio/transcriptions")
        session.clock = { self.base }
        session.releaseAt = base
        session.appleModelReadyOverride = true
        let live = StubSpeech(.words("unused"))
        session.processRelease(customChosen: true, silent: false, live: live)
        await waitUntil { self.insertedAfter != nil }
        XCTAssertEqual(self.insertedAfter, "Let's meet at three.")
        XCTAssertGreaterThanOrEqual(fakeCleaner.calls, 1)
    }

    /// A service that sends no segments keeps the old behavior: words land.
    func testAServiceWithoutTheFieldStillInserts() async {
        chooseCustomSpeech()
        armedClip()
        okTranscription("Thank you.")
        session.clock = { self.base }
        session.releaseAt = base
        session.appleModelReadyOverride = true
        let live = StubSpeech(.words("unused"))
        session.processRelease(customChosen: true, silent: false, live: live)
        await waitUntil { self.insertedAfter != nil }
        XCTAssertEqual(self.insertedAfter, "Thank you.",
                       "no verdict from the service means no new rule; the floor and empty checks still decide")
    }

    /// The verdict belongs to one session: the next one starts clean.
    func testTheNoSpeechVerdictIsSpentWithItsSession() async {
        chooseCustomSpeech()
        armedClip()
        service.queue(service.text(#"{"text":" Thank you.","segments":[{"no_speech_prob":0.83}]}"#),
                      forPath: "/v1/audio/transcriptions")
        session.clock = { self.base }
        session.releaseAt = base
        session.appleModelReadyOverride = false
        session.processRelease(customChosen: true, silent: false, live: StubSpeech(.words("unused")))
        await waitUntil { self.session.pillLog.contains { if case .error = $0 { return true }; return false } }
        XCTAssertTrue(session.serviceHeardNoSpeech == false, "read once, then cleared")
    }

    // MARK: - Notices stay readable

    func testFailureNoticeShowsAfterTheWordsLand() async {
        chooseCustomSpeech()
        armedClip()
        failingTranscription()
        session.clock = { self.base }
        session.releaseAt = base
        session.appleModelReadyOverride = false
        let live = StubSpeech(.words("Apple said this."))
        session.processRelease(customChosen: true, silent: false, live: live)
        await waitUntil { self.session.pillLog.last != nil && self.insertedAtPillCount >= 0 }
        // The insert happened first; the notice is the LAST pill state.
        XCTAssertGreaterThan(session.pillLog.count, self.insertedAtPillCount,
                             "the notice may not be stamped over by the result pill")
        XCTAssertEqual(session.pillLog.last,
                       .error("Your speech service failed. Used Apple's words."))
        // And it appeared only once: no earlier pill already said it and got
        // buried by the insert.
        let notice = OverlayController.State.error("Your speech service failed. Used Apple's words.")
        XCTAssertEqual(session.pillLog.filter { $0 == notice }.count, 1)
    }

    func testNoticeSurvivesTheClipboardRoute() async {
        chooseCustomSpeech()
        armedClip()
        failingTranscription()
        session.clock = { self.base }
        session.releaseAt = base
        session.appleModelReadyOverride = false
        session.targetReader = { .notText }
        let live = StubSpeech(.words("Apple said this."))
        session.processRelease(customChosen: true, silent: false, live: live)
        await waitUntil { !self.session.pillLog.isEmpty && self.insertedAfter == nil && !self.copied.isEmpty }
        guard case .error(let text)? = session.pillLog.last else { return XCTFail("\(String(describing: session.pillLog.last))") }
        XCTAssertTrue(text.contains("Apple's words copied to the clipboard."), text)
        XCTAssertTrue(text.contains("copied to the clipboard."), text)
        XCTAssertEqual(copied, ["Apple said this."])
    }

    func testLimitNoticeShowsAfterInsertionNotBefore() async {
        chooseCustomSpeech()
        session.armRecording()
        session.recording?.maxSeconds = 0.001          // any speech overflows immediately
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050)!
        b.frameLength = 22_050
        session.recording?.append(b)
        session.clock = { self.base }
        session.releaseAt = base
        session.appleModelReadyOverride = false
        let live = StubSpeech(.words("Apple heard all of it."))
        session.processRelease(customChosen: true, silent: false, live: live)
        await waitUntil { self.insertedAfter != nil }
        XCTAssertEqual(service.received.filter { $0.path.contains("transcriptions") }.count, 0,
                       "an over-limit recording is never uploaded")
        guard case .error(let why)? = session.pillLog.last else { return XCTFail("\(String(describing: session.pillLog.last))") }
        XCTAssertTrue(why.contains("limit"), why)
    }

    func testNoNoticeKeepsThePlainPills() async {
        chooseAppleSpeech()
        session.appleModelReadyOverride = false
        session.releaseAt = base
        let live = StubSpeech(.words("Plain words."))
        session.processRelease(customChosen: false, silent: false, live: live)
        await waitUntil { self.insertedAfter != nil }
        XCTAssertEqual(session.pillLog.last, .degraded)   // cleanup skipped for the model override
    }

    // MARK: - Cancel during upload closes Apple's session too

    func testCancelDuringUploadClosesApplesSession() async {
        chooseCustomSpeech()
        armedClip()
        failingTranscription(delay: 3)                 // the upload sits there mid-flight
        session.releaseAt = base
        session.appleModelReadyOverride = false
        let live = StubSpeech(.hangs(returnsOnCancel: "late words"))
        session.transcription = live                   // what start() would have installed
        session.showOverlay(.processing)               // the state finish() leaves behind
        session.processRelease(customChosen: true, silent: false, live: live)
        await waitUntil { live.finishStarted }         // wind-down racing the upload already
        session.cancel()
        XCTAssertTrue(live.wasCancelled, "Esc during an upload must end Apple's session too")
        XCTAssertNil(session.recording, "and free the audio")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(self.insertedAfter, "a cancelled upload inserts nothing, even when it answers")
    }

    func testStuckAppleSessionCannotHoldTheFailurePathForever() async {
        let saved = SessionController.appleFallbackGrace
        SessionController.appleFallbackGrace = 0.3
        defer { SessionController.appleFallbackGrace = saved }
        chooseCustomSpeech()
        armedClip()
        failingTranscription()
        session.clock = { self.base }
        session.releaseAt = base
        let live = StubSpeech(.hangs(returnsOnCancel: nil))
        session.processRelease(customChosen: true, silent: false, live: live)
        await waitUntil {
            if case .error(let t)? = self.session.pillLog.last { return t.contains("no words either") }
            return false
        }
    }

    // MARK: - Stubs

    private final class FakeCleaner: Cleaning, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        func clean(_ text: String, instructions: String) async throws -> String {
            lock.lock(); _calls += 1; lock.unlock()
            return text      // an honest do-nothing cleanup passes the guard
        }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    }

    private final class CountingSecrets: SecretStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var _reads = 0
        func secret() -> String? { lock.lock(); _reads += 1; lock.unlock(); return "k" }
        func setSecret(_ value: String?) throws {}
        var reads: Int { lock.lock(); defer { lock.unlock() }; return _reads }
    }

    private final class StubSpeech: SpeechAccepting, @unchecked Sendable {
        enum Behavior {
            case words(String)              // answers at once
            case fails                      // Apple's session itself fails
            case hangs(returnsOnCancel: String?)   // never answers unless cancelled
        }
        private let lock = NSLock()
        private let behavior: Behavior
        private var waiters: [CheckedContinuation<String, Error>] = []
        private var _finishStarted = false
        private var _finishResolved = false
        private var _cancelled = false

        init(_ behavior: Behavior) { self.behavior = behavior }

        var finishStarted: Bool { lock.lock(); defer { lock.unlock() }; return _finishStarted }
        var finishResolved: Bool { lock.lock(); defer { lock.unlock() }; return _finishResolved }
        var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

        func append(_ buffer: AVAudioPCMBuffer) {}

        func finish() async throws -> String {
            lock.lock(); _finishStarted = true; lock.unlock()
            switch behavior {
            case .words(let w):
                lock.lock(); _finishResolved = true; lock.unlock()
                return w
            case .fails:
                throw NSError(domain: "stub", code: 1)
            case .hangs(let onCancel):
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { done in
                        self.register(done)
                    }
                } onCancel: {
                    self.end(with: onCancel)
                }
            }
        }

        func cancel() {
            lock.lock(); _cancelled = true; lock.unlock()
            end(with: nil)
        }

        private func register(_ done: CheckedContinuation<String, Error>) {
            lock.lock()
            if _cancelled { lock.unlock(); done.resume(throwing: CancellationError()); return }
            waiters.append(done)
            lock.unlock()
        }

        private func end(with words: String?) {
            lock.lock()
            let pending = waiters
            waiters = []
            if !pending.isEmpty { _finishResolved = true }
            lock.unlock()
            for done in pending {
                if let words { done.resume(returning: words) }
                else { done.resume(throwing: CancellationError()) }
            }
        }
    }
}
