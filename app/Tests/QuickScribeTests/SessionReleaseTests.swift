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
