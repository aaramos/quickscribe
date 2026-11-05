import AVFoundation
import XCTest
@testable import QuickScribe
@testable import QuickScribeCore

/// Cleanup routing inside a real session: the fake service answers chat, and
/// every outcome (reply, refusal, outage, bad key) must keep the words. Also
/// the pure route choice and the failure wording it feeds to the person.
@MainActor
final class SessionCleanupRouteTests: XCTestCase {
    func testRouteFollowsTheSettingNotJustTheAddress() {
        XCTAssertEqual(SessionController.cleanupRoute(settings: EndpointSettings(address: "http://127.0.0.1:1234/v1",
                                                                                 useCustomCleanup: true)), .service)
        XCTAssertEqual(SessionController.cleanupRoute(settings: EndpointSettings(address: "http://127.0.0.1:1234/v1")), .apple,
                       "an address alone keeps Apple")
        XCTAssertEqual(SessionController.cleanupRoute(settings: EndpointSettings(useCustomCleanup: true)), .apple,
                       "Custom without an address stays Apple")
    }

    func testFailureNoticesArePlainAndTellYouNothingWasLost() {
        let key = SessionController.cleanupFailureNotice(EndpointError.unauthorized)
        XCTAssertTrue(key.contains("refused the key"), key)
        XCTAssertTrue(key.hasSuffix("Your words were inserted as typed."), key)
        let time = SessionController.cleanupFailureNotice(DeadlinePassed())
        XCTAssertTrue(time.contains("did not answer in time"), time)
        let other = SessionController.cleanupFailureNotice(NSError(domain: "x", code: 1))
        XCTAssertTrue(other.contains("cleanup service failed"), other)
        for n in [key, time, other] { XCTAssertFalse(n.contains("\u{2014}"), n) }
    }

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
        XCTAssertTrue(notice.contains("code 500"), notice)
        XCTAssertTrue(notice.contains("inserted as typed"), notice)
    }

    func testUnreachableAddressGivesAClearMessageAndKeepsTheWords() async {
        store.save(EndpointSettings(address: "http://127.0.0.1:9/v1", cleanupModel: "tidier",
                                    useCustomCleanup: true))
        await runRelease()
        XCTAssertEqual(inserted, "The invoice is 1200 due Friday.")
        guard case .error(let notice)? = session.pillLog.last else { return XCTFail("\(String(describing: session.pillLog.last))") }
        XCTAssertTrue(notice.contains("Could not reach the address."), notice)
    }

    func testWrongKeyNamesTheKey() async {
        chooseServiceCleanup()
        service.queue(service.text("denied", status: 401), forPath: "/v1/chat/completions")
        await runRelease()
        XCTAssertEqual(inserted, "The invoice is 1200 due Friday.")
        guard case .error(let notice)? = session.pillLog.last else { return XCTFail("\(String(describing: session.pillLog.last))") }
        XCTAssertTrue(notice.contains("refused the key"), notice)
    }

    func testGuardRejectionOnTheServiceRouteStaysQuietAndLosesNothing() async {
        chooseServiceCleanup()
        // A reply with an invented number: the same guard Apple's route uses
        // must stamp on it, falling back to the person's tidied words, quietly.
        service.queue(service.text(qsSSE("The invoice is 9999 due Friday.")),
                      forPath: "/v1/chat/completions")
        await runRelease()
        XCTAssertEqual(inserted, "The invoice is 1200 due Friday.")
        XCTAssertEqual(session.pillLog.last, .degraded)
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
        session.cleaner = note       // override stands in for whichever cleaner the route picks
        store.save(EndpointSettings())  // everything Apple
        await runRelease()
        XCTAssertEqual(note.instructions, library.prompt(session.profile, route: .apple))
        XCTAssertEqual(secrets.reads, 0, "the Apple cleanup route never reads the Keychain")
    }

    func testRewriteRunsOnBothRoutes() async throws {
        // The ⌃⌘⇧ profile over the service: FactoryPrompts.rewrite's text is
        // what the old sidecar sent, so it must arrive as a system prompt.
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
}

/// One SSE chat body: a content delta, a stop line, and [DONE].
private func qsSSE(_ content: String) -> String {
    "data: {\"choices\":[{\"delta\":{\"content\":\"\(content)\"}}]}\n\n"
        + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
}
