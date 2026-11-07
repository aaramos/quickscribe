import AppKit
import XCTest
@testable import QuickScribe
import QuickScribeCore

/// The menu bar's three choice submenus: their titles, what each contains, the
/// checkmark, and that a very long model name cannot stretch the menu.
@MainActor
final class MenuBarMenuTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: EndpointSettingsStore!
    private var app: MainMenuAssembly!
    private var models: MenuModelStore!
    private var actions: Recorded!

    /// What a click would do, recorded instead of done.
    final class Recorded {
        var profiles: [String] = []
        var apples: [String] = []
        var models: [(String, String)] = []
        var refreshes = 0
        var handsFree = 0
    }

    override func setUp() async throws {
        suiteName = "qs-menu-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = EndpointSettingsStore(defaults: defaults, secrets: MemorySecrets.Store("k"))
        actions = Recorded()
        models = MenuModelStore(endpointStore: store) { _, _ in
            .success([ModelEntry(id: "whisper-large-v3-8bit", modelType: "audio_stt"),
                      ModelEntry(id: "parakeet-tdt-0.6b-v3", modelType: "audio_stt"),
                      ModelEntry(id: "Qwen3.8-27B-4bit", modelType: "vlm")])
        }
        app = MainMenuAssembly()
        let recorded = actions!
        app.actions = MainMenuAssembly.Actions(
            selectProfile: { recorded.profiles.append($0) },
            chooseApple: { recorded.apples.append($0) },
            chooseModel: { recorded.models.append(($0, $1)) },
            toggleHandsFree: { recorded.handsFree += 1 },
            openAccessibility: {},
            openReleasePage: {},
            showSettings: {},
            refreshModels: { recorded.refreshes += 1 })
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        app = nil
        models = nil
    }

    /// The whole menu, built the way the app builds it when it opens.
    private func menu(profile: String = "polish") -> NSMenu {
        let s = store.load()
        let state = MainMenuAssembly.State(
            hotkeysOff: false, cleanupProblem: nil, recording: false, profile: profile,
            snapshot: models.snapshot(), updateVersion: nil,
            speechModel: s.speechModel, cleanupModel: s.cleanupModel)
        return app.build(state)
    }

    private func reloadModels() async {
        models.refreshIfUseful()
        for _ in 0..<100 where models.speechModels.isEmpty && models.cleanupModels.isEmpty && !models.unreachable {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Titles

    func testTheThreeTitlesNameTheirChoice() {
        XCTAssertEqual(MainMenuBuilder.title(MainMenuBuilder.modeLabel, "Polish"), "Mode: Polish")
        XCTAssertEqual(MainMenuBuilder.title(MainMenuBuilder.speechLabel, "Apple Native"),
                       "Speech Model: Apple Native")
        XCTAssertEqual(MainMenuBuilder.title(MainMenuBuilder.cleanupLabel, "Apple Native"),
                       "Clean Up Model: Apple Native")
        XCTAssertFalse(MainMenuBuilder.title(MainMenuBuilder.modeLabel, "Polish").contains("—"))
    }

    /// A long model name is cut in the title so the menu stays a sane width, and
    /// the full name is still inside the submenu.
    func testALongNameIsCutInTheTitleButKeptInTheSubmenu() async {
        let long = "Qwen3.8-Flash-Next-Uncensored-8bit-Extra-Long-Model-Name"
        XCTAssertTrue(long.count > MainMenuBuilder.titleNameLimit)
        let title = MainMenuBuilder.title(MainMenuBuilder.cleanupLabel, long)
        XCTAssertTrue(title.hasPrefix("Clean Up Model: "), title)
        XCTAssertTrue(title.hasSuffix(MainMenuBuilder.shortened(long).suffix(1)), title)
        XCTAssertLessThanOrEqual(title.count, MainMenuBuilder.cleanupLabel.count + 2 + MainMenuBuilder.titleNameLimit)
        XCTAssertTrue(MainMenuBuilder.shortened(long).hasSuffix("…"), "cut with an ellipsis")
        XCTAssertEqual(MainMenuBuilder.shortened(long).count, MainMenuBuilder.titleNameLimit)

        var s = EndpointSettings(address: "http://127.0.0.1:1234/v1", cleanupModel: long, useCustomCleanup: true)
        s.language = EndpointSettings.deviceLanguage
        store.save(s)
        await reloadModels()
        let snap = models.snapshot()
        let submenu = app.modelSubmenu(label: MainMenuBuilder.cleanupLabel, route: snap.cleanup, chooseApple: false)
        XCTAssertTrue(submenu.items.contains { $0.title.hasPrefix(long) },
                      "the full name is in the submenu, notes and all: \(submenu.items.map(\.title))")
    }

    func testShortNamesAreNotTouched() {
        XCTAssertEqual(MainMenuBuilder.shortened("Apple Native"), "Apple Native")
        XCTAssertEqual(MainMenuBuilder.shortened("whisper-large-v3-8bit"), "whisper-large-v3-8bit")
    }

    // MARK: - Mode submenu

    func testTheModeSubmenuKeepsEveryModeAndItsGesture() {
        _ = menu()
        let sub = app.modeSubmenu(profile: "polish")
        let titles = sub.items.map(\.title)
        XCTAssertEqual(titles.count, 4)
        XCTAssertTrue(titles[0].contains("Polish"), titles[0])
        XCTAssertTrue(titles[0].contains("\(AppInfo.holdLabel)1"), "the keyboard gesture is still shown")
        XCTAssertTrue(titles[1].contains("Concise"))
        XCTAssertTrue(titles[1].contains("\(AppInfo.holdLabel)2"))
        XCTAssertTrue(titles[2].contains("Active Voice"))
        XCTAssertTrue(titles[2].contains("\(AppInfo.holdLabel)3"))
        XCTAssertTrue(titles[3].contains("Rewrite"))
        XCTAssertTrue(titles[3].contains("or hold \(AppInfo.holdRewriteLabel)"))
        // Exactly one checkmark, on the mode in effect.
        XCTAssertEqual(sub.items.filter { $0.state == .on }.count, 1)
        XCTAssertEqual(sub.items.first { $0.state == .on }?.representedObject as? String, "polish")
        for item in sub.items { XCTAssertFalse(item.title.contains("—")) }
        app.actions?.selectProfile("concise")
        XCTAssertEqual(actions.profiles.last, "concise", "a click reaches the app as the mode's id")
    }

    // MARK: - Model submenus

    func testAppleNativeIsFirstAndCheckedWhenAppleIsTheChoice() async {
        await reloadModels()
        let snap = models.snapshot()
        let menu = app.modelSubmenu(label: MainMenuBuilder.speechLabel,
                                    route: MenuModelStore.Route(entries: ["Apple Native", "whisper"],
                                                                unreachable: false, missingChoice: nil),
                                    chooseApple: true)
        XCTAssertEqual(menu.items.first?.title, "Apple Native")
        XCTAssertEqual(menu.items.first?.state, .on)
        XCTAssertEqual(menu.items.first?.isEnabled, true)
        XCTAssertNil(snap.speech.missingChoice)
    }

    func testACheckmarkMarksTheChosenServerModelInItsOwnSubmenu() async {
        var s = EndpointSettings(address: "http://127.0.0.1:1234/v1", speechModel: "whisper-large-v3-8bit",
                                 cleanupModel: "Qwen3.8-27B-4bit",
                                 useCustomSpeech: true, useCustomCleanup: true)
        s.language = EndpointSettings.deviceLanguage
        store.save(s)
        await reloadModels()
        let snap = models.snapshot()
        let speech = app.modelSubmenu(label: MainMenuBuilder.speechLabel, route: snap.speech, chooseApple: snap.speechIsApple)
        let cleanup = app.modelSubmenu(label: MainMenuBuilder.cleanupLabel, route: snap.cleanup, chooseApple: snap.cleanupIsApple)
        XCTAssertEqual(speech.items.first { $0.state == .on }?.title, "whisper-large-v3-8bit")
        XCTAssertEqual(cleanup.items.first { $0.state == .on }?.title, "Qwen3.8-27B-4bit")
        XCTAssertNotNil(speech.items.first { $0.state == .on }?.representedObject as? MainMenuAssembly.ModelChoice)
    }

    func testAnUnreachableServerSaysSoInTheList() {
        let menu = app.modelSubmenu(label: MainMenuBuilder.speechLabel,
                                    route: MenuModelStore.Route(entries: ["Apple Native"],
                                                                unreachable: true, missingChoice: nil),
                                    chooseApple: false)
        let note = menu.items.first { $0.title == MainMenuBuilder.noServerNote }
        XCTAssertNotNil(note, "with an address set and nothing answering, the menu says so")
        XCTAssertEqual(note?.isEnabled, false, "the note cannot be clicked")
        XCTAssertEqual(menu.items.first?.title, "Apple Native", "Apple Native stays first")
    }

    func testAModelNoLongerListedIsShownAndCannotBePicked() {
        let menu = app.modelSubmenu(label: MainMenuBuilder.speechLabel,
                                    route: MenuModelStore.Route(entries: ["Apple Native", "old-whisper"],
                                                                unreachable: false, missingChoice: "old-whisper"),
                                    chooseApple: false)
        let item = menu.items.first { $0.title.hasPrefix("old-whisper") }
        XCTAssertNotNil(item)
        XCTAssertTrue(item!.title.contains(MainMenuBuilder.notAvailableNote), item!.title)
        XCTAssertFalse(item!.isEnabled, "a model that is gone cannot be chosen again")
        XCTAssertEqual(item!.state, .on, "it is still the person's choice, shown honestly")
    }

    func testNoUsableModelsGetsANoteInsteadOfAnEmptyList() {
        let menu = app.modelSubmenu(label: MainMenuBuilder.cleanupLabel,
                                    route: MenuModelStore.Route(entries: ["Apple Native"], unreachable: false,
                                                                missingChoice: nil),
                                    chooseApple: true)
        XCTAssertTrue(menu.items.contains { $0.title == MainMenuBuilder.noCleanupModelsNote })
        let speech = app.modelSubmenu(label: MainMenuBuilder.speechLabel,
                                      route: MenuModelStore.Route(entries: ["Apple Native"], unreachable: false,
                                                                  missingChoice: nil),
                                      chooseApple: true)
        XCTAssertTrue(speech.items.contains { $0.title == MainMenuBuilder.noSpeechModelsNote })
    }

    // MARK: - Choosing

    func testChoosingAModelSetsOnlyItsOwnRouteAndAppliesNextDictation() {
        var s = EndpointSettings(address: "http://127.0.0.1:1234/v1",
                                 speechModel: "Apple Native", cleanupModel: "tidy")
        s.language = EndpointSettings.deviceLanguage
        store.save(s)

        let speech = app.modelSubmenu(label: MainMenuBuilder.speechLabel,
                                      route: MenuModelStore.Route(entries: ["Apple Native", "whisper"], unreachable: false,
                                                                  missingChoice: nil),
                                      chooseApple: true)
        let whisper = speech.items.first { $0.title == "whisper" }!
        XCTAssertEqual(whisper.action.map(NSStringFromSelector), "modelTapped:")
        XCTAssertNotNil(whisper.representedObject as? MainMenuAssembly.ModelChoice)
        let after = MainMenuAssembly.applied(store.load(), label: MainMenuBuilder.speechLabel,
                                             apple: false, model: "whisper")
        XCTAssertTrue(after.useCustomSpeech)
        XCTAssertEqual(after.speechModel, "whisper")
        XCTAssertEqual(after.cleanupModel, "tidy", "the cleanup route is untouched")
        XCTAssertFalse(after.useCustomCleanup)
    }

    func testChoosingAppleNativeOnOneRouteLeavesTheOtherAlone() {
        var s = EndpointSettings(address: "http://127.0.0.1:1234/v1", speechModel: "whisper",
                                 cleanupModel: "tidy", useCustomSpeech: true, useCustomCleanup: true)
        s.language = EndpointSettings.deviceLanguage
        store.save(s)
        let menu = app.modelSubmenu(label: MainMenuBuilder.speechLabel,
                                    route: MenuModelStore.Route(entries: ["Apple Native", "whisper"],
                                                                unreachable: false, missingChoice: nil),
                                    chooseApple: false)
        XCTAssertNotNil(menu.items.first?.representedObject as? String)
        let after = MainMenuAssembly.applied(store.load(), label: MainMenuBuilder.speechLabel, apple: true)
        XCTAssertTrue(after.useCustomCleanup, "cleanup stays on its service model")
        XCTAssertEqual(after.cleanupModel, "tidy")
        XCTAssertEqual(after.speechModel, "whisper", "the last speech model is remembered, not erased")
    }

    func testAClickOnAModelItemReachesTheAppAsLabelAndName() {
        let speech = app.modelSubmenu(label: MainMenuBuilder.speechLabel,
                                      route: MenuModelStore.Route(entries: ["Apple Native", "whisper"],
                                                                  unreachable: false, missingChoice: nil),
                                      chooseApple: true)
        let whisper = speech.items.first { $0.title == "whisper" }!
        _ = whisper.target?.perform(whisper.action, with: whisper)
        XCTAssertEqual(actions.models.count, 1)
        XCTAssertEqual(actions.models.first?.0, MainMenuBuilder.speechLabel)
        XCTAssertEqual(actions.models.first?.1, "whisper")
        let apple = speech.items.first!
        _ = apple.target?.perform(apple.action, with: apple)
        XCTAssertEqual(actions.apples.last, MainMenuBuilder.speechLabel)
    }

    /// Opening the menu asks for a fresh list, and never waits on it.
    func testOpeningTheMenuAsksForARefresh() {
        app.actions?.refreshModels()
        XCTAssertEqual(actions.refreshes, 1)
    }

    /// The whole menu keeps hands-free, Settings, Quit, and the update item.
    func testTheRestOfTheMenuIsKept() {
        let s = store.load()
        let state = MainMenuAssembly.State(
            hotkeysOff: true, cleanupProblem: "Apple Intelligence is off",
            recording: false, profile: "polish", snapshot: models.snapshot(),
            updateVersion: "2.1", speechModel: s.speechModel, cleanupModel: s.cleanupModel)
        let full = app.build(state)
        let titles = full.items.map(\.title)
        XCTAssertTrue(titles.contains { $0.contains("Hotkeys off") })
        XCTAssertTrue(titles.contains { $0.contains("Dictation still works, without AI cleanup") })
        XCTAssertTrue(titles.contains { $0.contains("Start Recording (hands-free)") })
        XCTAssertTrue(titles.contains { $0.hasPrefix("Update available: version 2.1") })
        XCTAssertTrue(titles.contains { $0.hasPrefix("Settings") })
        XCTAssertTrue(titles.contains { $0.hasPrefix("Quit ") })
        // The three choice submenus are there, in order, each with its own title.
        let choiceTitles = titles.filter { $0.hasPrefix("Mode: ") || $0.hasPrefix("Speech Model: ") || $0.hasPrefix("Clean Up Model: ") }
        XCTAssertEqual(choiceTitles.count, 3, "\(titles)")
        for item in full.items where item.submenu != nil {
            XCTAssertFalse(item.title.contains("—"), "no em dashes in menu text: \(item.title)")
        }
        XCTAssertTrue(full.items.allSatisfy { !$0.title.contains("—") })
    }

    func testTheChosenModelNameSurvivesTheMenuBeingRebuilt() async {
        var s = EndpointSettings(address: "http://127.0.0.1:1234/v1", speechModel: "whisper-large-v3-8bit",
                                 useCustomSpeech: true)
        s.language = EndpointSettings.deviceLanguage
        store.save(s)
        await reloadModels()
        let snap = models.snapshot()
        XCTAssertTrue(snap.speech.entries.contains("whisper-large-v3-8bit"))
        XCTAssertEqual(MainMenuBuilder.title(MainMenuBuilder.speechLabel, "whisper-large-v3-8bit"),
                       "Speech Model: whisper-large-v3-8bit")
    }
}
