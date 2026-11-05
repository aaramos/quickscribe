import XCTest
@testable import QuickScribeCore

/// The store keeps address and model names in preferences and the API key only
/// in the secret store (the app uses the Keychain; the in-memory store stands
/// in here). The key must never appear in the preference values.
final class EndpointSettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "qs-store-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testDefaultIsAppleWithNoAddress() {
        let store = EndpointSettingsStore(defaults: defaults, secrets: MemorySecrets.Store())
        let s = store.load()
        XCTAssertEqual(s.address, "")
        XCTAssertFalse(s.isEnabled)
        XCTAssertFalse(s.speechUsesEndpoint)
        XCTAssertFalse(s.cleanupUsesEndpoint)
    }

    func testRoundTripOfAddressModelsAndChoices() throws {
        let store = EndpointSettingsStore(defaults: defaults, secrets: MemorySecrets.Store())
        var s = EndpointSettings(address: "http://127.0.0.1:1234/v1", speechModel: "whisper-large",
                                 cleanupModel: "qwen-tidy",
                                 useCustomSpeech: true, useCustomCleanup: false)
        s.language = EndpointSettings.deviceLanguage   // follows the Mac, never stored
        store.save(s)
        let loaded = store.load()
        XCTAssertEqual(loaded, s)
        XCTAssertTrue(loaded.speechUsesEndpoint)
        XCTAssertFalse(loaded.cleanupUsesEndpoint)   // chosen Apple even with an address set
        s.useCustomCleanup = true
        store.save(s)
        XCTAssertTrue(store.load().cleanupUsesEndpoint)
    }

    func testEmptyAddressMeansAppleEvenWhenCustomWasChosen() {
        let store = EndpointSettingsStore(defaults: defaults, secrets: MemorySecrets.Store())
        store.save(EndpointSettings(address: "", useCustomSpeech: true, useCustomCleanup: true))
        XCTAssertFalse(store.load().speechUsesEndpoint)
        XCTAssertFalse(store.load().cleanupUsesEndpoint)
    }

    func testLanguageFollowsTheMacAndIsNeverPinned() {
        XCTAssertEqual(EndpointSettings().language, EndpointSettings.deviceLanguage)
        let store = EndpointSettingsStore(defaults: defaults, secrets: MemorySecrets.Store())
        var s = EndpointSettings(address: "http://127.0.0.1:1234/v1")
        s.language = "zz"            // even if something sets another language and saves,
        store.save(s)
        XCTAssertEqual(store.load().language, EndpointSettings.deviceLanguage,
                       "a stored language would go stale when the Mac's language changes")
    }

    func testAPIKeyLivesOnlyInTheSecretStore() throws {
        let secrets = MemorySecrets.Store()
        let store = EndpointSettingsStore(defaults: defaults, secrets: secrets)
        try store.setAPIKey("sk-super-secret-value")
        XCTAssertEqual(store.apiKey(), "sk-super-secret-value")
        // Nothing key-shaped reached the preference values.
        let dumped = defaults.dictionaryRepresentation().description
        XCTAssertFalse(dumped.contains("sk-super-secret-value"), "the API key must never be in preferences")
        // And clearing works.
        try store.setAPIKey("")
        XCTAssertNil(store.apiKey())
    }
}
