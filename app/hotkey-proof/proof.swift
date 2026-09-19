import CoreGraphics
import Foundation

// Synthesized-event proof harness for the modifier-only hotkey FSM.
// Compiles the REAL HotkeyManager.swift + AppInfo.swift from the app tree
// (same module → fileprivate visible). Events are real CGEvent objects fed
// through the tap handler path; dwell is resolved on the main run loop.

let srcCtrl: CGEventSource = CGEventSource(stateID: .hidSystemState)!
let kShift: Int64 = 0x38, kControl: Int64 = 0x3B, kCommand: Int64 = 0x37
let kF: Int64 = 0x03, kSpace: Int64 = 0x31, kQ: Int64 = 0x0C

func flags(_ extra: CGEventFlags) -> CGEventFlags {
    CGEventFlags(rawValue: extra.rawValue)
}
func modDown(_ key: Int64, _ f: CGEventFlags) -> CGEvent {
    let e = CGEvent(keyboardEventSource: srcCtrl, virtualKey: CGKeyCode(key), keyDown: true)!
    e.flags = flags(f)
    return e
}
func modUp(_ key: Int64, _ f: CGEventFlags) -> CGEvent {
    let e = CGEvent(keyboardEventSource: srcCtrl, virtualKey: CGKeyCode(key), keyDown: false)!
    e.flags = flags(f)
    return e
}
func keyDown(_ key: Int64, _ f: CGEventFlags) -> CGEvent {
    let e = CGEvent(keyboardEventSource: srcCtrl, virtualKey: CGKeyCode(key), keyDown: true)!
    e.flags = flags(f)
    return e
}

final class Log {
    var intents: [HotkeyManager.Intent] = []
}

var failures = 0
func expect(_ cond: Bool, _ msg: String) {
    if cond { print("  PASS: \(msg)") }
    else { failures += 1; print("  FAIL: \(msg)") }
}

func spin(_ secs: Double) { RunLoop.main.run(until: Date().addingTimeInterval(secs)) }

let cc  = CGEventFlags.maskControl.union(.maskCommand)
let ccs = cc.union(.maskShift)

func fresh() -> (HotkeyManager, Log) {
    let m = HotkeyManager()
    let l = Log()
    m.onIntent = { l.intents.append($0) }
    return (m, l)
}

// T1 — hold ⌃⌘ ~1s: start after dwell, release either modifier stops.
print("T1: hold ⌃⌘ starts capture, release stops")
do {
    let (m, l) = fresh()
    m._handleForTesting(type: .flagsChanged, event: modDown(kControl, .maskControl))
    spin(0.02)
    expect(l.intents.isEmpty, "⌃ alone does not start")
    m._handleForTesting(type: .flagsChanged, event: modDown(kCommand, cc))
    spin(0.05)
    expect(l.intents.isEmpty, "inside dwell: no start yet")
    spin(0.9)
    expect(l.intents == [.start(rewrite: false)], "after dwell ~0.15s: start(polish)")
    m._handleForTesting(type: .flagsChanged, event: modUp(kControl, .maskCommand))
    spin(0.05)
    expect(l.intents.count == 2 && l.intents[1] == .stop(rewrite: false),
           "releasing ⌃ (⌘ still down) stops")
    m._handleForTesting(type: .flagsChanged, event: modUp(kCommand, []))
    spin(0.05)
    expect(l.intents.count == 2, "remaining ⌘ release emits nothing further")
}

// T2 — ⌃⌘F inside dwell: aborts start, no capture ever.
print("T2: ⌃⌘F does NOT trigger capture")
do {
    let (m, l) = fresh()
    m._handleForTesting(type: .flagsChanged, event: modDown(kControl, .maskControl))
    m._handleForTesting(type: .flagsChanged, event: modDown(kCommand, cc))
    spin(0.03)
    m._handleForTesting(type: .keyDown, event: keyDown(kF, cc))
    spin(0.5)
    expect(l.intents.isEmpty, "⌃⌘F keyDown inside dwell aborts pending start")
    m._handleForTesting(type: .flagsChanged, event: modUp(kCommand, .maskControl))
    m._handleForTesting(type: .flagsChanged, event: modUp(kControl, []))
    spin(0.05)
    expect(l.intents.isEmpty, "no intents across the whole ⌃⌘F gesture")
}

// T3 — ⌃⌘ held, dwell elapses, THEN F mid-capture: cancel, nothing to insert.
print("T3: key mid-capture cancels (no insert)")
do {
    let (m, l) = fresh()
    m._handleForTesting(type: .flagsChanged, event: modDown(kControl, .maskControl))
    m._handleForTesting(type: .flagsChanged, event: modDown(kCommand, cc))
    spin(0.3)
    expect(l.intents == [.start(rewrite: false)], "capture started")
    m._handleForTesting(type: .keyDown, event: keyDown(kF, cc))
    spin(0.05)
    expect(l.intents.count == 2 && l.intents[1] == .cancel, "mid-capture keyDown → cancel intent")
    m._handleForTesting(type: .flagsChanged, event: modUp(kCommand, .maskControl))
    m._handleForTesting(type: .flagsChanged, event: modUp(kControl, []))
    spin(0.05)
    expect(l.intents.count == 2, "modifier release after cancel emits nothing (no insert)")
}

// T4 — ⌃⌘⇧ hold: forced Rewrite, stop carries the locked-in profile even if
// ⇧ is released first.
print("T4: ⌃⌘⇧ exercises Rewrite; profile locked at start")
do {
    let (m, l) = fresh()
    m._handleForTesting(type: .flagsChanged, event: modDown(kControl, .maskControl))
    m._handleForTesting(type: .flagsChanged, event: modDown(kShift, .maskControl.union(.maskShift)))
    m._handleForTesting(type: .flagsChanged, event: modDown(kCommand, ccs))
    spin(0.3)
    expect(l.intents == [.start(rewrite: true)], "⌃⌘⇧ dwell → start(rewrite)")
    m._handleForTesting(type: .flagsChanged, event: modUp(kShift, cc))
    spin(0.02)
    expect(l.intents.count == 1, "⇧ release mid-capture: no intent")
    m._handleForTesting(type: .flagsChanged, event: modUp(kCommand, .maskControl))
    spin(0.05)
    expect(l.intents.count == 2 && l.intents[1] == .stop(rewrite: true),
           "stop carries rewrite even after ⇧ released first")
}

// T5 — ⌃⌘Space collision: Space inside dwell aborts (QuickScribe never claims Space).
print("T5: ⌃⌘Space passes through")
do {
    let (m, l) = fresh()
    m._handleForTesting(type: .flagsChanged, event: modDown(kControl, .maskControl))
    m._handleForTesting(type: .flagsChanged, event: modDown(kCommand, cc))
    spin(0.03)
    m._handleForTesting(type: .keyDown, event: keyDown(kSpace, cc))
    spin(0.3)
    m._handleForTesting(type: .keyDown, event: keyDown(kQ, cc))
    spin(0.3)
    expect(l.intents.isEmpty, "⌃⌘Space and ⌃⌘Q inside dwell never arm a start")
}

print(failures == 0 ? "\nALL PASS (\(5) scenarios)" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
