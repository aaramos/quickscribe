import AppKit
import AVFoundation
import CoreAudio

// t_955de3e6 AC6 — per-app REAL-WORLD TTI driver (Notes / TextEdit / Chrome / Terminal).
// Compiles the REAL app stack (SessionController/HotkeyManager/Insertion/...).
// For each app, 2 runs: focus target with seed marker, route audio out->BlackHole,
// post real ⌃⌘ hold, play a unique utterance, release, poll AX until the polished
// token appears in the app. TTI = release -> token visible in the app.

let JOURNAL_PATH = "/tmp/qs955-perapp/journal.txt"
let T0 = Date()
var journal = ""
func jlog(_ s: String) {
    let line = String(format: "[%07.3f] %@", Date().timeIntervalSince(T0), s)
    journal += line + "\n"
    print(line)
    try? journal.write(toFile: JOURNAL_PATH, atomically: true, encoding: .utf8)
}
func spin(_ secs: Double) { RunLoop.main.run(until: Date().addingTimeInterval(secs)) }
func front() -> String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?" }

let src = CGEventSource(stateID: .hidSystemState)!
func post(_ key: Int64, down: Bool, _ flags: CGEventFlags) {
    let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(key), keyDown: down)!
    e.flags = flags
    e.post(tap: .cgSessionEventTap)
}
let kControl: Int64 = 0x3B, kCommand: Int64 = 0x37

func osascript(_ script: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try? p.run(); p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

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
func getDefaultIO(_ sel: AudioObjectPropertySelector) -> AudioDeviceID {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var dev = AudioDeviceID(0); var sz = UInt32(4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &dev)
    return dev
}
func setDefaultIO(_ sel: AudioObjectPropertySelector, _ dev: AudioDeviceID) -> Bool {
    var d = dev
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                      UInt32(MemoryLayout<AudioDeviceID>.size), &d) == noErr
}

struct Target {
    let name: String            // display
    let bundle: String
    let seed: String            // marker seeded into the doc
    let focusSel: String?       // axfocus selector for mid-capture focus
    let setup: () -> Bool       // open+focus+seed, return ok
    let read: () -> String      // read doc contents via AX/AppleScript
}

func runAxfocus(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/tmp/qs955-perapp/axfocus")
    p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try? p.run(); p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

var notesName = ""

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let blackholes = audioDevices(matching: "BlackHole")
    guard let (bhID, bhName) = blackholes.first else { jlog("FATAL: no BlackHole"); exit(3) }
    let origOut = getDefaultIO(kAudioHardwarePropertyDefaultOutputDevice)
    let origIn  = getDefaultIO(kAudioHardwarePropertyDefaultInputDevice)
    guard setDefaultIO(kAudioHardwarePropertyDefaultOutputDevice, bhID),
          setDefaultIO(kAudioHardwarePropertyDefaultInputDevice, bhID) else {
        jlog("FATAL: audio route"); exit(3)
    }
    defer { _ = setDefaultIO(kAudioHardwarePropertyDefaultOutputDevice, origOut)
            _ = setDefaultIO(kAudioHardwarePropertyDefaultInputDevice, origIn) }
    jlog("route -> \(bhName)")

    let session = SessionController()
    var releaseT: Date? = nil
    session.onPhaseChange = { _ in }
    guard session.activate() else { jlog("FATAL: event tap dead"); exit(2) }
    jlog("event tap live")

    let targets: [Target] = [
        Target(name: "TextEdit", bundle: "com.apple.TextEdit", seed: "PERAPP-SEED-TE", focusSel: "textarea",
            setup: {
                _ = osascript("""
                    tell application "TextEdit"
                        activate
                        if (count documents) = 0 then make new document
                    end tell
                    """)
                spin(1.2)
                _ = osascript("tell application \"TextEdit\" to set text of document 1 to \"PERAPP-SEED-TE \"")
                spin(0.4)
                let v = osascript("tell application \"TextEdit\" to get text of document 1")
                return v.contains("PERAPP-SEED-TE")
            },
            read: { osascript("tell application \"TextEdit\" to get text of document 1") }),
        Target(name: "Notes", bundle: "com.apple.Notes", seed: "PERAPP-SEED-NO", focusSel: "textarea",
            setup: {
                _ = osascript("tell application \"Notes\" to activate")
                spin(1.2)
                // ⌘N so the NEW note editor actually has focus (AppleScript
                // make-new-note does not switch the visible editor).
                let src2 = CGEventSource(stateID: .hidSystemState)
                let dn = CGEvent(keyboardEventSource: src2, virtualKey: 0x08, keyDown: true)!; dn.flags = .maskCommand
                let up = CGEvent(keyboardEventSource: src2, virtualKey: 0x08, keyDown: false)!; up.flags = .maskCommand
                dn.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                spin(1.0)
                let v = runAxfocus(["com.apple.Notes", "textarea", "SEED "])
                return v.lowercased().contains("seed")
            },
            read: { runAxfocus(["com.apple.Notes", "textarea", "-", "--noclick"]) }),
        Target(name: "Chrome", bundle: "com.google.Chrome", seed: "PERAPP-SEED-CH", focusSel: "textarea",
            setup: {
                for attempt in 0..<2 {
                    _ = osascript("tell application \"Google Chrome\" to activate")
                    spin(1.2)
                    _ = osascript("tell application \"Google Chrome\" to open location \"file:///tmp/qs955-perapp/target.html\"")
                    spin(1.5)
                    let f = runAxfocus(["com.google.Chrome", "textarea", "-"])
                    if f.contains("SEED-CH") || f.contains("VALUE:") { return true }
                    jlog("Chrome setup attempt \(attempt): \(f)")
                    spin(1.0)
                }
                return false
            },
            read: { runAxfocus(["com.google.Chrome", "textarea", "-", "--noclick"]) }),
        Target(name: "Terminal", bundle: "com.apple.Terminal", seed: "PERAPP-SEED-TE2", focusSel: nil,
            setup: {
                _ = osascript("tell application \"Terminal\" to activate")
                spin(1.2)
                _ = osascript("tell application \"Terminal\" to do script \"echo PERAPP-SEED-TE2\"")
                spin(1.0)
                return true
            },
            read: { osascript("tell application \"Terminal\" to get contents of front window") }),
    ]

    // Unique utterance per (app, run): token appears ONLY in this run's speech.
    let utts: [(wav: String, secs: Double, token: String)] = [
        ("/tmp/qs955-perapp/v0.wav", 2.9, "nina"),
        ("/tmp/qs955-perapp/v1.wav", 2.9, "puppy"),
        ("/tmp/qs955-perapp/v2.wav", 2.9, "castle"),
        ("/tmp/qs955-perapp/v3.wav", 2.9, "lemon"),
        ("/tmp/qs955-perapp/v4.wav", 2.9, "scarf"),
        ("/tmp/qs955-perapp/v5.wav", 2.9, "canal"),
        ("/tmp/qs955-perapp/v6.wav", 2.9, "owls"),
        ("/tmp/qs955-perapp/v7.wav", 2.9, "captain"),
    ]

    @MainActor
    func runSession(_ t: Target, _ u: (wav: String, secs: Double, token: String), idx: Int) -> (tti: Double, inserted: Bool, restored: Bool) {
        let pb = NSPasteboard.general
        let orig = "PERAPP-CLIP-\(t.name)-\(idx)-\(Int(Date().timeIntervalSince1970))"
        pb.clearContents(); pb.setString(orig, forType: .string)

        // 1) setup target content (activate + seed)
        guard t.setup() else { jlog("\(t.name)#\(idx): SETUP FAILED"); return (-1, false, false) }

        // 2) start capture
        post(kControl, down: true, .maskControl); spin(0.03)
        post(kCommand, down: true, [.maskCommand, .maskControl])
        spin(0.6)  // dwell 150ms + start intent + activate() (sleeps ~0.35s)
        guard session.isRecording else { jlog("\(t.name)#\(idx): NOT RECORDING"); return (-1, false, false) }
        jlog("\(t.name)#\(idx): recording")

        // 3) focus target editor precisely (AX set-focus + click)
        let axf = runAxfocus([t.bundle, t.focusSel ?? "textarea", "-"])
        jlog("\(t.name)#\(idx): focus \(axf.hasPrefix("VALUE:") ? "ok" : axf)")

        // 4) speak
        var player: AVAudioPlayer? = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: u.wav))
        player?.volume = 1.0
        player?.play()
        spin(u.secs + 0.3)
        player?.stop()

        // 5) release → polish → insert
        post(kCommand, down: false, .maskControl); spin(0.02)
        post(kControl, down: false, [])
        releaseT = Date()

        // 6) poll target for token
        var inserted = false
        var tti = -1.0
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            spin(0.2)
            let body = t.read()
            if body.lowercased().replacingOccurrences(of: "\n", with: " ").contains(u.token.lowercased()) {
                inserted = true
                tti = Date().timeIntervalSince(releaseT!)
                break
            }
        }
        spin(1.0)
        let restored = pb.string(forType: .string) == orig
        jlog("RESULT(\(t.name)#\(idx)): inserted=\(inserted) tti=\(String(format: "%.2f", tti))s clipboardRestored=\(restored)")
        return (tti, inserted, restored)
    }

    var uttIdx = 0
    for t in targets {
        for _ in 0..<2 {
            _ = runSession(t, utts[uttIdx], idx: uttIdx)
            uttIdx += 1
        }
    }
    jlog("per-app driver complete")
}
