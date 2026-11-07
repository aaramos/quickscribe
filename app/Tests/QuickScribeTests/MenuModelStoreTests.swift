import XCTest
@testable import QuickScribe
import QuickScribeCore

/// The model lists the menu shows: their contents, their freshness, and the
/// promises around them (never waits, never prompts, never changes under a
/// reader, never drops a chosen model).
@MainActor
final class MenuModelStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var secrets: CountingSecrets!
    private var store: EndpointSettingsStore!

    /// Counts reads, so "the Keychain is not opened" is a test, not a hope.
    private final class CountingSecrets: SecretStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        private var value: String?
        init(_ value: String? = "k") { self.value = value }
        func secret() -> String? { lock.lock(); reads += 1; lock.unlock(); return value }
        func setSecret(_ value: String?) throws { lock.lock(); self.value = value; lock.unlock() }
        var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    }

    /// A fetch that answers what the test says, and records the calls.
    private final class Caller: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<[ModelEntry], EndpointError> = .success([])
        private var delay: TimeInterval = 0
        private var calls: [(address: String, key: String?)] = []
        func answer(_ r: Result<[ModelEntry], EndpointError>) { lock.lock(); result = r; lock.unlock() }
        func setDelay(_ d: TimeInterval) { lock.lock(); delay = d; lock.unlock() }
        func record(_ settings: EndpointSettings, _ key: String?) {
            lock.lock(); calls.append((settings.address, key)); lock.unlock()
        }
        var seen: [(address: String, key: String?)] { lock.lock(); defer { lock.unlock() }; return calls }
        func make() -> @Sendable (EndpointSettings, String?) async -> Result<[ModelEntry], EndpointError> {
            { [self] settings, key in
                self.record(settings, key)
                lock.lock(); let d = delay; let r = result; lock.unlock()
                if d > 0 { try? await Task.sleep(nanoseconds: UInt64(d * 1_000_000_000)) }
                return r
            }
        }
    }

    override func setUp() {
        suiteName = "qs-menu-models-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        secrets = CountingSecrets()
        store = EndpointSettingsStore(defaults: defaults, secrets: secrets)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
    }

    private func makeStore(_ caller: Caller) -> MenuModelStore {
        MenuModelStore(endpointStore: store, fetch: caller.make())
    }

    private func waitUntil(_ done: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while !done() {
            if Date() > deadline { XCTFail("condition never happened", file: file, line: line); return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Y2: what the lists contain

    func testNoAddressShowsAppleNativeOnlyAndNeverOpensTheKeychain() async {
        let caller = Caller()
        let models = makeStore(caller)
        models.refreshIfUseful()
        let snap = models.snapshot()
        XCTAssertEqual(snap.speech.entries, ["Apple Native"])
        XCTAssertEqual(snap.cleanup.entries, ["Apple Native"])
        XCTAssertTrue(snap.speechIsApple)
        XCTAssertTrue(snap.cleanupIsApple)
        XCTAssertFalse(snap.speech.unreachable)
        XCTAssertTrue(caller.seen.isEmpty, "no address means nothing to ask")
        XCTAssertEqual(secrets.readCount, 0, "no address means no Keychain read at all")
    }

    func testAppleNativeIsAlwaysFirstAndEachRouteGetsItsOwnKind() async {
        var s = EndpointSettings(address: "http://127.0.0.1:1234/v1", speechModel: "whisper-large-v3-8bit",
                                 cleanupModel: "Qwen3.8-27B-4bit", useCustomSpeech: true, useCustomCleanup: true)
        s.language = EndpointSettings.deviceLanguage
        store.save(s)
        let caller = Caller()
        caller.answer(.success([
            ModelEntry(id: "whisper-large-v3-8bit", modelType: "audio_stt"),
            ModelEntry(id: "parakeet-tdt-0.6b-v3", modelType: "audio_stt"),
            ModelEntry(id: "Qwen3.8-27B-4bit", modelType: "vlm"),
            ModelEntry(id: "MarkItDown", modelType: "markitdown"),
        ]))
        let models = makeStore(caller)
        models.refreshIfUseful()
        await waitUntil { !models.speechModels.isEmpty }
        let snap = models.snapshot()
        XCTAssertEqual(snap.speech.entries, ["Apple Native", "whisper-large-v3-8bit", "parakeet-tdt-0.6b-v3"])
        XCTAssertEqual(snap.cleanup.entries, ["Apple Native", "Qwen3.8-27B-4bit"])
        XCTAssertFalse(snap.speech.entries.contains("MarkItDown"), "a markitdown model is in neither list")
        XCTAssertFalse(snap.speechIsApple)
    }

    /// Speech and cleanup are independent: any mix works, and the menu reads
    /// each route's own choice.
    func testAnyMixOfAppleAndServiceIsShownPerRoute() async {
        var s = EndpointSettings(address: "http://127.0.0.1:1234/v1", speechModel: "whisper-large-v3-8bit",
                                 cleanupModel: "", useCustomSpeech: true, useCustomCleanup: false)
        s.language = EndpointSettings.deviceLanguage
        store.save(s)
        let caller = Caller()
        caller.answer(.success([ModelEntry(id: "whisper-large-v3-8bit", modelType: "audio_stt"),
                                ModelEntry(id: "Qwen3.8-27B-4bit", modelType: "vlm")]))
        let models = makeStore(caller)
        models.refreshIfUseful()
        await waitUntil { !models.speechModels.isEmpty }
        let snap = models.snapshot()
        XCTAssertFalse(snap.speechIsApple)
        XCTAssertTrue(snap.cleanupIsApple, "cleanup is on Apple Native while speech is on the service")
        XCTAssertEqual(snap.cleanup.entries, ["Apple Native", "Qwen3.8-27B-4bit"],
                       "the cleanup list still shows what the server has")
    }

    func testAChosenModelTheServerStoppedListingStaysWithANote() async {
        var s = EndpointSettings(address: "http://127.0.0.1:1234/v1", speechModel: "old-whisper",
                                 cleanupModel: "", useCustomSpeech: true)
        s.language = EndpointSettings.deviceLanguage
        store.save(s)
        let caller = Caller()
        caller.answer(.success([ModelEntry(id: "whisper-large-v3-8bit", modelType: "audio_stt")]))
        let models = makeStore(caller)
        models.refreshIfUseful()
        await waitUntil { !models.speechModels.isEmpty }
        let snap = models.snapshot()
        XCTAssertEqual(snap.speech.entries.last, "old-whisper", "the choice stays, never silently swapped")
        XCTAssertEqual(snap.speech.missingChoice, "old-whisper")
    }

    func testAnUnreachableServerKeepsTheLastKnownListAndSaysSo() async {
        var s = EndpointSettings(address: "http://127.0.0.1:1234/v1", speechModel: "whisper-large-v3-8bit",
                                 useCustomSpeech: true)
        s.language = EndpointSettings.deviceLanguage
        store.save(s)
        let caller = Caller()
        caller.answer(.success([ModelEntry(id: "whisper-large-v3-8bit", modelType: "audio_stt")]))
        let models = makeStore(caller)
        models.refreshIfUseful()
        await waitUntil { !models.speechModels.isEmpty }

        caller.answer(.failure(.notReached("offline")))
        models.refreshIfUseful()
        await waitUntil { models.unreachable }
        let snap = models.snapshot()
        XCTAssertTrue(snap.speech.entries.contains("whisper-large-v3-8bit"),
                      "the last known list is better than an empty menu")
        XCTAssertEqual(snap.speech.entries.first, "Apple Native")
        XCTAssertTrue(snap.speech.unreachable)
    }

    // MARK: - Z2: the answer reaches the menu

    func testTheStoreTellsTheAppWhenARefreshSettles() async {
        var s = EndpointSettings(address: "http://127.0.0.1:1234/v1", speechModel: "w", useCustomSpeech: true)
        s.language = EndpointSettings.deviceLanguage
        store.save(s)
        let caller = Caller()
        caller.setDelay(0.2)
        caller.answer(.success([ModelEntry(id: "w", modelType: "audio_stt")]))
        let models = makeStore(caller)
        var landed = 0
        models.onRefreshFinished = { landed += 1 }
        models.refreshIfUseful()
        XCTAssertEqual(landed, 0, "nothing has come back yet")
        await waitUntil { landed == 1 }
        XCTAssertEqual(models.speechModels, ["w"])
    }

    func testAFailedRefreshAlsoTellsTheApp() async {
        var s = EndpointSettings(address: "http://127.0.0.1:1234/v1", speechModel: "w", useCustomSpeech: true)
        s.language = EndpointSettings.deviceLanguage
        store.save(s)
        let caller = Caller()
        caller.answer(.failure(.notReached("offline")))
        let models = makeStore(caller)
        var landed = 0
        models.onRefreshFinished = { landed += 1 }
        models.refreshIfUseful()
        await waitUntil { landed == 1 }
        XCTAssertTrue(models.unreachable)
    }

    /// Before any answer, the menu says it is checking. It must never claim the
    /// server lists no speech models, which is what a first launch showed.
    func testBeforeAnyAnswerTheRouteIsCheckingNotEmpty() async {
        var s = EndpointSettings(address: "http://127.0.0.1:1234/v1", speechModel: "", useCustomSpeech: false)
        s.language = EndpointSettings.deviceLanguage
        store.save(s)
        let caller = Caller()
        caller.setDelay(0.5)
        caller.answer(.success([ModelEntry(id: "w", modelType: "audio_stt")]))
        let models = makeStore(caller)
        models.refreshIfUseful()
        let snap = models.snapshot()
        XCTAssertTrue(snap.speech.checking, "a refresh is out and nothing is known")
        XCTAssertTrue(snap.cleanup.checking)
        XCTAssertFalse(models.unreachable, "checking is not the same as unreachable")
        await waitUntil { !models.speechModels.isEmpty }
        let after = models.snapshot()
        XCTAssertFalse(after.speech.checking, "the answer landed, so it is no longer checking")
        XCTAssertEqual(after.speech.entries, ["Apple Native", "w"])
    }

    /// Z3: a refused key is not an unreachable server. The menu says which.
    func testARefusedKeyIsNamedAsItsOwnProblem() async {
        var s = EndpointSettings(address: "http://127.0.0.1:1234/v1", speechModel: "w", useCustomSpeech: true)
        s.language = EndpointSettings.deviceLanguage
        store.save(s)
        let caller = Caller()
        caller.answer(.failure(.unauthorized))
        let models = makeStore(caller)
        models.refreshIfUseful()
        await waitUntil { models.lastFailure != nil }
        let snap = models.snapshot()
        XCTAssertTrue(snap.speech.keyRefused, "the menu must say the key was refused")
        XCTAssertFalse(snap.speech.unreachable, "the server answered; it was the key")
        XCTAssertFalse(snap.speech.checking)
    }

    func testAnUnreachableServerIsNotReportedAsARefusedKey() async {
        var s = EndpointSettings(address: "http://127.0.0.1:1234/v1", speechModel: "w", useCustomSpeech: true)
        s.language = EndpointSettings.deviceLanguage
        store.save(s)
        let caller = Caller()
        caller.answer(.failure(.notReached("offline")))
        let models = makeStore(caller)
        models.refreshIfUseful()
        await waitUntil { models.unreachable }
        XCTAssertFalse(models.snapshot().speech.keyRefused)
    }

    // MARK: - Y4: freshness without waiting

    func testTheMenuNeverWaitsForTheServer() async {
        var s = EndpointSettings(address: "http://127.0.0.1:1234/v1", speechModel: "w", useCustomSpeech: true)
        s.language = EndpointSettings.deviceLanguage
        store.save(s)
        let caller = Caller()
        caller.setDelay(2.0)                       // a slow server
        caller.answer(.success([ModelEntry(id: "w", modelType: "audio_stt")]))
        let models = makeStore(caller)
        let started = Date()
        models.refreshIfUseful()                   // a window or the launch refresh
        let snap = models.snapshot()               // and a menu opening right after
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 0.2, "the menu opened at once, without waiting for the server")
        XCTAssertEqual(snap.speech.entries, ["Apple Native", "w"],
                       "nothing is known yet, so the list is Apple Native plus the chosen model")
        XCTAssertEqual(snap.speech.missingChoice, "w", "the chosen model is still shown as chosen")
    }

    func testAnOpenMenuIsNotChangedUnderTheReader() async {
        // The person chooses "w"; the server has "w" and "x". Before the list
        // lands, the menu shows Apple Native and the chosen "w". After it
        // lands, a FRESH menu shows Apple Native, "w" and "x". The menu that
        // was already handed to the reader must keep showing what it showed.
        var s = EndpointSettings(address: "http://127.0.0.1:1234/v1", speechModel: "w", useCustomSpeech: true)
        s.language = EndpointSettings.deviceLanguage
        store.save(s)
        let caller = Caller()
        caller.setDelay(0.4)                         // still in flight when the menu opens
        caller.answer(.success([ModelEntry(id: "w", modelType: "audio_stt"),
                                ModelEntry(id: "x", modelType: "audio_stt")]))
        let models = makeStore(caller)
        models.refreshIfUseful()
        let opened = models.snapshot()               // what the open menu was built from
        XCTAssertEqual(opened.speech.entries, ["Apple Native", "w"])
        await waitUntil { models.speechModels.count == 2 }
        XCTAssertEqual(opened.speech.entries, ["Apple Native", "w"],
                       "a menu already open is never changed under the person reading it")
        XCTAssertEqual(models.snapshot().speech.entries, ["Apple Native", "w", "x"],
                       "the NEXT open sees the new list")
    }

    func testTheRefreshHasAShortLimit() {
        XCTAssertEqual(MenuModelStore.refreshLimit, 3.0, accuracy: 0.001)
    }

    func testASlowServerIsGivenUpOnAtTheLimitAndTheLastListStands() async {
        let saved = MenuModelStore.refreshLimit
        MenuModelStore.refreshLimit = 0.2
        defer { MenuModelStore.refreshLimit = saved }
        var s = EndpointSettings(address: "http://127.0.0.1:1234/v1", speechModel: "w", useCustomSpeech: true)
        s.language = EndpointSettings.deviceLanguage
        store.save(s)
        let caller = Caller()
        caller.answer(.success([ModelEntry(id: "w", modelType: "audio_stt")]))
        let models = makeStore(caller)
        models.refreshIfUseful()
        await waitUntil { !models.speechModels.isEmpty }

        caller.setDelay(5.0)                        // far past the limit
        models.refreshIfUseful()
        await waitUntil { models.unreachable }
        XCTAssertEqual(models.lastFailure, .timedOut)
        XCTAssertEqual(models.speechModels, ["w"], "the timing out server costs its list nothing")
    }

    // MARK: - Y4: the Keychain

    func testTheKeyIsReadOncePerLaunchEvenWithManyMenuOpens() async {
        var s = EndpointSettings(address: "http://127.0.0.1:1234/v1", speechModel: "w", useCustomSpeech: true)
        s.language = EndpointSettings.deviceLanguage
        store.save(s)
        let caller = Caller()
        caller.answer(.success([ModelEntry(id: "w", modelType: "audio_stt")]))
        let models = makeStore(caller)
        for _ in 0..<5 {
            models.refreshIfUseful()
            _ = models.snapshot()
            await waitUntil { !models.speechModels.isEmpty || models.unreachable }
            models.refreshIfUseful()                // the next open
        }
        XCTAssertEqual(secrets.readCount, 1, "opening the menu is no reason to read the Keychain again")
        XCTAssertEqual(caller.seen.first?.key, "k")
    }

    func testAKeyChangeMakesTheNextFetchReadItAgain() async {
        var s = EndpointSettings(address: "http://127.0.0.1:1234/v1", speechModel: "w", useCustomSpeech: true)
        s.language = EndpointSettings.deviceLanguage
        store.save(s)
        let caller = Caller()
        caller.answer(.success([ModelEntry(id: "w", modelType: "audio_stt")]))
        let models = makeStore(caller)
        models.refreshIfUseful()
        await waitUntil { !models.speechModels.isEmpty }
        try? secrets.setSecret("k2")
        models.keyChanged()
        models.refreshIfUseful()
        await waitUntil { caller.seen.count >= 2 }
        XCTAssertEqual(secrets.readCount, 2, "a changed key is read again, once")
        XCTAssertEqual(caller.seen.last?.key, "k2")
        XCTAssertTrue(models.speechModels.isEmpty || caller.seen.count == 2)
    }

    func testChangingTheAddressDropsTheOldServersLists() async {
        var s = EndpointSettings(address: "http://127.0.0.1:1234/v1", speechModel: "w", useCustomSpeech: true)
        s.language = EndpointSettings.deviceLanguage
        store.save(s)
        let caller = Caller()
        caller.answer(.success([ModelEntry(id: "w", modelType: "audio_stt")]))
        let models = makeStore(caller)
        models.refreshIfUseful()
        await waitUntil { !models.speechModels.isEmpty }
        XCTAssertEqual(models.speechModels, ["w"])

        s.address = "http://127.0.0.1:9999/v1"
        store.save(s)
        let caller2Answer = Caller()
        caller2Answer.answer(.success([ModelEntry(id: "other-model", modelType: "vlm")]))
        // Same store object, new address: the next refresh must not keep the old list.
        models.addressChanged()
        XCTAssertEqual(models.speechModels, [], "the old server's models are not this server's models")
    }
}
