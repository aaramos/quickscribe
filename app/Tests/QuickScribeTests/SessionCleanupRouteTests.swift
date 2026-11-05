import AppKit
import AVFoundation
import XCTest
@testable import QuickScribe
@testable import QuickScribeCore

/// Cleanup routing inside a real session: the fake service answers chat, and
/// every outcome (reply, refusal, outage, bad key) must keep the words. Also
/// the pure route choice, the notice wording, and the pill it has to fit in.
@MainActor
final class SessionCleanupRouteTests: XCTestCase {
    private var session: SessionController!
    private var service: FakeService!
    private var secrets: ReadKeyOnce!
    private var defaults: UserDefaults!
    private var suite = ""
    private var store: EndpointSettingsStore!
    private var library: PromptLibrary!
    private var inserted: String?
    private let base = Date(timeIntervalSinceReferenceDate: 100)

    private final class ReadKeyOnce: SecretStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var _reads = 0
        func secret() -> String? { lock.lock(); _reads += 1; lock.unlock(); return "k" }
        func setSecret(_ value: String?) throws {}
        var reads: Int { lock.lock(); defer { lock.unlock() }; return _reads }
    }

    private final class Spy: SpeechAccepting, @unchecked Sendable {
        func append(_ buffer: AVAudioPCMBuffer) {}
        func finish() async throws -> String { "The invoice is 1200 due Friday." }
        func cancel() {}
    }

    override func setUpWithError() throws {
        service = try FakeService()
        try service.start()
        secrets = ReadKeyOnce()
        suite = "quickscribe.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        store = EndpointSettingsStore(defaults: defaults, secrets: secrets)
        library = PromptLibrary(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qs-clean-\(UUID().uuidString).json"))
        session = SessionController(prompts: library, endpointStore: store)
        inserted = nil
        session.silentSessionOverride = false
        session.clock = { self.base }
        session.targetReader = { .textField }
        session.textInserter = { [weak self] text, done in self?.inserted = text; done(true, false) }
        session.appleModelReadyOverride = false   // Apple's model never answers in these tests
    }

    override func tearDown() {
        service.stop()
        defaults.removePersistentDomain(forName: suite)
        SessionController.serviceCleanupTimeout = 6.0
    }

    private func chooseServiceCleanup() {
        store.save(EndpointSettings(address: service.baseURL, cleanupModel: "tidier",
                                    useCustomCleanup: true))
    }

    private func runRelease() async {
        session.releaseAt = base
        session.processRelease(customChosen: false, silent: false, live: Spy())
        let deadline = Date().addingTimeInterval(5)
        while inserted == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testRouteFollowsTheSettingNotJustTheAddress() {
        XCTAssertEqual(SessionController.cleanupRoute(settings: EndpointSettings(address: "http://127.0.0.1:1234/v1",
                                                                                 useCustomCleanup: true)), .service)
        XCTAssertEqual(SessionController.cleanupRoute(settings: EndpointSettings(address: "http://127.0.0.1:1234/v1")), .apple,
                       "an address alone keeps Apple")
        XCTAssertEqual(SessionController.cleanupRoute(settings: EndpointSettings(useCustomCleanup: true)), .apple,
                       "Custom without an address stays Apple")
    }

    func testFailureNoticesArePlainAndTellYouNothingWasLost() {
        XCTAssertEqual(SessionController.cleanupFailureWhy(EndpointError.unauthorized), "Bad API key.")
        XCTAssertEqual(SessionController.cleanupFailureWhy(EndpointError.notReached("Connection 1 failed: bad host.")),
                       "Can't reach the service.", "the OS's own text stays out of the pill")
        XCTAssertEqual(SessionController.cleanupFailureWhy(EndpointError.serverError(503)), "Service error 503.")
        XCTAssertEqual(SessionController.cleanupFailureWhy(DeadlinePassed()), "Cleanup timed out.")
        XCTAssertEqual(SessionController.cleanupFailureWhy(NSError(domain: "x", code: 1)), "Cleanup failed.")
        XCTAssertTrue(SessionController.SessionNotice.cleanupFailed("Bad API key.").display(copied: false)
                      .hasSuffix("Your words went in."))
        XCTAssertTrue(SessionController.SessionNotice.cleanupFailed("Bad API key.").display(copied: true)
                      .hasSuffix("Your words copied to the clipboard."),
                      "nothing claims the words were inserted when they were copied")
    }

    func testServiceCleanupReceivesTheServicePromptAndKeepsTheReply() async throws {
        chooseServiceCleanup()
        let cleaned = "The invoice is 1200 due Friday"   // minus the period: a real edit the guard allows
        service.queue(service.text(qsSSE(cleaned)), forPath: "/v1/chat/completions")
        await runRelease()
        XCTAssertEqual(inserted, cleaned)
        let req = try XCTUnwrap(service.lastRequest)
        XCTAssertEqual(req.path, "/v1/chat/completions")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: req.body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "tidier")
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages[0]["content"], library.prompt(session.profile, route: .service),
                       "the service route must run its own factory set, or the person's prompt")
        XCTAssertEqual(session.pillLog.last, .inserted, "a service reply is a clean cleanup, not degraded")
        XCTAssertEqual(secrets.reads, 1, "the key is read for the route that uses it")
    }

    func testServiceCleanupFailureFallsBackToTidiedWordsAndSaysWhy() async {
        chooseServiceCleanup()
        service.queue(service.text("nope", status: 500), forPath: "/v1/chat/completions")
        await runRelease()
        XCTAssertEqual(inserted, "The invoice is 1200 due Friday.", "the words survive a cleanup outage")
        guard case .error(let notice)? = session.pillLog.last else { return XCTFail("\(String(describing: session.pillLog.last))") }
        XCTAssertTrue(notice.contains("Service error 500."), notice)
        XCTAssertTrue(notice.contains("Your words went in."), notice)
    }

    func testUnreachableAddressGivesAClearMessageAndKeepsTheWords() async {
        store.save(EndpointSettings(address: "http://127.0.0.1:9/v1", cleanupModel: "tidier",
                                    useCustomCleanup: true))
        await runRelease()
        XCTAssertEqual(inserted, "The invoice is 1200 due Friday.")
        guard case .error(let notice)? = session.pillLog.last else { return XCTFail("\(String(describing: session.pillLog.last))") }
        XCTAssertTrue(notice.contains("Can't reach the service."), notice)
    }

    func testWrongKeyNamesTheKey() async {
        chooseServiceCleanup()
        service.queue(service.text("denied", status: 401), forPath: "/v1/chat/completions")
        await runRelease()
        XCTAssertEqual(inserted, "The invoice is 1200 due Friday.")
        guard case .error(let notice)? = session.pillLog.last else { return XCTFail("\(String(describing: session.pillLog.last))") }
        XCTAssertTrue(notice.contains("Bad API key."), notice)
    }

    func testWrongPathNamesThePath() async {
        store.save(EndpointSettings(address: service.baseURL + "/wrong-base", cleanupModel: "tidier",
                                    useCustomCleanup: true))
        await runRelease()
        XCTAssertEqual(inserted, "The invoice is 1200 due Friday.")
        guard case .error(let notice)? = session.pillLog.last else { return XCTFail("\(String(describing: session.pillLog.last))") }
        XCTAssertTrue(notice.contains("Wrong service path."), notice)
    }

    func testGuardRejectionSaysWhyInThePillAndLosesNothing() async {
        chooseServiceCleanup()
        // A reply with an invented number: the guard stamps, the person's own
        // tidied words go in, and the pill says which rule fired instead of
        // passing the skip in silence.
        service.queue(service.text(qsSSE("The invoice is 9999 due Friday.")),
                      forPath: "/v1/chat/completions")
        await runRelease()
        XCTAssertEqual(inserted, "The invoice is 1200 due Friday.")
        guard case .error(let notice)? = session.pillLog.last else { return XCTFail("\(String(describing: session.pillLog.last))") }
        XCTAssertTrue(notice.contains("Cleanup changed a number."), notice)
        XCTAssertTrue(notice.contains("Your words went in."), notice)
    }

    func testAppleRouteStillUsesTheShortAppleSet() async {
        final class Note: Cleaning, @unchecked Sendable {
            private let lock = NSLock()
            var instructions: String?
            func clean(_ text: String, instructions: String) async throws -> String {
                lock.lock(); self.instructions = instructions; lock.unlock()
                return text
            }
        }
        let note = Note()
        session.appleModelReadyOverride = true
        session.cleaner = note
        store.save(EndpointSettings())  // everything Apple
        await runRelease()
        XCTAssertEqual(note.instructions, library.prompt(session.profile, route: .apple))
        XCTAssertEqual(secrets.reads, 0, "the Apple cleanup route never reads the Keychain")
    }

    func testRewriteRunsOnBothRoutes() async throws {
        // The ⌃⌘⇧ profile over the service: the old sidecar's Rewrite text is
        // what a service gets as its system prompt.
        store.save(EndpointSettings(address: service.baseURL, cleanupModel: "tidier", useCustomCleanup: true))
        session.selectProfile("rewrite")
        service.queue(service.text(qsSSE("The invoice is 1200 due Friday")),
                      forPath: "/v1/chat/completions")
        await runRelease()
        XCTAssertEqual(inserted, "The invoice is 1200 due Friday")
        let req = try XCTUnwrap(service.lastRequest)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: req.body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages[0]["content"], ServicePrompts.rewrite)
    }

    func testServiceAnswerPastApplesBudgetWindowIsStillUsedUpToItsOwnDeadline() async {
        // A 5 s clip leaves Apple's planner 0.1 s here; the answer takes 0.3 s
        // and lands. The service runs on the flat deadline, not the leftover.
        chooseServiceCleanup()
        session.captureSeconds = 5
        session.clock = { self.base.addingTimeInterval(2.4) }
        service.queue(service.text(qsSSE("The invoice is 1200 due Friday"), delay: 0.3),
                      forPath: "/v1/chat/completions")
        await runRelease()
        XCTAssertEqual(inserted, "The invoice is 1200 due Friday")
    }

    func testServiceAnswerSlowerThanTheFlatDeadlineFallsBackWithANotice() async {
        SessionController.serviceCleanupTimeout = 0.2
        chooseServiceCleanup()
        service.queue(service.text(qsSSE("late words"), delay: 0.6), forPath: "/v1/chat/completions")
        await runRelease()
        XCTAssertEqual(inserted, "The invoice is 1200 due Friday.", "past the limit, the words are the person's own")
        guard case .error(let notice)? = session.pillLog.last else { return XCTFail("\(String(describing: session.pillLog.last))") }
        XCTAssertTrue(notice.contains("Cleanup timed out."), notice)
    }

    func testSpentBudgetStillAsksTheService() async {
        // Apple's planner stops asking once its budget is gone; a service has
        // its own window, so the request must still leave the Mac.
        chooseServiceCleanup()
        session.clock = { self.base.addingTimeInterval(9.9) }
        service.queue(service.text(qsSSE("The invoice is 1200 due Friday")), forPath: "/v1/chat/completions")
        await runRelease()
        XCTAssertEqual(inserted, "The invoice is 1200 due Friday")
        XCTAssertNotNil(service.received.first { $0.path == "/v1/chat/completions" })
    }

    /// One pill line at the pill's own font, for every sentence a session can
    /// show. If this fails, the notice must be reworded, not the pill widened.
    func testEveryNoticeFitsThePill() {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        var notices: [SessionController.SessionNotice] = [
            .reason("Over the 5-minute limit. Apple speech answered."),
            .reason("The clip came out empty. Apple speech answered."),
            .speechFellBack,
            .cleanupFailed(SessionController.cleanupFailureWhy(DeadlinePassed())),
            .cleanupFailed(SessionController.cleanupFailureWhy(EndpointError.unauthorized)),
            .cleanupFailed(SessionController.cleanupFailureWhy(EndpointError.notReached("the OS's longest plausible sentence about a socket."))),
            .cleanupFailed(SessionController.cleanupFailureWhy(EndpointError.notFound("speech"))),
            .cleanupFailed(SessionController.cleanupFailureWhy(EndpointError.serverError(500))),
            .cleanupFailed(SessionController.cleanupFailureWhy(EndpointError.truncated)),
            .cleanupFailed(SessionController.cleanupFailureWhy(NSError(domain: "x", code: 1))),
        ]
        let refused: [SessionController.SessionNotice] = CleanupGuard.Refusal.allCases.map {
            .cleanupFailed(SessionController.guardRefusalWhy($0))
        }
        notices = notices + refused
        for notice in notices {
            for copied in [false, true] {
                let text = notice.display(copied: copied)
                let width = NSAttributedString(string: text, attributes: [.font: font]).size().width
                XCTAssertLessThanOrEqual(width, OverlayController.messageTextBudget,
                                         "\(text) measures \(Int(width))px")
                XCTAssertFalse(text.contains("\u{2014}"), text)
            }
        }
    }
    func testTheQuestionStemSaysWhatTheRuleSaw() {
        // The rule fires when a question mark is lost, including a request
        // returned as a command: dropped, not answered.
        XCTAssertEqual(SessionController.guardRefusalWhy(.answeredTheQuestion), "Cleanup dropped the question.")
        let why = SessionController.SessionNotice.cleanupFailed(SessionController.guardRefusalWhy(.answeredTheQuestion))
        XCTAssertTrue(why.display(copied: false).hasPrefix("Cleanup dropped the question."))
    }
}

/// One SSE chat body: a content delta, a stop line, and [DONE].
private func qsSSE(_ content: String) -> String {
    "data: {\"choices\":[{\"delta\":{\"content\":\"\(content)\"}}]}\n\n"
        + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"

}
