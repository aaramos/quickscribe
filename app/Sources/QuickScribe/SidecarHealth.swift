import Foundation

/// Pure sidecar-health transitions (t_a0fb24bb) — the HotkeyManager.reduce
/// pattern: the AppDelegate timer code only ADAPTS this; the observable rules
/// live here and are unit-tested in Tests/QuickScribeTests.
///
/// Rules encoded:
/// • The monitor is PERMANENT: probes keep running for the app's life, so a
///   later outage (healthy → down) is observable, not just the launch race.
/// • A delayed response must never overwrite the recording icon — while a
///   session is live the icon belongs to the animation; the `down` STATE still
///   updates so session end dims/restores honestly (stopIconAnimation reads it).
/// • Icon changes only on TRANSITIONS (changed), never on steady state —
///   a routine 30 s probe must not fight applyIcon callers.
/// • The "ready" tooltip may only claim readiness while hotkeys are actually
///   live; otherwise it must not lie about the current problem.
enum SidecarHealth {
    enum Icon: Equatable { case keep, normal, dimmed }
    enum Tip: Equatable { case keep, down, ready }

    struct Outcome: Equatable {
        let down: Bool
        let icon: Icon
        let tip: Tip
    }

    /// `probeOK` = /health answered with decodable JSON; nil response → false.
    static func next(down: Bool, probeOK: Bool, hotkeysLive: Bool, recording: Bool) -> Outcome {
        let nowDown = !probeOK
        let changed = nowDown != down
        var icon: Icon = .keep
        if changed && !recording { icon = nowDown ? .dimmed : .normal }
        var tip: Tip = .keep
        if changed { tip = nowDown ? .down : (hotkeysLive ? .ready : .keep) }
        return Outcome(down: nowDown, icon: icon, tip: tip)
    }
}
