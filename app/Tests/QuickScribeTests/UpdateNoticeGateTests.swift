import XCTest
@testable import QuickScribe
@testable import QuickScribeCore

/// The rule from the review: a version notice must never take the pill away
/// from a dictation, and a version it skipped is NOT a version it told.
@MainActor
final class UpdateNoticeGateTests: XCTestCase {

    private let newer = UpdateChecker.Check.newer(
        version: "2.1", page: URL(string: "https://github.com/example/native/releases/tag/v2.1")!)

    /// Both busy shapes read off a real session's pill, and the idle in
    /// between: this is exactly the value the update check passes in.
    func testRecordingAndFinishingBothLookBusyIdleDoesNot() {
        let prompts = PromptLibrary(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qs-prompts-\(UUID().uuidString).json"))
        let session = SessionController(prompts: prompts,
                                        endpointStore: EndpointSettingsStore(
                                            defaults: UserDefaults(suiteName: "qs.gate.\(UUID().uuidString)")!,
                                            secrets: MemorySecrets.Store()))
        XCTAssertFalse(session.pillBelongsToDictation, "a fresh session is idle")

        session.showOverlay(.recording(mode: "Clean up"))          // held: words arriving
        XCTAssertTrue(session.pillBelongsToDictation, "recording")

        session.showOverlay(.processing)                           // released: words still on their way home
        XCTAssertTrue(session.pillBelongsToDictation, "finishing")

        session.showOverlay(.inserted, autoHide: 0)                // words home
        XCTAssertFalse(session.pillBelongsToDictation)
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
