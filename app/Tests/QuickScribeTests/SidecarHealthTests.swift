import XCTest
@testable import QuickScribe

/// t_a0fb24bb: the permanent health monitor's observable rules, as a pure
/// transition table (SidecarHealth.next). No timers, no network.
final class SidecarHealthTests: XCTestCase {
    func testHealthyAtLaunchIsQuiet() {
        // Steady healthy (initial state == healthy): nothing may change.
        XCTAssertEqual(SidecarHealth.next(down: false, probeOK: true, hotkeysLive: true, recording: false),
                       SidecarHealth.Outcome(down: false, icon: .keep, tip: .keep))
    }
    func testOutageAfterHealthyDimsIcon() {
        XCTAssertEqual(SidecarHealth.next(down: false, probeOK: false, hotkeysLive: true, recording: false),
                       SidecarHealth.Outcome(down: true, icon: .dimmed, tip: .down))
    }
    func testRecoveryRestoresIconWithoutRelaunch() {
        XCTAssertEqual(SidecarHealth.next(down: true, probeOK: true, hotkeysLive: true, recording: false),
                       SidecarHealth.Outcome(down: false, icon: .normal, tip: .ready))
    }
    func testRecoveryDoesNotClaimReadyWhileHotkeysDead() {
        // Icon may normalize (dimming was about the sidecar) but the tooltip
        // must not claim "ready" while the tap is not live.
        XCTAssertEqual(SidecarHealth.next(down: true, probeOK: true, hotkeysLive: false, recording: false),
                       SidecarHealth.Outcome(down: false, icon: .normal, tip: .keep))
    }
    func testDelayedOutageResponseCannotOverwriteRecordingIcon() {
        // The probe left before recording began; its late answer updates STATE
        // (so session end dims honestly) but must not touch the icon.
        XCTAssertEqual(SidecarHealth.next(down: false, probeOK: false, hotkeysLive: true, recording: true),
                       SidecarHealth.Outcome(down: true, icon: .keep, tip: .down))
    }
    func testSteadyDownIsQuiet() {
        XCTAssertEqual(SidecarHealth.next(down: true, probeOK: false, hotkeysLive: true, recording: false),
                       SidecarHealth.Outcome(down: true, icon: .keep, tip: .keep))
    }
    func testOutageDuringRecordingThenRecoveryChainRemainsObservable() {
        // healthy → (record, outage arrives, icon untouched) → (late probe
        // tracked state) → recovery observable without relaunch.
        var down = false
        let t1 = SidecarHealth.next(down: down, probeOK: false, hotkeysLive: true, recording: true)
        down = t1.down
        XCTAssertTrue(down)                 // state tracked during recording
        XCTAssertEqual(t1.icon, .keep)      // recording animation not clobbered
        let t2 = SidecarHealth.next(down: down, probeOK: true, hotkeysLive: true, recording: false)
        XCTAssertFalse(t2.down)
        XCTAssertEqual(t2.icon, .normal)    // recovery observable without relaunch
    }
}
