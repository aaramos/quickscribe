import CoreGraphics
import XCTest
@testable import QuickScribe

final class VoiceModeCommandTests: XCTestCase {
    func testCommandAloneSwitchesAndInsertsNothing() {
        XCTAssertEqual(VoiceModeCommand.parse("Switch to concise."), .init(modeID: "concise", remainder: ""))
        XCTAssertEqual(VoiceModeCommand.parse("switch to concise"), .init(modeID: "concise", remainder: ""))
        XCTAssertEqual(VoiceModeCommand.parse(" Switch to polish mode. "), .init(modeID: "polish", remainder: ""))
        XCTAssertEqual(VoiceModeCommand.parse("Switch to the Active Voice."), .init(modeID: "active_voice", remainder: ""))
        XCTAssertEqual(VoiceModeCommand.parse("switch to active-voice!"), .init(modeID: "active_voice", remainder: ""))
    }
    func testWordsAfterTheCommandAreStillDictated() {
        XCTAssertEqual(VoiceModeCommand.parse("Switch to concise. The report is done."),
                       .init(modeID: "concise", remainder: "The report is done."))
    }
    func testOrdinarySentencesAreNotCommands() {
        XCTAssertNil(VoiceModeCommand.parse("Switch to concise emails next quarter."))
        XCTAssertNil(VoiceModeCommand.parse("We should switch to concise."))
        XCTAssertNil(VoiceModeCommand.parse("Switch to rewrite."))
        XCTAssertNil(VoiceModeCommand.parse(""))
    }
}

final class RefineModeTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "RefineModeTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultStartsOnPolishAndPersists() {
        XCTAssertEqual(RefineMode.savedProfile(in: defaults), "polish")
        RefineMode.saveProfile("active_voice", in: defaults)
        XCTAssertEqual(RefineMode.savedProfile(in: defaults), "active_voice")
        RefineMode.saveProfile("rewrite", in: defaults)
        XCTAssertEqual(RefineMode.savedProfile(in: defaults), "rewrite")
    }
    func testUnknownSavedValueFallsBackToPolish() {
        RefineMode.saveProfile("gone", in: defaults)
        XCTAssertEqual(RefineMode.savedProfile(in: defaults), "polish")
    }
    func testModeShortcutNeedsExactlyControlCommandAndADigit() {
        let chord = CGEventFlags.maskControl.union(.maskCommand)
        XCTAssertEqual(HotkeyManager.modeIndex(keyCode: 18, flags: chord), 0)
        XCTAssertEqual(HotkeyManager.modeIndex(keyCode: 19, flags: chord), 1)
        XCTAssertEqual(HotkeyManager.modeIndex(keyCode: 20, flags: chord), 2)
        XCTAssertNil(HotkeyManager.modeIndex(keyCode: 21, flags: chord))
        XCTAssertNil(HotkeyManager.modeIndex(keyCode: 18, flags: .maskCommand))
        XCTAssertNil(HotkeyManager.modeIndex(keyCode: 18, flags: chord.union(.maskShift)))
    }
}

final class PromptDraftsTests: XCTestCase {
    private func entry(_ id: String, prompt: String = "factory", custom: Bool = false) -> SidecarClient.PromptEntry {
        .init(id: id, label: id, prompt: prompt, factory: "factory", custom: custom)
    }

    func testDraftsSurviveMovingBetweenModes() {
        var drafts = PromptDrafts()
        drafts.load([entry("polish"), entry("concise")])
        drafts.edit("polish", text: "typed")
        XCTAssertEqual(drafts.text("concise"), "factory")
        XCTAssertEqual(drafts.text("polish"), "typed")
        XCTAssertTrue(drafts.isDirty("polish"))
        XCTAssertFalse(drafts.isDirty("concise"))
    }
    func testReloadKeepsUnsavedTyping() {
        var drafts = PromptDrafts()
        drafts.load([entry("polish")])
        drafts.edit("polish", text: "typed")
        drafts.load([entry("polish")])
        XCTAssertEqual(drafts.text("polish"), "typed")
    }
    func testCommitReplacesTheDraftWithTheSidecarsAnswer() {
        var drafts = PromptDrafts()
        drafts.load([entry("polish")])
        drafts.edit("polish", text: "typed")
        drafts.commit(entry("polish", prompt: "typed", custom: true))
        XCTAssertFalse(drafts.isDirty("polish"))
        XCTAssertEqual(drafts.entry("polish")?.custom, true)
        drafts.commit(entry("polish"))
        XCTAssertEqual(drafts.text("polish"), "factory")
    }
    func testTokenEstimateRoundsUp() {
        XCTAssertEqual(PromptDrafts.estimateTokens(""), 0)
        XCTAssertEqual(PromptDrafts.estimateTokens("abcd"), 1)
        XCTAssertEqual(PromptDrafts.estimateTokens("abcde"), 2)
    }
}

/// The real listener fed real events: the mode chord must never start, stop or cancel by accident.
final class HotkeyModeChordTests: XCTestCase {
    private let chord = CGEventFlags.maskControl.union(.maskCommand)

    private func flagsChanged(_ flags: CGEventFlags) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: true)!
        event.type = .flagsChanged
        event.flags = flags
        return event
    }
    private func key(_ code: CGKeyCode, _ flags: CGEventFlags) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
        event.flags = flags
        return event
    }
    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testChordInsideTheDwellPicksTheModeAndNeverStartsCapture() {
        let hotkeys = HotkeyManager()
        var intents: [HotkeyManager.Intent] = []
        hotkeys.onIntent = { intents.append($0) }
        hotkeys._handleForTesting(type: .flagsChanged, event: flagsChanged(chord))
        hotkeys._handleForTesting(type: .keyDown, event: key(19, chord))
        pump(AppInfo.holdDwell + 0.1)
        hotkeys._handleForTesting(type: .flagsChanged, event: flagsChanged([]))
        pump(0.05)
        XCTAssertEqual(intents, [.selectMode(index: 1)])
    }

    func testChordDuringCaptureKeepsRecordingButOtherKeysStillCancel() {
        let hotkeys = HotkeyManager()
        var intents: [HotkeyManager.Intent] = []
        hotkeys.onIntent = { intents.append($0) }
        hotkeys._handleForTesting(type: .flagsChanged, event: flagsChanged(chord))
        pump(AppInfo.holdDwell + 0.1)
        hotkeys._handleForTesting(type: .keyDown, event: key(20, chord))
        pump(0.05)
        hotkeys._handleForTesting(type: .keyDown, event: key(3, chord))  // the F key
        pump(0.05)
        XCTAssertEqual(intents, [.start(rewrite: false), .selectMode(index: 2), .cancel])
    }
}
