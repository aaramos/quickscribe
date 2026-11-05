import XCTest
@testable import QuickScribe
@testable import QuickScribeCore

/// A version notice must never take the pill away from anything the person
/// may be reading, and one it skips is not one it told.

@MainActor
final class UpdateNoticeGateTests: XCTestCase {

    private let newer = UpdateChecker.Check.newer(
        version: "2.1", page: URL(string: "https://github.com/example/native/releases/tag/v2.1")!)

    /// Every pill state except an empty pill counts as busy, read off a
    /// real session: the words arriving, the words being worked on, a
    /// permission warning with no hide timer, the just-inserted check, the
    /// orange guard notice, and the copied fallback. Only hidden is free.
    func testOnlyAnEmptyPillIsFree() {
        let prompts = PromptLibrary(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qs-prompts-\(UUID().uuidString).json"))
        let session = SessionController(prompts: prompts,
                                        endpointStore: EndpointSettingsStore(
                                            defaults: UserDefaults(suiteName: "qs.gate.\(UUID().uuidString)")!,
                                            secrets: MemorySecrets.Store()))
        XCTAssertTrue(session.pillIsFree, "a fresh session has an empty pill")

        session.showOverlay(.recording(mode: "Clean up"))
        XCTAssertFalse(session.pillIsFree, "dictation words arriving")

        session.showOverlay(.processing)
        XCTAssertFalse(session.pillIsFree, "dictation words on their way home")

        session.showOverlay(.error("Accessibility off, so hotkeys are disabled. Enable QuickScribe in System Settings."))
        XCTAssertFalse(session.pillIsFree, "a permission warning stays until read")

        session.showOverlay(.inserted)
        XCTAssertFalse(session.pillIsFree, "the inserted check is being read")

        session.showOverlay(.error("Cleanup said no. Your words went in as they are."))
        XCTAssertFalse(session.pillIsFree, "the orange guard notice is being read")

        session.showOverlay(.copied)
        XCTAssertFalse(session.pillIsFree, "the copy-instead message is being read")

        session.showOverlay(.hidden)
        XCTAssertTrue(session.pillIsFree, "empty at last: the notice may go on")
    }

    func testTheNoticeWaitsForQuietAndTheMenuNeverDoes() {
        XCTAssertNil(AppDelegate.updateNotice(newer, lastNotified: nil, sessionBusy: true),
                     "recording or finishing: nothing on the pill, and nothing marked as told")
        XCTAssertEqual(AppDelegate.updateNotice(newer, lastNotified: nil, sessionBusy: false), "2.1",
                       "at the quiet moment the same check announces")
        XCTAssertNil(AppDelegate.updateNotice(newer, lastNotified: "2.1", sessionBusy: false),
                     "a skipped notice is retold later; a told one never")
    }
}
