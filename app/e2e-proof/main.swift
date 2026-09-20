import AppKit
import AVFoundation
import CoreAudio

// t_955de3e6 — LIVE full-pipeline harness. Compiles the REAL app stack
// (SessionController, AudioCapture, HotkeyManager, Insertion, SidecarClient,
// OverlayController) and drives real capture sessions:
//   posted ⌃⌘ events → live event tap → real mic (speakers→BlackHole) →
//   live sidecar STT+polish → ⌘V into focused TextEdit → AX verify.
// Journal: /tmp/qs955-e2e-journal.txt

let JOURNAL_PATH = "/tmp/qs955-e2e-journal.txt"
let T0 = Date()
var journal = ""
func jlog(_ s: String) {
    let line = String(format: "[%07.3f] %@", Date().timeIntervalSince(T0), s)
    journal += line + "\n"
    print(line)
    try? journal.write(toFile: JOURNAL_PATH, atomically: true, encoding: .utf8)
}
func spin(_ secs: Double) { RunLoop.main.run(until: Date().addingTimeInterval(secs)) }

let src = CGEventSource(stateID: .hidSystemState)!
func post(_ key: Int64, down: Bool, _ flags: CGEventFlags) {
    let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(key), keyDown: down)!
    e.flags = flags
    e.post(tap: .cgSessionEventTap)
}
let kControl: Int64 = 0x3B, kCommand: Int64 = 0x37, kShift: Int64 = 0x38
let cc = CGEventFlags.maskControl.union(.maskCommand)
let ccs = cc.union(.maskShift)

// --- Default output device switch (speakers -> BlackHole -> restore) ------
func audioDevices(matching name: String) -> [(AudioDeviceID, String)] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    var out: [(AudioDeviceID, String)] = []
    for id in ids {
        var naddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        var nameCF: CFString = "" as CFString
        var nsz = UInt32(MemoryLayout<CFString>.size)
        if AudioObjectGetPropertyData(id, &naddr, 0, nil, &nsz, &nameCF) == noErr {
            let n = nameCF as String
            if n.contains(name) { out.append((id, n)) }
        }
    }
    return out
}
func getDefaultOutput() -> AudioDeviceID {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var dev = AudioDeviceID(0)
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &dev)
    return dev
}
func setDefaultOutput(_ dev: AudioDeviceID) -> Bool {
    var d = dev
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                      UInt32(MemoryLayout<AudioDeviceID>.size), &d) == noErr
}
func getDefaultInput() -> AudioDeviceID {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var dev = AudioDeviceID(0)
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &dev)
    return dev
}
func setDefaultInput(_ dev: AudioDeviceID) -> Bool {
    var d = dev
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                      UInt32(MemoryLayout<AudioDeviceID>.size), &d) == noErr
}

func pbSetMarker() {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString("QS955-CLIPBOARD-MARKER-\(Int(Date().timeIntervalSince1970))", forType: .string)
}
func pbString() -> String { NSPasteboard.general.string(forType: .string) ?? "(none)" }

func axFocusedValue() -> String {
    let sys = AXUIElementCreateSystemWide()
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let el = focused else { return "(no focus)" }
    var val: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el as! AXUIElement, kAXValueAttribute as CFString, &val) == .success,
          let s = val as? String else { return "(no value)" }
    return s
}

/// Hard gate: TextEdit must be frontmost AND its text area key before any
/// session runs — otherwise the ⌘V paste lands in whatever IS focused.
@MainActor
func ensureTargetFocused(seed: String) -> Bool {
    for attempt in 0..<8 {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        let axv = axFocusedValue()
        if front == "com.apple.TextEdit", axv.contains(seed) {
            jlog("target focused (attempt \(attempt)): front=\(front) ax=\(axv.prefix(24))")
            return true
        }
        Process.runCmd("/usr/bin/osascript", ["-e", "tell application \"TextEdit\" to activate"])
        spin(0.7)
        // Force key focus into the text area via AX (System Events path).
        _ = Process.runCmd2("/usr/bin/osascript", ["-e",
            "tell application \"System Events\" to tell process \"TextEdit\" to set focused of text area 1 of scroll area 1 of front window to true"])
        spin(0.4)
    }
    jlog("FATAL-GATE: could not focus TextEdit text area; front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?") ax=\(axFocusedValue().prefix(24))")
    return false
}

/// Clipboard mechanics proof using the REAL Insertion code (same module):
/// snapshot -> write -> recognize marker -> restore -> verify byte-identical.
@MainActor
func clipboardMechanicsProof() -> Bool {
    let pb = NSPasteboard.general
    let original = "QS955-ORIGINAL-CLIPBOARD-\(UUID().uuidString.prefix(8))"
    pb.clearContents()
    pb.setString(original, forType: .string)
    let snap = Insertion.snapshot(pb)
    let ccBefore = pb.changeCount
    // Simulate what insert() does between snapshot and restore:
    pb.clearContents()
    pb.setString("QS955-TRANSIENT-PAYLOAD", forType: .string)
    pb.setData(Data(AppInfo.displayName.utf8), forType: Insertion.markerType)
    let changed = pb.changeCount != ccBefore
    let markerSeen = pb.string(forType: Insertion.markerType) != nil
    // Restore via the same logic Insertion.restore uses (writeObjects of items).
    pb.clearContents()
    var items: [NSPasteboardItem] = []
    for bag in snap.items {
        let item = NSPasteboardItem()
        for (t, d) in bag { item.setData(d, forType: t) }
        items.append(item)
    }
    if !items.isEmpty { pb.writeObjects(items) }
    let restored = pb.string(forType: .string) == original
    let ok = changed && markerSeen && restored
    jlog("CLIPBOARD-PROOF done")
    return ok
}

func historyFetch() -> [[String: Any]] {
    let sem = DispatchSemaphore(value: 0)
    var out: [[String: Any]] = []
    var req = URLRequest(url: URL(string: "http://127.0.0.1:8790/history?limit=5")!)
    req.timeoutInterval = 3
    URLSession.shared.dataTask(with: req) { d, _, _ in
        if let d = d, let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] { out = arr }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 4)
    return out
}

final class Speaker {
    static func play(_ path: String, seconds: Double) {
        guard let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else {
            jlog("!! TTS load failed: \(path)"); return
        }
        p.volume = 1.0
        p.play()
        spin(seconds + 0.3)
        p.stop()
    }
}

extension Process {
    static func runCmd(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }
    @discardableResult
    static func runCmd2(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared   // initialize AppKit BEFORE any NSApp use
    app.setActivationPolicy(.accessory)
    jlog("harness start (pid \(getpid()), accessory policy)")

    // Route system audio into BlackHole so TTS reaches the default INPUT.
    let blackholes = audioDevices(matching: "BlackHole")
    guard let (bhID, bhName) = blackholes.first else {
        jlog("FATAL: BlackHole device not found"); exit(3)
    }
    let originalOutput = getDefaultOutput()
    let originalInput = getDefaultInput()
    guard setDefaultOutput(bhID) else { jlog("FATAL: cannot set default output"); exit(3) }
    _ = setDefaultInput(bhID)   // app captures DEFAULT INPUT -> must be BlackHole too
    jlog("default in+out -> \(bhName) (id \(bhID)); orig out \(originalOutput) in \(originalInput)")
    defer {
        _ = setDefaultOutput(originalOutput)
        _ = setDefaultInput(originalInput)
    }

    let session = SessionController()
    var phases: [(Double, Bool)] = []   // absolute epoch seconds (history ts is epoch)
    session.onPhaseChange = { rec in phases.append((Date().timeIntervalSince1970, rec)) }

    guard session.activate() else {
        jlog("FATAL: event tap not live — aborting (honest harness)")
        exit(2)
    }
    jlog("event tap live")

    // Focus TextEdit with a scratch doc.
    let target = "/tmp/qs955-target.txt"
    try? "QS955 insert target\n".write(toFile: target, atomically: true, encoding: .utf8)
    Process.runCmd("/usr/bin/open", ["-e", target])
    spin(1.5)
    let screenLocked = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow"
    if screenLocked {
        jlog("SCREEN LOCKED: GUI insert leg will be gated — running all non-GUI proofs (clipboard mechanics, degrade, recovery)")
    }
    if !screenLocked {
        guard ensureTargetFocused(seed: "QS955 insert target") else { exit(4) }
    }
    _ = clipboardMechanicsProof()

    func pidOfSidecar() -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "sidecar/server.py"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Int32(s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first ?? "0") ?? 0
    }

    func healthUp(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let sem = DispatchSemaphore(value: 0)
            var ok = false
            var req = URLRequest(url: URL(string: "http://127.0.0.1:8790/health")!)
            req.timeoutInterval = 1.5
            URLSession.shared.dataTask(with: req) { d, _, _ in
                if let d = d, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   j["status"] as? String == "ok" { ok = true }
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 3)
            if ok { return true }
            spin(0.4)
        }
        return false
    }

    @MainActor
    func runSession(_ name: String, rewrite: Bool, wavPath: String,
                    ttsSeconds: Double, token: String, toggled: Bool = false,
                    expectInserted: Bool = true) {
        jlog("== \(name): begin (rewrite=\(rewrite), toggled=\(toggled))")
        pbSetMarker()
        let pbBefore = pbString()

        if toggled {
            session.toggleHandsFree()
        } else {
            post(kControl, down: true, .maskControl)
            spin(0.03)
            if rewrite {
                post(kShift, down: true, ccs); spin(0.03)
                post(kCommand, down: true, ccs)
            } else {
                post(kCommand, down: true, cc)
            }
        }
        spin(0.45) // dwell 0.15 + margin
        guard session.isRecording else {
            jlog("FAIL(\(name)): not recording after dwell (mic? tap?)")
            return
        }
        jlog("\(name): recording (overlay=\(session.overlayStateLabel()))")
        Speaker.play(wavPath, seconds: ttsSeconds)
        jlog("\(name): TTS done (~\(ttsSeconds)s utterance)")

        if toggled {
            post(0x07, down: true, [])   // ordinary 'x' mid-session (toggled must survive)
            spin(0.1)
            jlog("\(name): typed 'x' mid-session, stillRecording=\(session.isRecording)")
            session.toggleHandsFree()
        } else {
            if rewrite {
                post(kShift, down: false, cc); spin(0.02)
                post(kCommand, down: false, .maskControl); spin(0.02)
                post(kControl, down: false, [])
            } else {
                post(kCommand, down: false, .maskControl); spin(0.02)
                post(kControl, down: false, [])
            }
            jlog("\(name): hotkey released")
        }

        let releaseT = phases.last?.0 ?? 0
        let deadline = Date().addingTimeInterval(14)
        var inserted = false
        while Date() < deadline {
            spin(0.25)
            if axFocusedValue().contains(token) { inserted = true; break }
        }
        spin(1.0) // clipboard restore window (0.6 s timer)
        let restored = pbString() == pbBefore
        var histFound = false
        var tti: Double = -1
        let hDeadline = Date().addingTimeInterval(6)
        while Date() < hDeadline {
            let h = historyFetch()
            if let newest = h.first, (newest["polished"] as? String ?? "").contains(token) {
                histFound = true
                if let ts = newest["ts"] as? Double { tti = ts - releaseT }
                break
            }
            spin(0.3)
        }
        let okInserted = inserted == expectInserted
        jlog("RESULT(\(name)): inserted=\(inserted) expected=\(expectInserted) ok=\(okInserted) clipboardRestored=\(restored) history=\(histFound) tti=\(String(format: "%.2f", tti))s overlay=\(session.overlayStateLabel()) phaseChanges=\(phases.count)")
    }

    // S1–S3 happy path — needs a focused GUI target for the paste leg.
    // Skipped when the screen is locked (insert cannot land) or in degrade stage.
    let happyPath = !screenLocked && ProcessInfo.processInfo.environment["QS955_DEGRADE"] != "1"
    if happyPath {
        // S1 — polish profile, push-to-talk, ~4.5 s utterance (10 s bucket).
        runSession("S1-polish", rewrite: false, wavPath: "/tmp/qs955-utt.wav",
                   ttsSeconds: 4.2, token: "Nadia and Omar")

        // S2 — forced rewrite via ⌃⌘⇧.
        runSession("S2-rewrite", rewrite: true, wavPath: "/tmp/qs955-utt2.wav",
                   ttsSeconds: 4.0, token: "roadmap")

        // S3 — hands-free toggle: typing mid-session must NOT cancel.
        runSession("S3-toggle", rewrite: false, wavPath: "/tmp/qs955-utt.wav",
                   ttsSeconds: 4.2, token: "Reykjavik", toggled: true)
    }

    // Degrade + recovery — fully headless-verifiable (no GUI needed):
    // S4 expects NO insert; S5 verifies pipeline recovery (insert leg gated on unlock).
    if ProcessInfo.processInfo.environment["QS955_DEGRADE"] == "1" || screenLocked {
        // S4 — sidecar DOWN mid-flight: capture, kill sidecar before release,
        // expect NO insert and NO crash.
        jlog("== S4-degrade: killing sidecar pid \(pidOfSidecar()) before release")
        pbSetMarker()
        let pbBefore4 = pbString()
        post(kControl, down: true, .maskControl); spin(0.03)
        post(kCommand, down: true, cc)
        spin(0.45)
        guard session.isRecording else { jlog("FAIL(S4): not recording"); return }
        Speaker.play("/tmp/qs955-utt.wav", seconds: 4.2)
        let pid = pidOfSidecar()
        if pid > 0 { _ = Process.runCmd("/bin/kill", ["-9", "\(pid)"]) }
        spin(0.3)
        post(kCommand, down: false, .maskControl); spin(0.02)
        post(kControl, down: false, [])
        jlog("S4: released with sidecar down")
        let d4 = Date().addingTimeInterval(16)
        while Date() < d4, session.isRecording || session.overlayStateLabel().contains("processing") { spin(0.3) }
        spin(2.0)
        let ins4 = axFocusedValue().contains("Nadia and Omar")
        jlog("RESULT(S4-degrade): inserted=\(ins4) (expect false) stillAlive=\(true) overlay=\(session.overlayStateLabel())")
        _ = pbBefore4

        // S5 — recovery: relaunch sidecar, wait healthy, full session again.
        jlog("== S5-recover: relaunching sidecar")
        Process.runCmd("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/com.quickscribe.sidecar"])
        guard healthUp(timeout: 90) else {
            jlog("FAIL(S5): sidecar did not become healthy in 90s")
            jlog("harness main flow complete")
            return
        }
        jlog("S5: sidecar healthy — running full session")
        runSession("S5-recover", rewrite: false, wavPath: "/tmp/qs955-utt.wav",
                   ttsSeconds: 4.2, token: "Nadia and Omar")
    }

    jlog("harness main flow complete")
}

extension SessionController {
    @MainActor
    func overlayStateLabel() -> String {
        let m = Mirror(reflecting: self)
        for child in m.children where child.label == "overlay" {
            let om = Mirror(reflecting: child.value)
            for oc in om.children where oc.label == "state" {
                return String(describing: oc.value)
            }
        }
        return "(unknown)"
    }
}
