import AppKit
import XCTest
@testable import QuickScribe
import QuickScribeCore

/// Drives the real Settings window's Custom service section: fields persist,
/// the key lands in the secret store only, choices and warnings react, and
/// Test Connection reports all four checks against a fake service.
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
        service.queue(FakeService.Rule(body: Data(#"{"data":[{"id":"whisper-x"},{"id":"tidy-y"}]}"#.utf8)), forPath: "/v1/models")
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
    private var combos: [NSComboBox] { all(NSComboBox.self, in: root) }   // speech, cleanup
    private var popups: [NSPopUpButton] { all(NSPopUpButton.self, in: root) }   // speech, cleanup
    private var testButton: NSButton { all(NSButton.self, in: root).first { $0.title == "Test Connection" }! }

    private func commit(_ control: NSControl) {
        control.sendAction(control.action!, to: control.target)
    }

    func testAddressAndModelsPersistAndPickersFill() async throws {
        addressField.stringValue = service.baseURL
        commit(addressField)
        try await Task.sleep(nanoseconds: 400_000_000)   // let GET /models land
        XCTAssertEqual(defaults.string(forKey: "endpoint.address"), service.baseURL)
        XCTAssertTrue(combos[0].objectValues as? [String] == ["tidy-y", "whisper-x"],
                      "both pickers fill from the service: \(combos[0].objectValues ?? [])")
        // Custom choices persist through the controls.
        popups[0].selectItem(at: 1)
        commit(popups[0])
        let store = EndpointSettingsStore(defaults: defaults, secrets: secrets)
        XCTAssertTrue(store.load().speechUsesEndpoint)
        XCTAssertFalse(store.load().cleanupUsesEndpoint)
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

    func testTypedModelSurvivesTheModelListArriving() async throws {
        addressField.stringValue = service.baseURL
        commit(addressField)
        combos[1].stringValue = "my-own-model"
        commit(combos[1])
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(combos[1].stringValue, "my-own-model", "the fetch must not wipe a typed name")
        XCTAssertEqual(defaults.string(forKey: "endpoint.cleanupModel"), "my-own-model")
    }

    func testNonLocalAddressShowsTheLeavingWarning() throws {
        popups[0].selectItem(at: 1)          // Speech set to Custom: words really do leave
        commit(popups[0])
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

    func testConnectionTestReportsFourChecks() async throws {
        service.queue(FakeService.Rule(body: Data(#"{"text":""}"#.utf8)), forPath: "/v1/audio/transcriptions")
        service.queue(FakeService.Rule(body: Data(
            "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8
        )), forPath: "/v1/chat/completions")
        var s = EndpointSettings(address: service.baseURL, speechModel: "whisper-x", cleanupModel: "tidy-y")
        s.useCustomSpeech = true
        s.useCustomCleanup = true
        let report = await SettingsWindow.runConnectionTest(settings: s, apiKey: "k")
        XCTAssertTrue(report.contains("Reached the address"), report)
        XCTAssertTrue(report.contains("2 models"), report)
        XCTAssertTrue(report.contains("Key accepted"), report)
        XCTAssertTrue(report.contains("Speech works"), report)
        XCTAssertTrue(report.contains("Cleanup works"), report)
    }

    func testConnectionTestNamesABadKeyPlainly() async throws {
        service.reset(path: "/v1/models")
        service.queue(FakeService.Rule(status: 401, body: Data("{}".utf8)), forPath: "/v1/models")
        let report = await SettingsWindow.runConnectionTest(settings: EndpointSettings(address: service.baseURL), apiKey: "wrong")
        XCTAssertTrue(report.contains("Reached the address"), report)
        XCTAssertTrue(report.contains("refused the key"), report)
        XCTAssertFalse(report.contains("wrong"), "the key value itself never appears in reports")
    }

    /// Layout check: the settings page lives in a scroller, so controls are
    /// judged against the document, must not overlap, and a full Test
    /// Connection report must never push the window past a small screen.
    /// Set QS_SETTINGS_SHOTS to a folder to save a picture.
    func testWindowIsLaidOutCorrectly() throws {
        addressField.stringValue = service.baseURL
        commit(addressField)
        keyField.stringValue = "sk-for-the-photo"
        commit(keyField)
        speechChoice_selectCustom()
        let win = try! XCTUnwrap(settings.window)
        // The page scrolls: window content is a scroller, controls live in its document.
        let scroller = try XCTUnwrap(win.contentView as? NSScrollView)
        let doc = try XCTUnwrap(scroller.documentView)
        let controls: [NSView] = ([addressField, keyField] as [NSTextField]) + combos + popups + [testButton]
        for control in controls {
            let frame = control.convert(control.bounds, to: doc)
            XCTAssertTrue(doc.bounds.contains(frame), "\(type(of: control)) outside the page: \(frame) in \(doc.bounds)")
            XCTAssertGreaterThan(frame.width, 40, "control too narrow: \(frame)")
            XCTAssertGreaterThan(frame.height, 16, "control too short: \(frame)")
        }
        // Neighbours must not sit on top of each other.
        for (i, a) in controls.enumerated() {
            for b in controls.dropFirst(i + 1) {
                let fa = a.convert(a.bounds, to: doc), fb = b.convert(b.bounds, to: doc)
                XCTAssertFalse(fa.intersects(fb), "\(type(of: a)) overlaps \(type(of: b)): \(fa) vs \(fb)")
            }
        }
        // The section headings and notes are drawn on the page.
        let visible = all(NSTextField.self, in: doc).filter { !$0.isHidden }
        XCTAssertTrue(visible.contains { $0.stringValue == "Custom service" }, "heading missing")
        XCTAssertTrue(visible.contains { $0.stringValue.contains("Apple's on-device models") }, "default explanation missing")

        // A full four-line report must not grow the window past a small screen:
        // 1440x900 leaves about 800 visible points. Height stays fixed, the page scrolls.
        let report = all(NSTextField.self, in: doc).first { !$0.isEditable && ($0.font?.fontName.contains("Mono") ?? false) }
        let status = try XCTUnwrap(report, "Test Connection report label not found")
        status.stringValue = """
        Reached the address. It has 18 models.
        Key accepted.
        Speech works (whisper).
        Cleanup works (tidy).
        Your words will leave this Mac and travel to host.example.
        """
        win.layoutIfNeeded()
        XCTAssertLessThanOrEqual(win.frame.height, 760, "window too tall for a 1440x900 screen with a full report")
        let reportFrame = status.convert(status.bounds, to: doc)
        XCTAssertTrue(doc.bounds.contains(reportFrame), "report must be on the page, reachable by scrolling")
        XCTAssertGreaterThan(status.frame.height, 40, "the report label must show all its lines")

        if let folder = ProcessInfo.processInfo.environment["QS_SETTINGS_SHOTS"] {
            // A photo of the whole page, not just the visible part.
            guard let rep = doc.bitmapImageRepForCachingDisplay(in: doc.bounds) else { return }
            doc.cacheDisplay(in: doc.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/settings.png"))
        }
    }

    private func speechChoice_selectCustom() {
        popups[0].selectItem(at: 1)
        commit(popups[0])
    }
    /// The prompt test runs the selected route for real: with Cleanup set to
    /// Custom the request goes to the service with the service's own factory
    /// text, and a wrong key answers with its plain sentence on screen.
    func testPromptTestSendsToTheSelectedServiceRoute() async throws {
        try secrets.setSecret("k")
        addressField.stringValue = service.baseURL
        commit(addressField)
        popups[1].selectItem(at: 1)              // Cleanup: Custom service
        commit(popups[1])
        combos[1].stringValue = "tidy-y"
        commit(combos[1])
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
