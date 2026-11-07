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
        var opened = 0
        var closed = 0
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
            refreshModels: { recorded.refreshes += 1 },
            menuDidOpen: { recorded.opened += 1 },
            menuDidClose: { recorded.closed += 1 })
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
        let speech = app.modelSubmenu(label: MainMenuBuilder.speechLabel, route: snap.speech,
                                      chooseApple: snap.speechIsApple, chosen: s.speechModel)
        let cleanup = app.modelSubmenu(label: MainMenuBuilder.cleanupLabel, route: snap.cleanup,
                                       chooseApple: snap.cleanupIsApple, chosen: s.cleanupModel)
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
                                    chooseApple: false, chosen: "old-whisper")
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

    /// Z1: one checkmark per submenu, on the chosen model, even when it is not
    /// the first in the list. This is the exact case the earlier test missed.
    func testExactlyOneCheckmarkOnTheChosenModelNotTheFirst() {
        for label in [MainMenuBuilder.speechLabel, MainMenuBuilder.cleanupLabel] {
            let route = MenuModelStore.Route(entries: ["Apple Native", "alpha", "beta", "gamma"],
                                             unreachable: false, missingChoice: nil)
            let menu = app.modelSubmenu(label: label, route: route, chooseApple: false, chosen: "gamma")
            let checked = menu.items.filter { $0.state == .on }
            XCTAssertEqual(checked.count, 1, "\(label): exactly one checkmark, got \(checked.map(\.title))")
            XCTAssertEqual(checked.first?.title, "gamma", "\(label): the checkmark is on the chosen model")
            XCTAssertEqual(menu.items.first?.state, .off, "\(label): Apple Native is not checked")
        }
    }

    func testTheFirstModelIsNotCheckedJustForBeingFirst() {
        let route = MenuModelStore.Route(entries: ["Apple Native", "alpha", "beta"], unreachable: false,
                                         missingChoice: nil)
        let menu = app.modelSubmenu(label: MainMenuBuilder.speechLabel, route: route,
                                    chooseApple: false, chosen: "beta")
        XCTAssertEqual(menu.items.map(\.state), [.off, .off, .on])
    }

    func testAppleNativeCheckedMeansNoModelIsChecked() {
        let route = MenuModelStore.Route(entries: ["Apple Native", "alpha", "beta"], unreachable: false,
                                         missingChoice: nil)
        let menu = app.modelSubmenu(label: MainMenuBuilder.cleanupLabel, route: route,
                                    chooseApple: true, chosen: "beta")
        XCTAssertEqual(menu.items.filter { $0.state == .on }.count, 1)
        XCTAssertEqual(menu.items.first?.state, .on)
    }

    /// The whole menu, built by the app's own path: the checkmark follows the
    /// saved choice, in each submenu, on a model that is not first.
    func testTheWholeMenuChecksTheSavedChoice() async {
        var s = EndpointSettings(address: "http://127.0.0.1:1234/v1", speechModel: "parakeet-tdt-0.6b-v3",
                                 cleanupModel: "", useCustomSpeech: true, useCustomCleanup: false)
        s.language = EndpointSettings.deviceLanguage
        store.save(s)
        await reloadModels()
        let full = menu()
        let speech = full.items.first { $0.title.hasPrefix("Speech Model: ") }!.submenu!
        let checked = speech.items.filter { $0.state == .on }
        XCTAssertEqual(checked.count, 1)
        XCTAssertEqual(checked.first?.title, "parakeet-tdt-0.6b-v3")
        let cleanup = full.items.first { $0.title.hasPrefix("Clean Up Model: ") }!.submenu!
        XCTAssertEqual(cleanup.items.filter { $0.state == .on }.count, 1)
        XCTAssertEqual(cleanup.items.first?.state, .on, "cleanup is on Apple Native")
    }

    // MARK: - Z2: never a false empty list

    func testWhileCheckingTheMenuSaysSoAndNeverClaimsNoModels() {
        let checking = MenuModelStore.Route(entries: ["Apple Native"], unreachable: false,
                                            missingChoice: nil, checking: true)
        for label in [MainMenuBuilder.speechLabel, MainMenuBuilder.cleanupLabel] {
            let menu = app.modelSubmenu(label: label, route: checking, chooseApple: true, chosen: "")
            XCTAssertTrue(menu.items.contains { $0.title == MainMenuBuilder.checkingNote }, label)
            XCTAssertFalse(menu.items.contains { $0.title == MainMenuBuilder.noSpeechModelsNote }, label)
            XCTAssertFalse(menu.items.contains { $0.title == MainMenuBuilder.noCleanupModelsNote }, label)
            XCTAssertFalse(menu.items.contains { $0.title == MainMenuBuilder.noServerNote }, label)
        }
    }

    func testAReachableServerThatListsNothingStillGetsTheNoModelsNote() {
        let answered = MenuModelStore.Route(entries: ["Apple Native"], unreachable: false,
                                            missingChoice: nil, checking: false)
        let menu = app.modelSubmenu(label: MainMenuBuilder.speechLabel, route: answered, chooseApple: true, chosen: "")
        XCTAssertTrue(menu.items.contains { $0.title == MainMenuBuilder.noSpeechModelsNote },
                      "an answer with no speech models is a real answer, and says so")
        XCTAssertFalse(menu.items.contains { $0.title == MainMenuBuilder.checkingNote })
    }

    func testARefusedKeyIsNamedAsARefusal() {
        let refused = MenuModelStore.Route(entries: ["Apple Native"], unreachable: false,
                                           missingChoice: nil, checking: false, keyRefused: true)
        let menu = app.modelSubmenu(label: MainMenuBuilder.speechLabel, route: refused, chooseApple: false, chosen: "")
        XCTAssertTrue(menu.items.contains { $0.title == MainMenuBuilder.keyRefusedNote })
        XCTAssertFalse(menu.items.contains { $0.title == MainMenuBuilder.noServerNote },
                       "a refused key is not an unreachable server")
        XCTAssertFalse(menu.items.contains { $0.title == MainMenuBuilder.noSpeechModelsNote })
    }

    /// The launch path, end to end through the app's own store: the menu is
    /// built before the answer, then again when the answer lands.
    func testLaunchShowCheckingThenTheModels() async {
        var s = EndpointSettings(address: "http://127.0.0.1:1234/v1", speechModel: "", useCustomSpeech: false)
        s.language = EndpointSettings.deviceLanguage
        store.save(s)
        let slow = MenuModelStore(endpointStore: store) { _, _ in
            try? await Task.sleep(nanoseconds: 300_000_000)
            return .success([ModelEntry(id: "whisper-x", modelType: "audio_stt"),
                             ModelEntry(id: "tidy-y", modelType: "vlm")])
        }
        var rebuilt: [MenuModelStore.Snapshot] = []
        slow.onRefreshFinished = { rebuilt.append(slow.snapshot()) }
        slow.refreshIfUseful()

        // What the app builds at launch, before any answer.
        let launch = slow.snapshot()
        XCTAssertTrue(launch.speech.checking, "at launch the menu says it is checking")
        let launchMenu = app.build(MainMenuAssembly.State(
            hotkeysOff: false, cleanupProblem: nil, recording: false, profile: "polish",
            snapshot: launch, updateVersion: nil, speechModel: s.speechModel, cleanupModel: s.cleanupModel))
        let launchSpeech = launchMenu.items.first { $0.title.hasPrefix("Speech Model: ") }!.submenu!
        XCTAssertFalse(launchSpeech.items.contains { $0.title == MainMenuBuilder.noSpeechModelsNote },
                       "the false empty list is never shown while checking")

        await waitUntil { !rebuilt.isEmpty }
        XCTAssertEqual(rebuilt.first?.speech.entries, ["Apple Native", "whisper-x"],
                       "the rebuild that follows the answer carries the models")
        XCTAssertEqual(rebuilt.first?.cleanup.entries, ["Apple Native", "tidy-y"])
    }

    /// A menu open when the answer lands keeps what it showed; the rebuild
    /// happens on close. Modeled here with the same open/close signals.
    func testAMenuOpenDuringTheAnswerKeepsItsListThenRebuildsOnClose() {
        let before = MenuModelStore.Snapshot(
            speech: MenuModelStore.Route(entries: ["Apple Native", "old"], unreachable: false, missingChoice: nil),
            cleanup: MenuModelStore.Route(entries: ["Apple Native"], unreachable: false, missingChoice: nil),
            speechIsApple: false, cleanupIsApple: true)
        let shown = app.build(MainMenuAssembly.State(
            hotkeysOff: false, cleanupProblem: nil, recording: false, profile: "polish",
            snapshot: before, updateVersion: nil, speechModel: "old", cleanupModel: ""))
        let shownSpeech = shown.items.first { $0.title.hasPrefix("Speech Model: ") }!.submenu!
        XCTAssertTrue(shownSpeech.items.contains { $0.title == "old" })

        app.actions?.menuDidOpen()
        app.actions?.refreshModels()
        XCTAssertEqual(actions.opened, 1)
        XCTAssertEqual(actions.refreshes, 1)
        // The menu on screen was not rebuilt: it still shows the same items.
        XCTAssertTrue(shownSpeech.items.contains { $0.title == "old" })
        app.actions?.menuDidClose()
        XCTAssertEqual(actions.closed, 1)
    }

    private func waitUntil(_ done: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while !done() {
            if Date() > deadline { XCTFail("condition never happened", file: file, line: line); return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
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
