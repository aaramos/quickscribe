import AVFoundation
import CoreAudio
import Foundation

/// Input-device resolution (t_b3e7802c): the OS default input on this host
/// is BlackHole 2ch — a virtual loopback that carries NO live signal, which
/// is exactly what fed Whisper the silence that produced the "Thank you."
/// hallucination loops. The app must therefore NEVER trust the OS default
/// blindly.
///
/// Resolution order:
///   1. QUICKSCRIBE_INPUT_PIN env — substring match against device names
///      (harness/owner override, e.g. "C920").
///   2. The OS default input — but ONLY if it is real (input channels > 0
///      and not a known virtual/loopback device by name).
///   3. The first real input device (enumeration order = user preference
///      order in macOS).
/// If none: nil → caller shows "No microphone detected" and never records.
enum InputDeviceResolver {
    struct Device: Equatable {
        let id: AudioDeviceID
        let name: String
        let channels: UInt32
        let isVirtual: Bool
    }

    /// Name fragments of known virtual/loopback aggregate devices on this
    /// host family. A device matching any of these can carry signal only if
    /// something is actively routing into it — never assume a live mic.
    private static let virtualHints = ["blackhole", "loopback", "soundflower",
                                       "multi-output", "aggregate", "cascad"]

    static func isVirtual(name: String) -> Bool {
        let n = name.lowercased()
        return virtualHints.contains { n.contains($0) }
    }

    private static func address(_ s: AudioObjectPropertySelector,
                                _ sc: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: s, mScope: sc, mElement: kAudioObjectPropertyElementMain)
    }

    static func deviceName(_ id: AudioDeviceID) -> String {
        var nm: CFString = "" as CFString
        var sz = UInt32(MemoryLayout<CFString>.size)
        var a = address(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal)
        AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &nm)
        return nm as String
    }

    static func inputChannels(_ id: AudioDeviceID) -> UInt32 {
        var cssz: UInt32 = 0
        var a = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &cssz) == noErr, cssz > 0 else { return 0 }
        var buf = [UInt8](repeating: 0, count: Int(cssz))
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &cssz, &buf) == noErr else { return 0 }
        let bl = buf.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: AudioBufferList.self) }
        var ch: UInt32 = 0
        for _ in 0..<Int(bl.pointee.mNumberBuffers) { ch += bl.pointee.mBuffers.mNumberChannels }
        return ch
    }

    static func defaultInputDevice() -> AudioDeviceID? {
        var dev = AudioDeviceID(0)
        var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = address(kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &dev) == noErr,
              dev != 0 else { return nil }
        return dev
    }

    static func allInputDevices() -> [Device] {
        var sz: UInt32 = 0
        var a = address(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(sz / UInt32(MemoryLayout<AudioDeviceID>.size)))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let ch = inputChannels(id)
            guard ch > 0 else { return nil }
            let name = deviceName(id)
            return Device(id: id, name: name.isEmpty ? "device \(id)" : name,
                         channels: ch, isVirtual: isVirtual(name: name))
        }
    }

    /// Resolve the device the engine should bind. See header for precedence.
    static func resolve() -> Device? {
        resolve(devices: allInputDevices(),
                defaultID: defaultInputDevice(),
                pin: ProcessInfo.processInfo.environment["QUICKSCRIBE_INPUT_PIN"])
    }

    /// Pure selection core (t_eec52a7e unit proof): no CoreAudio calls, so
    /// a fake device list can drive the phantom-gate / fallback rules.
    /// `resolve()` above is a thin wrapper over this — keep them in sync by
    /// keeping ALL logic here.
    static func resolve(devices all: [Device], defaultID: AudioDeviceID?, pin: String?) -> Device? {
        if let pin, !pin.isEmpty {
            if let hit = all.first(where: { $0.name.lowercased().contains(pin.lowercased()) }) {
                return hit
            }
            NSLog("QuickScribe: QUICKSCRIBE_INPUT_PIN='\(pin)' matched no input device — falling back")
        }
        if let def = defaultID, let d = all.first(where: { $0.id == def }), !d.isVirtual {
            return d
        }
        return all.first(where: { !$0.isVirtual })
    }

    /// Subscribe to device-add/remove/default-change; fires `onChange` on a
    /// background queue so the session controller can re-resolve + re-log.
    static func registerChangeCallback(_ onChange: @escaping () -> Void) {
        var a = address(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a,
                                            DispatchQueue.global(qos: .utility)) { _, _ in onChange() }
        var d = address(kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &d,
                                            DispatchQueue.global(qos: .utility)) { _, _ in onChange() }
    }

    // MARK: - Capture-time device bind
    //
    // AVAudioEngine.setInputDevice / AVAudioDevice are ABSENT from this OS's
    // AVFAudio runtime (probed via ObjC runtime on macOS 27.0 seed — the
    // newer typed device API does not exist in this framework build). The
    // engine therefore binds the SYSTEM default input at start(). Binding a
    // resolved real mic = switch the default for the capture window, restore
    // on stop. Proven mechanism on this host (t_955de3e6 e2e harness uses the
    // identical CoreAudio property switch).

    struct Bind {
        let switched: Bool
        let restoreTo: AudioDeviceID
        let device: Device
    }

    /// Switch the system default input to `dev` if it isn't already.
    /// Returns a Bind the caller MUST hand back to `restore(_:)` on stop.
    static func bindForCapture(_ dev: Device) -> Bind {
        guard defaultInputDevice() != dev.id else {
            return Bind(switched: false, restoreTo: dev.id, device: dev)
        }
        let prev = defaultInputDevice() ?? 0
        var d = dev.id
        var a = address(kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal)
        let ok = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil,
                                            UInt32(MemoryLayout<AudioDeviceID>.size), &d) == noErr
        NSLog("QuickScribe: capture bind default-input -> '\(dev.name)' ok=\(ok)")
        return Bind(switched: ok, restoreTo: prev, device: dev)
    }

    /// Restore the pre-capture default input (best effort, logged).
    static func restore(_ bind: Bind) {
        guard bind.switched, bind.restoreTo != 0 else { return }
        guard defaultInputDevice() == bind.device.id else {
            // Someone else moved the default during capture — don't stomp it.
            NSLog("QuickScribe: default input moved during capture; restore skipped")
            return
        }
        var d = bind.restoreTo
        var a = address(kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal)
        let ok = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil,
                                            UInt32(MemoryLayout<AudioDeviceID>.size), &d) == noErr
        NSLog("QuickScribe: default input restored -> id \(bind.restoreTo) ok=\(ok)")
    }
}
