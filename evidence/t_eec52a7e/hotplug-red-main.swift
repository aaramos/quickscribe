import AVFoundation
import CoreAudio
import Foundation

// t_eec52a7e RED control: compiled against HEAD (pre-fix) sources. Mirrors
// what the shipped app does today: register a device-change listener, keep
// the SAME AudioCapture object across a default-input switch, press again.
// With the bug, session2's ENGINE keeps capturing the old device (live tap
// format stuck at A's channel count) even after re-resolution.

let capture = AudioCapture()
InputDeviceResolver.registerChangeCallback {
    if let d = InputDeviceResolver.resolve() {
        NSLog("QuickScribe: input devices changed — next capture will use '\(d.name)'")
    }
}
func pump(_ secs: Double) { RunLoop.main.run(until: Date().addingTimeInterval(secs)) }
var da = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
func getDefault() -> AudioDeviceID {
    var dev = AudioDeviceID(0); var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &da, 0, nil, &sz, &dev)
    return dev
}
func setDefault(_ id: AudioDeviceID) {
    var d = id
    AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &da, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &d)
}
let reals = InputDeviceResolver.allInputDevices().filter { !$0.isVirtual }
guard reals.count >= 2, let a = reals.first, let b = reals.dropFirst().first else { print("need 2 mics"); exit(2) }
let orig = getDefault()
setDefault(a.id); pump(0.4)
do { try capture.start() } catch { print("s1 start threw \(error)"); exit(2) }
pump(1.0); _ = capture.stop()
print("HEAD session1: '\(capture.activeDevice?.name ?? "?")' ch=\(capture.activeDevice?.channels ?? 0)")
setDefault(b.id); pump(1.5)
// The honest bug signal on HEAD: the reused engine's inputNode STILL reports
// device A's format after the resolver re-picked B.
let staleFmt = capture.probeEngineFormat()
print("HEAD engine format after switch: rate=\(staleFmt.sampleRate) ch=\(staleFmt.channelCount) (A ch=\(a.channels), B ch=\(b.channels))")
do { try capture.start() } catch { print("s2 start threw: \((error as? AudioCapture.CaptureError)?.why ?? error.localizedDescription)"); exit(2) }
pump(1.0); _ = capture.stop()
let liveFmt = capture.probeEngineFormat()
print("HEAD session2 engine AFTER start: ch=\(liveFmt.channelCount) (B is ch=\(b.channels)) — this audio stream is what Whisper would have heard")
let second = capture.activeDevice?.name ?? "?"
// Verdict on the ENGINE, not the resolver: resolver names B while the
// reused engine still streams A's format = the defect.
let stale = (staleFmt.channelCount == a.channels && b.channels != a.channels)
if stale {
    print("REPRODUCED: resolver picked '\(second)' but the reused engine stayed on '\(a.name)' (ch=\(staleFmt.channelCount)) — audio would come from the OLD mic until app restart")
} else {
    print("UNEXPECTED: HEAD engine followed the switch")
}
setDefault(orig)
exit(stale ? 3 : 0)
