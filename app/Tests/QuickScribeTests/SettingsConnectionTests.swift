import AppKit
import XCTest
@testable import QuickScribe
import QuickScribeCore

/// Drives the real Settings window's Inference server section: fields persist,
/// the key lands in the secret store only, the warning reacts, and Test
/// Connection reports what the service offers. Model choice itself lives in the
/// menu bar, so there are no model controls on this page any more.
@MainActor
final class SettingsConnectionTests: XCTestCase {
    private var service: FakeService!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var secrets: MemorySecrets.Store!
    private var library: PromptLibrary!
    private var settings: SettingsWindow!

    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { all(type, in: $0) } + ((view as? T).map { [$0] } ?? [])
    }

    override func setUpWithError() throws {
        service = try FakeService()
        try service.start()
        service.queue(FakeService.Rule(body: Data(#"""
        {"data":[{"id":"whisper-x","model_type":"audio_stt"},
                 {"id":"tidy-y","model_type":"llm"},
                 {"id":"embed-z","model_type":"embedding"}]}
        """#.utf8)), forPath: "/v1/models")
        suiteName = "qs-settings-conn-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        secrets = MemorySecrets.Store()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("prompts.json")
        library = PromptLibrary(fileURL: url)
        settings = SettingsWindow(library: library, endpointStore: EndpointSettingsStore(defaults: defaults, secrets: secrets))
        settings.show()
    }

    override func tearDown() {
        settings.window?.close()
        settings = nil
        defaults.removePersistentDomain(forName: suiteName)
        service.stop()
    }

    private var root: NSView { settings.window!.contentView! }
    private var addressField: NSTextField { all(NSTextField.self, in: root).first { $0.placeholderString == "http://192.168.1.20:1234/v1" }! }
    private var keyField: NSTextField { all(NSSecureTextField.self, in: root).first! }
    private var testButton: NSButton { all(NSButton.self, in: root).first { $0.title == "Test Connection" }! }

    private func commit(_ control: NSControl) {
        control.sendAction(control.action!, to: control.target)
    }

    /// No model controls on this page: the three submenus in the menu bar own
    /// that choice now.
    func testThePageHasNoSpeechOrCleanupModelControls() {
        XCTAssertTrue(all(NSPopUpButton.self, in: root).isEmpty, "the Speech and Cleanup pickers are gone")
        XCTAssertTrue(all(NSComboBox.self, in: root).isEmpty, "the model name boxes are gone")
        XCTAssertTrue(all(NSTextField.self, in: root).contains { $0.stringValue == "Inference server" },
                      "the section is named Inference server")
        XCTAssertFalse(all(NSTextField.self, in: root).contains { $0.stringValue == "Custom service" })
        XCTAssertTrue(all(NSTextField.self, in: root).contains {
            $0.stringValue.contains("Leave the address empty to use Apple Native only. Choose your models from the menu bar icon.")
        }, "the line that says where models are chosen")
    }

    func testAddressPersistsAndTheChangeIsAnnounced() throws {
        var announced: [(Bool, Bool)] = []
        settings.onConnectionChanged = { announced.append(($0, $1)) }
        addressField.stringValue = service.baseURL
        commit(addressField)
        XCTAssertEqual(defaults.string(forKey: "endpoint.address"), service.baseURL)
        XCTAssertEqual(announced.count, 1)
        XCTAssertEqual(announced.first?.0, true, "the address really changed, so the old model list is dropped")
    }

    func testSavingAnUnchangedAddressIsNotAChange() throws {
        addressField.stringValue = service.baseURL
        commit(addressField)
        var announced: [(Bool, Bool)] = []
        settings.onConnectionChanged = { announced.append(($0, $1)) }
        commit(addressField)                     // same address again
        XCTAssertEqual(announced.first?.0, false, "no new address, so the list is not thrown away")
    }

    /// Z3: the real first-time order. The address is typed first, which reads
    /// the key once and finds none; the key is typed second, and the next fetch
    /// must carry it. Before this fix the second step was reported as no change,
    /// so a key-protected server listed no models until the app restarted.
    func testTheKeyTypedAfterTheAddressIsReportedAsAChange() throws {
        var announced: [(Bool, Bool)] = []
        settings.onConnectionChanged = { announced.append(($0, $1)) }

        addressField.stringValue = service.baseURL
        commit(addressField)
        XCTAssertEqual(announced.last?.0, true, "the address changed")
        XCTAssertEqual(announced.last?.1, false, "no key was typed yet")

        keyField.stringValue = "sk-first-key"
        commit(keyField)
        XCTAssertEqual(announced.last?.0, false, "the address did not change")
        XCTAssertEqual(announced.last?.1, true, "the key did change: the fetch must use it")
    }

    func testReplacingTheKeyIsAChangeAndSavingTheSameKeyIsNot() throws {
        keyField.stringValue = "sk-one"
        commit(keyField)
        var announced: [(Bool, Bool)] = []
        settings.onConnectionChanged = { announced.append(($0, $1)) }
        keyField.stringValue = "sk-two"
        commit(keyField)
        XCTAssertEqual(announced.last?.1, true, "a different key is a change")
        keyField.stringValue = "sk-two"
        commit(keyField)
        XCTAssertEqual(announced.last?.1, false, "the same key again is not")
        keyField.stringValue = "   "
        commit(keyField)
        XCTAssertEqual(announced.last?.1, true, "clearing the key is a change")
    }

    /// End to end through the menu's own store: address first, then the key,
    /// and the fetch after the key really carries it.
    func testTheModelFetchAfterAKeyTypedLaterUsesThatKey() async throws {
        final class Counter: SecretStoring, @unchecked Sendable {
            private let lock = NSLock()
            private var value: String?
            private var reads = 0
            init(_ v: String? = nil) { value = v }
            func secret() -> String? { lock.lock(); reads += 1; let v = value; lock.unlock(); return v }
            func setSecret(_ v: String?) throws { lock.lock(); value = v; lock.unlock() }
            var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
        }
        let counter = Counter()
        let store = EndpointSettingsStore(defaults: defaults, secrets: counter)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("prompts.json")
        let window = SettingsWindow(library: PromptLibrary(fileURL: url), endpointStore: store)
        window.show()
        defer { window.window?.close() }
        let root = try XCTUnwrap(window.window?.contentView)
        let address = try XCTUnwrap(all(NSTextField.self, in: root).first { $0.placeholderString == "http://192.168.1.20:1234/v1" })
        let key = try XCTUnwrap(all(NSSecureTextField.self, in: root).first)

        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [(String, String?)] = []
            func add(_ settings: EndpointSettings, _ key: String?) { lock.lock(); items.append((settings.address, key)); lock.unlock() }
            var seen: [(String, String?)] { lock.lock(); defer { lock.unlock() }; return items }
        }
        let box = Box()
        let models = MenuModelStore(endpointStore: store) { settings, key in
            box.add(settings, key)
            return .success([ModelEntry(id: "whisper-x", modelType: "audio_stt")])
        }
        window.onConnectionChanged = { addressChanged, keyChanged in
            if addressChanged { models.addressChanged() }
            if keyChanged { models.keyChanged() }
            models.refreshIfUseful()
        }

        address.stringValue = service.baseURL
        address.sendAction(address.action!, to: address.target)
        for _ in 0..<100 where models.speechModels.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(box.seen.count, 1)
        XCTAssertNil(box.seen.first?.1, "no key yet, so the fetch carries none")

        // The promise is about the menu's own fetch: one read per change, not
        // one per menu open. The Settings page's own echo of the key is separate.
        let readsBefore = counter.readCount
        key.stringValue = "sk-late-key"
        key.sendAction(key.action!, to: key.target)
        for _ in 0..<100 where box.seen.count < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(box.seen.count, 2, "a key typed later asks the server again")
        XCTAssertEqual(box.seen.last?.1, "sk-late-key", "and carries the key")
        XCTAssertLessThan(counter.readCount - readsBefore, 6, "a key change does not read per fetch")
        // The promise that matters: opening the menu again does not read it again.
        let readsAfterChange = counter.readCount
        for _ in 0..<4 {
            models.refreshIfUseful()
            try await Task.sleep(nanoseconds: 120_000_000)
        }
        XCTAssertEqual(counter.readCount, readsAfterChange,
                       "four more menu opens, zero more Keychain reads")
    }

    func testKeyGoesToSecretStoreNotPreferences() throws {
        keyField.stringValue = "sk-window-secret"
        commit(keyField)
        XCTAssertEqual(secrets.secret(), "sk-window-secret")
        XCTAssertFalse(defaults.dictionaryRepresentation().description.contains("sk-window-secret"),
                       "the API key must never reach the preference files")
    }

    /// Keys pasted from a chat window carry spaces and line breaks; the
    /// service wants exactly what it handed out.
    func testPastedKeyIsTrimmedBeforeSaving() throws {
        keyField.stringValue = "\n  sk-pasted-key  \t\n"
        commit(keyField)
        XCTAssertEqual(secrets.secret(), "sk-pasted-key")
        // Blank after a space-only paste means cleared, not stored.
        keyField.stringValue = "   \n "
        commit(keyField)
        XCTAssertNil(secrets.secret())
    }

    /// The choices the earlier 2.0 builds saved are carried through: this page
    /// no longer sets them, and saving the address must not wipe them.
    func testModelChoicesSavedByAnEarlierBuildSurvive() throws {
        var saved = EndpointSettings(address: "http://127.0.0.1:1234/v1", speechModel: "whisper-x",
                                     cleanupModel: "tidy-y", useCustomSpeech: true, useCustomCleanup: true)
        saved.language = EndpointSettings.deviceLanguage
        let store = EndpointSettingsStore(defaults: defaults, secrets: secrets)
        store.save(saved)
        settings.window?.close()
        settings = SettingsWindow(library: library, endpointStore: store)
        settings.show()
        addressField.stringValue = "http://127.0.0.1:1234/v1"
        commit(addressField)
        let after = store.load()
        XCTAssertEqual(after.speechModel, "whisper-x", "a saved speech model is not lost by touching the address")
        XCTAssertEqual(after.cleanupModel, "tidy-y")
        XCTAssertTrue(after.useCustomSpeech)
        XCTAssertTrue(after.useCustomCleanup)
    }

    /// Z5(b): a route chosen in the menu bar while Settings is open must
    /// refresh this page, or its "words will leave this Mac" line is stale.
    func testAMenuChoiceRefreshesAnOpenSettingsPage() throws {
        // A non-local address, both routes still Apple: no warning yet.
        addressField.stringValue = "https://some-service.example"
        commit(addressField)
        XCTAssertFalse(all(NSTextField.self, in: root).contains { $0.stringValue.contains("leave this Mac") })

        // The menu bar now switches speech to a server model.
        var s = endpointStore().load()
        s.useCustomSpeech = true
        s.speechModel = "whisper-x"
        endpointStore().save(s)
        settings.connectionChangedOutside()

        XCTAssertTrue(all(NSTextField.self, in: root).contains { $0.stringValue.contains("leave this Mac") },
                      "the warning must appear once a route really sends words")
        XCTAssertEqual(addressField.stringValue, "https://some-service.example",
                       "the page re-reads the saved values without losing the address")
    }

    func testNonLocalAddressShowsTheLeavingWarning() throws {
        var s = endpointStore().load()
        s.useCustomSpeech = true                 // what the menu would set
        endpointStore().save(s)
        settings.window?.close()
        settings = SettingsWindow(library: library, endpointStore: endpointStore())
        settings.show()
        addressField.stringValue = "https://some-service.example"
        commit(addressField)
        let warning = all(NSTextField.self, in: root).first { $0.stringValue.contains("leave this Mac") }
        XCTAssertNotNil(warning, "a non-local address must say on screen that words leave the Mac")
        XCTAssertTrue(warning!.stringValue.contains("some-service.example"))
        XCTAssertFalse(warning!.stringValue.contains("unencrypted"), "https does not add a false warning")
    }

    /// A set address with both routes still on Apple moves nothing.
    func testWarningHiddenWhileBothRoutesStayOnApple() throws {
        addressField.stringValue = "https://some-service.example"
        commit(addressField)
        XCTAssertFalse(all(NSTextField.self, in: root).contains { $0.stringValue.contains("leave this Mac") },
                       "nothing leaves the Mac when neither route is set to Custom")
    }

    func testNonLocalPlainHTTPRefusedOnScreen() throws {
        addressField.stringValue = "http://some-service.example"
        commit(addressField)
        let warning = all(NSTextField.self, in: root).first { $0.stringValue.contains("unencrypted") }
        XCTAssertNotNil(warning, "plain http off the local network is refused with a clear message")
    }

    func testEmptyAddressMeansAppleNoWarning() throws {
        addressField.stringValue = ""
        commit(addressField)
        XCTAssertFalse(all(NSTextField.self, in: root).contains { $0.stringValue.contains("leave this Mac") })
        XCTAssertFalse(EndpointSettingsStore(defaults: defaults, secrets: secrets).load().isEnabled)
    }

    private func endpointStore() -> EndpointSettingsStore {
        EndpointSettingsStore(defaults: defaults, secrets: secrets)
    }

    func testConnectionTestReportsWhatTheServiceOffers() async throws {
        service.queue(FakeService.Rule(body: Data(#"{"text":""}"#.utf8)), forPath: "/v1/audio/transcriptions")
        service.queue(FakeService.Rule(body: Data(
            "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8
        )), forPath: "/v1/chat/completions")
        var s = EndpointSettings(address: service.baseURL, speechModel: "whisper-x", cleanupModel: "tidy-y")
        s.useCustomSpeech = true
        s.useCustomCleanup = true
        let report = await SettingsWindow.runConnectionTest(settings: s, apiKey: "k")
        XCTAssertTrue(report.contains("Connected. 1 speech, 1 clean up model."), report)
        XCTAssertTrue(report.contains("Key accepted"), report)
        XCTAssertTrue(report.contains("Speech works with whisper-x"), report)
        XCTAssertTrue(report.contains("Clean up works with tidy-y"), report)
    }

    /// The counts sentence, on its own: the review's example, the singular
    /// forms, and a service that has nothing usable.
    func testTheCountsLine() {
        let example = ModelCatalog.split((1...5).map { ModelEntry(id: "s\($0)", modelType: "audio_stt") }
                                         + (1...7).map { ModelEntry(id: "c\($0)", modelType: "vlm") })
        XCTAssertEqual(SettingsWindow.modelsLine(example), "Connected. 5 speech, 7 clean up models.")
        XCTAssertEqual(SettingsWindow.modelsLine(ModelCatalog.split([])),
                       "Reached the address, but it lists no speech or clean up models.")
        let one = ModelCatalog.split([ModelEntry(id: "w", modelType: "audio_stt")])
        XCTAssertEqual(SettingsWindow.modelsLine(one), "Connected. 1 speech, 0 clean up models.")
    }

    func testConnectionTestNamesABadKeyPlainly() async throws {
        service.reset(path: "/v1/models")
        service.queue(FakeService.Rule(status: 401, body: Data("{}".utf8)), forPath: "/v1/models")
        let report = await SettingsWindow.runConnectionTest(settings: EndpointSettings(address: service.baseURL), apiKey: "wrong")
        XCTAssertTrue(report.contains("Reached the address"), report)
        XCTAssertTrue(report.contains("refused the key"), report)
        XCTAssertFalse(report.contains("wrong"), "the key value itself never appears in reports")
    }

    /// Test Connection still works with Apple Native chosen for both routes:
    /// it checks the address and the key, and says both routes are Apple's.
    func testConnectionTestWorksWithAppleNativeOnBothRoutes() async throws {
        let report = await SettingsWindow.runConnectionTest(settings: EndpointSettings(address: service.baseURL), apiKey: "k")
        XCTAssertTrue(report.contains("Connected. 1 speech, 1 clean up model."), report)
        XCTAssertTrue(report.contains("Speech: Apple Native is chosen in the menu bar."), report)
        XCTAssertTrue(report.contains("Clean up: Apple Native is chosen in the menu bar."), report)
        XCTAssertFalse(report.contains("not chosen"), "Apple Native is a valid choice, not a missing one")
    }

    /// Layout check: the settings page lives in a scroller, so controls are
    /// judged against the document and must not overlap. A full report must
    /// never push the window past a small screen.
    /// Set QS_SETTINGS_SHOTS to a folder to save a picture.
    func testWindowIsLaidOutCorrectly() throws {
        addressField.stringValue = service.baseURL
        commit(addressField)
        keyField.stringValue = "sk-for-the-photo"
        commit(keyField)
        let win = try! XCTUnwrap(settings.window)
        let scroller = try XCTUnwrap(win.contentView as? NSScrollView)
        let doc = try XCTUnwrap(scroller.documentView)
        let controls: [NSView] = ([addressField, keyField] as [NSTextField]) + [testButton]
        for control in controls {
            let frame = control.convert(control.bounds, to: doc)
            XCTAssertTrue(doc.bounds.contains(frame), "\(type(of: control)) outside the page: \(frame) in \(doc.bounds)")
            XCTAssertGreaterThan(frame.width, 40, "control too narrow: \(frame)")
            XCTAssertGreaterThan(frame.height, 16, "control too short: \(frame)")
        }
        for (i, a) in controls.enumerated() {
            for b in controls.dropFirst(i + 1) {
                let fa = a.convert(a.bounds, to: doc), fb = b.convert(b.bounds, to: doc)
                XCTAssertFalse(fa.intersects(fb), "\(type(of: a)) overlaps \(type(of: b)): \(fa) vs \(fb)")
            }
        }
        let visible = all(NSTextField.self, in: doc).filter { !$0.isHidden }
        XCTAssertTrue(visible.contains { $0.stringValue == "Inference server" }, "heading missing")
        XCTAssertTrue(visible.contains { $0.stringValue.contains("Apple Native only") },
                      "the line telling people where models are chosen is missing")

        let report = all(NSTextField.self, in: doc).first { !$0.isEditable && ($0.font?.fontName.contains("Mono") ?? false) }
        let status = try XCTUnwrap(report, "Test Connection report label not found")
        status.stringValue = """
        Connected. 5 speech, 7 clean up models.
        Key accepted.
        Speech works with whisper-large-v3-8bit.
        Clean up works with Qwen3.8-27B-4bit.
        Your words will leave this Mac and travel to host.example.
        """
        win.layoutIfNeeded()
        XCTAssertLessThanOrEqual(win.frame.height, 760, "window too tall for a 1440x900 screen with a full report")
        let reportFrame = status.convert(status.bounds, to: doc)
        XCTAssertTrue(doc.bounds.contains(reportFrame), "report must be on the page, reachable by scrolling")
        XCTAssertGreaterThan(status.frame.height, 40, "the report label must show all its lines")

        if let folder = ProcessInfo.processInfo.environment["QS_SETTINGS_SHOTS"] {
            guard let rep = doc.bitmapImageRepForCachingDisplay(in: doc.bounds) else { return }
            doc.cacheDisplay(in: doc.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/settings.png"))
        }
    }

    /// The prompt test runs the selected route for real: with cleanup on a
    /// service model (chosen in the menu, saved in settings) the request goes
    /// to that service with its own factory text.
    func testPromptTestSendsToTheSelectedServiceRoute() async throws {
        try secrets.setSecret("k")
        var s = EndpointSettings(address: service.baseURL, speechModel: "whisper-x", cleanupModel: "tidy-y",
                                 useCustomSpeech: true, useCustomCleanup: true)
        s.language = EndpointSettings.deviceLanguage
        endpointStore().save(s)
        settings.window?.close()
        settings = SettingsWindow(library: library, endpointStore: endpointStore())
        settings.show()
        service.queue(FakeService.Rule(status: 401, body: Data("{}".utf8)), forPath: "/v1/chat/completions")

        let root = try XCTUnwrap(settings.window?.contentView)
        let button = try XCTUnwrap(all(NSButton.self, in: root).first { $0.title == "Test Prompt" })
        button.performClick(nil)
        for _ in 0..<200 where !button.isEnabled { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(button.isEnabled, "Test Prompt never finished")
        let output = try XCTUnwrap(all(NSTextView.self, in: root).first { !$0.isEditable })
        XCTAssertTrue(output.string.contains("refused the key"), output.string)

        let chat = try XCTUnwrap(service.received.first { $0.path == "/v1/chat/completions" })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: chat.body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "tidy-y")
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertTrue(messages[0]["content"]!.contains("publication-ready"),
                      "the service route tested its own longer factory set")
    }
}
