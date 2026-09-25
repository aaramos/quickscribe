import AVFoundation
import CoreAudio
import Foundation

// t_eec52a7e hot-plug proof: compiles the REAL InputDeviceResolver +
// AudioCapture sources (the same files the app builds). Two parts:
//  A) unit-level — fake device lists drive the pure selection core
//     (phantom/BlackHole gate, unplug fallback, no-mic nil). This is the
//     unit test the card mandates; true hot-plug cannot be unit-tested, so
//     part B proves it live and says so.
//  B) live — owner repro shape: the app object keeps running, a device is
//     (re)connected and becomes the new default, the CoreAudio change
//     notification fires for REAL (emitted by the system default-input
//     switch), and the NEXT press must use the new device WITHOUT relaunch.
//     A physical plug cannot be scripted on an unattended machine; switching
//     the system default drives the identical listener -> re-resolve ->
//     engine-rebind path, and a physical plug additionally fires the
//     kAudioHardwarePropertyDevices listener wired by the same call.

func D(_ id: AudioDeviceID, _ name: String, _ ch: UInt32, virt: Bool = false) -> InputDeviceResolver.Device {
    InputDeviceResolver.Device(id: id, name: name, channels: ch, isVirtual: virt)
}

var failures = 0
func check(_ name: String, _ cond: Bool) {
    print("\(cond ? "PASS" : "FAIL"): \(name)")
    if !cond { failures += 1 }
}

// ---------- A) unit-level: resolver re-selects / falls back safely ----------
let blackhole = D(1, "BlackHole 2ch", 2, virt: true)
let cam = D(2, "HD Pro Webcam C920", 2)
let phoneMic = D(3, "iPhone Microphone", 1)

check("gate: virtual default not picked, falls to first real",
      InputDeviceResolver.resolve(devices: [blackhole, cam, phoneMic], defaultID: 1, pin: nil)?.id == 2)
check("gate: virtual-only list resolves nil (no-mic state)",
      InputDeviceResolver.resolve(devices: [blackhole], defaultID: 1, pin: nil) == nil)
check("change: newly-present real device selected as default on re-resolve",
      InputDeviceResolver.resolve(devices: [cam, phoneMic], defaultID: 3, pin: nil)?.id == 3)
check("unplug: removed current default falls back to remaining real",
      InputDeviceResolver.resolve(devices: [blackhole, phoneMic], defaultID: 2, pin: nil)?.id == 3)
check("unplug: empty list resolves nil (surface 'no mic', never record silence)",
      InputDeviceResolver.resolve(devices: [], defaultID: nil, pin: nil) == nil)
check("pin: QUICKSCRIBE_INPUT_PIN semantics unchanged",
      InputDeviceResolver.resolve(devices: [blackhole, cam, phoneMic], defaultID: nil, pin: "iPhone")?.id == 3)

// ---------- B) live: engine rebind without relaunch ----------
let reals = InputDeviceResolver.allInputDevices().filter { !$0.isVirtual }
guard reals.count >= 2, let a = reals.first, let b = reals.dropFirst().first else {
    print("FAIL: need >= 2 real input devices for the live leg (found \(reals.map(\.name)))")
    exit(1)
}
var da = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
func getDefault() -> AudioDeviceID {
    var dev = AudioDeviceID(0); var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &da, 0, nil, &sz, &dev)
    return dev
}
func setDefault(_ id: AudioDeviceID) -> Bool {
    var d = id
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &da, 0, nil,
                                      UInt32(MemoryLayout<AudioDeviceID>.size), &d) == noErr
}
let origDefault = getDefault()
print("live: A='\(a.name)' (\(a.id), ch=\(a.channels))  B='\(b.name)' (\(b.id), ch=\(b.channels))  origDefault=\(origDefault)")

// ONE AudioCapture object for the whole proof — that is the "no relaunch".
let capture = AudioCapture()
var changeFires = 0
// Mirror of SessionController's wiring (t_eec52a7e): background CoreAudio
// listener -> main-queue hop -> re-resolve (logged inside resolve path) +
// drop the engine the OS pinned to the old device.
InputDeviceResolver.registerChangeCallback { [weak capture] in
    DispatchQueue.main.async {
        capture?.invalidateEngine()
        changeFires += 1
    }
}
func pump(_ secs: Double) { RunLoop.main.run(until: Date().addingTimeInterval(secs)) }

func runPress(_ tag: String) {
    do { try capture.start() } catch { print("  \(tag): start threw: \((error as? AudioCapture.CaptureError)?.why ?? error.localizedDescription)") }
    pump(1.0)
    _ = capture.stop()
    let f = capture.liveTapFormat
    print("  \(tag): resolver->'\(capture.activeDevice?.name ?? "nil")' engine tap=\(f.map { "rate=\($0.sampleRate) ch=\($0.channelCount)" } ?? "nil")")
}
/// Engine-level truth: the LIVE tap format proves which device the ENGINE
/// captured — with the stale-engine bug it keeps the OLD device's format
/// even when the resolver picked the new one. Falls back to resolver
/// identity only when both devices share a format (then tap can't tell).
func engineFollows(_ dev: InputDeviceResolver.Device, _ other: InputDeviceResolver.Device) -> Bool {
    guard let f = capture.liveTapFormat else { return false }
    if f.channelCount == dev.channels, f.channelCount != other.channels { return true }
    if f.channelCount == other.channels, f.channelCount != dev.channels { return false }
    return capture.activeDevice?.id == dev.id
}

guard setDefault(a.id) else { print("FAIL: setDefault(A)"); exit(1) }
pump(0.5)
runPress("session1")
check("live session 1: real device bound", capture.activeDevice != nil && !capture.activeDevice!.isVirtual)

// --- the (re)connect: B becomes the system default -> fires the REAL
//     CoreAudio change notifications into the running app.
print("live: (re)connect sim -> default B '\(b.name)'")
guard setDefault(b.id) else { print("FAIL: setDefault(B)"); exit(1) }
pump(1.5)   // lets the listener + main-queue invalidation run
check("device-change listener fired (engine invalidated, no relaunch)", changeFires >= 1)
runPress("session2")
check("after (re)connect, NEXT press uses B — engine-level (live tap format)",
      capture.activeDevice?.id == b.id && engineFollows(b, a))

// switch back: next press follows again, still no relaunch
_ = setDefault(a.id)
pump(1.5)
runPress("session3")
check("switch-back press follows the new default (still no relaunch)",
      capture.activeDevice?.id == a.id && engineFollows(a, b))

// restore machine state
_ = setDefault(origDefault)
pump(0.3)

let total = 10
print(failures == 0 ? "ALL PASS (\(total) checks)" : "FAILURES: \(failures)/\(total)")
exit(failures == 0 ? 0 : 1)
