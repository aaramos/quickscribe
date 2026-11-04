import AVFoundation
import CoreAudio
import Foundation
import QuartzCore
import SpecCatch

/// ObjC exception bridge: AVAudioEngine.prepare()/start() raise
/// NSException (`com.apple.coreaudio.avfaudio`), which Swift `do/catch`
/// CANNOT catch. An uncaught throw in the menu action path was the silent
/// no-op on 2026-09-19 (AppKit swallowed it: "This is a bug in the client
/// code"). All engine touchpoints must run through this guard.
enum ExceptionGuard {
    /// Runs `body`; returns nil on success, error description if an
    /// Objective-C exception OR a Swift error was thrown.
    ///
    /// The old implementation ran the body as `try?`, which SILENTLY
    /// DISCARDED Swift errors — e.g. an `engine.start()` AVAudioError was
    /// swallowed, start() reported success, the engine never ran, no buffers
    /// ever arrived, and the session died at "Couldn't hear you" despite a
    /// working mic. Swift errors now surface like exceptions.
    static func run(_ body: () throws -> Void) -> String? {
        var name: NSString?
        var reason: NSString?
        var swiftError: Error?
        let caught = NSException_blockCatch({
            do { try body() } catch { swiftError = error }
        }, &name, &reason)
        if caught { return "\(name ?? "unknown")/\(reason ?? "(no reason)")" }
        if let swiftError { return "swift: \(swiftError)" }
        return nil
    }
}

/// CoreAudio pre-flight: default input device exists, is alive, has channels.
enum AudioPreflight {
    struct Info { let deviceID: AudioDeviceID; let name: String; let channels: UInt32 }
    struct Failure: Error, ExpressibleByStringLiteral {
        let why: String
        init(why: String) { self.why = why }
        init(stringLiteral value: String) { self.why = value }
    }

    static func check() -> Result<Info, Failure> {
        func pa(_ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: s, mScope: sc, mElement: kAudioObjectPropertyElementMain)
        }
        var dev = AudioDeviceID(0)
        var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = pa(kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &dev)
        guard st == noErr, dev != 0 else { return .failure(Failure(why: "no default input device (status=\(st))")) }
        var alive: UInt32 = 0
        var aa = pa(kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal)
        var asz = UInt32(4)
        AudioObjectGetPropertyData(dev, &aa, 0, nil, &asz, &alive)
        guard alive == 1 else { return .failure(Failure(why: "default input device \(dev) is not alive")) }
        // Channel count via the ONE correct AudioBufferList walk
        // (InputDeviceResolver.inputChannels) — this used to duplicate a
        // broken version that re-read buffer[0] once per buffer.
        let ch = InputDeviceResolver.inputChannels(dev)
        guard ch > 0 else { return .failure(Failure(why: "default input device \(dev) has 0 input channels")) }
        // Single shared, correctly-managed name read (was a duplicate
        // CFString-by-pointer fetch — the harness build warning).
        let name = InputDeviceResolver.deviceName(dev)
        return .success(Info(deviceID: dev, name: name, channels: ch))
    }
}

/// AVAudioEngine capture. Each buffer goes straight to the recognizer, and its level
/// is measured along the way so a session the mic never really heard can say so
/// instead of inserting whatever the recognizer made of the noise.
final class AudioCapture {
    /// NOT a `let`: AVAudioEngine binds its input device the first time the
    /// node graph is touched and never re-reads the system default (proven
    /// on macOS 27, t_eec52a7e: an engine first touched while default=A keeps
    /// reporting A's format after the default switches to B; only a FRESH
    /// engine reports B). A long-lived engine is therefore exactly the
    /// "new mic ignored until app restart" defect — `invalidateEngine()`
    /// swaps in a fresh instance on device changes while idle.
    private var engine = AVAudioEngine()
    private var capturedSeconds: Double = 0
    private var windowSeconds: Double = 0
    private var windowEnergy: Double = 0
    private var windowSamples: Int64 = 0
    private(set) var isCapturing = false

    /// Active capture device (resolved at start, shown in the overlay pill).
    private(set) var activeDevice: InputDeviceResolver.Device?
    /// LIVE tap format from the engine that actually captured (t_eec52a7e
    /// proof hook): shows the device the ENGINE bound, not what the resolver
    /// asked for. nil when no capture has run since the last invalidate.
    private(set) var liveTapFormat: AVAudioFormat?
    /// Scoped default-input switch owned by the capture window (t_b3e7802c).
    private var bind: InputDeviceResolver.Bind?
    /// Window accounting for the honest "Couldn't hear you" path.
    private(set) var voicedWindows = 0
    private(set) var silentWindows = 0

    /// Invoked on the audio thread with each captured buffer. The buffer is only
    /// valid during the call.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// LEVEL TAP (t_3db202e7): invoked on a background queue with the live
    /// input level 0...1 for every capture buffer, ~1 frame per 16 ms so a
    /// 60 fps waveform has real data behind it. Pure read-only tap — it
    /// does not touch the chunk pipeline. UI-only consumer (WF1 overlay).
    var onLevel: ((_ level: Double) -> Void)?
    private var lastLevelEmit = CFTimeInterval(0)
    /// Peak raw level since capture started (headless level-tap proof).
    private(set) var peakLevel: Double = 0

    struct CaptureError: Error { let why: String }

    private let accountingQueue = DispatchQueue(label: "quickscribe.capture-accounting")

    var sessionWasFullySilent: Bool { accountingQueue.sync { voicedWindows == 0 } }

    func start() throws {
        guard !isCapturing else { return }
        // Defensive: a previous failed start must never leave a bind dangling —
        // stop() early-returns while !isCapturing, so nothing else restores it.
        if let b = bind { InputDeviceResolver.restore(b); bind = nil }
        voicedWindows = 0
        silentWindows = 0
        capturedSeconds = 0
        windowSeconds = 0
        windowEnergy = 0
        windowSamples = 0
        peakLevel = 0
        lastLevelEmit = 0
        let inputFormat: AVAudioFormat
        do {
            inputFormat = try startEngine()
        } catch {
            // Mic permission likely not granted yet — retry once after the
            // permission prompt lands (onboarding owns the prompt).
            do { inputFormat = try startEngine() } catch { throw CaptureError(why: "mic unavailable: \(error.localizedDescription)") }
        }
        // installTap throws NSException on format mismatch — must be inside
        // the exception bridge (t_50da3b54) or AppKit swallows it as a
        // silent no-op.
        if let exc = ExceptionGuard.run({ [engine, inputFormat] in
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buf, _ in
                self?.handle(buf)
            }
        }) {
            engine.stop()
            if let b = bind { InputDeviceResolver.restore(b); bind = nil }
            activeDevice = nil
            throw CaptureError(why: "tap install: \(exc)")
        }
        isCapturing = true
    }

    private func startEngine() throws -> AVAudioFormat {
        // macOS 27 regression: prepare() with an untouched inputNode throws an
        // ObjC exception (inputNode != nullptr) on this host — every device,
        // every process (t_220b8507 run 28). Querying the input format first
        // makes the graph initialize. Do NOT reorder these lines.
        if case .failure(let pf) = AudioPreflight.check() {
            throw CaptureError(why: pf.why)
        }
        // Device bind (t_b3e7802c): never trust the OS default — on this
        // host it is BlackHole 2ch (silent virtual loopback, proven RCA).
        // Engine-level device APIs are absent from this OS's AVFAudio
        // runtime; the proven mechanism is a scoped default-input switch
        // across the capture window, restored on stop.
        guard let dev = InputDeviceResolver.resolve() else {
            throw CaptureError(why: "no microphone detected")
        }
        activeDevice = dev
        bind = InputDeviceResolver.bindForCapture(dev)
        // Everything after the bind must unwind it on failure: a thrown error
        // used to leave the SYSTEM default input switched to `dev` while
        // isCapturing stayed false — stop() early-returns and never restored,
        // and the permission-retry below would re-bind and clobber `bind`,
        // losing the original restore target. The do/catch keeps bind
        // ownership strictly tied to a running capture window.
        var engineStarted = false
        do {
            let inFmt = engine.inputNode.outputFormat(forBus: 0)
            guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else {
                throw CaptureError(why: "no live input device (rate=\(inFmt.sampleRate) ch=\(inFmt.channelCount))")
            }
            NSLog("QuickScribe: capture device = '\(dev.name)' (id=\(dev.id), ch=\(dev.channels), virtual=\(dev.isVirtual))")
            if let exc = ExceptionGuard.run({ [engine] in
                engine.prepare()
                try engine.start()
            }) {
                throw CaptureError(why: "engine init: \(exc)")
            }
            engineStarted = true
            // macOS 27 trap (t_50da3b54): the pre-start inputNode.outputFormat
            // can report a nominal rate (16k) that the hardware does NOT come up
            // at (C920 starts at 48k/2ch). Installing the tap with the stale
            // pre-start format throws com.apple.coreaudio.avfaudio from
            // InstallTapOnNode — inside start(), OUTSIDE the ExceptionGuard —
            // which AppKit swallows: menu click and hotkey both become silent
            // no-ops. Re-read the LIVE format after start and install the tap
            // with THAT. Do not revert to using the pre-start format for the tap.
            let liveFmt = engine.inputNode.outputFormat(forBus: 0)
            guard liveFmt.sampleRate > 0, liveFmt.channelCount > 0 else {
                throw CaptureError(why: "live input format invalid (rate=\(liveFmt.sampleRate) ch=\(liveFmt.channelCount))")
            }
            liveTapFormat = liveFmt
            return liveFmt
        } catch {
            // Unwind in reverse order of acquisition (t_a0fb24bb): a started
            // engine must be stopped BEFORE the default-input bind is restored
            // — stopping afterward races the bind flip — and an engine left
            // running with isCapturing == false holds the device. stop() can
            // itself raise (AVFAudio exceptions); bridge it, log, continue.
            if engineStarted, let exc = ExceptionGuard.run({ [engine] in engine.stop() }) {
                NSLog("QuickScribe: engine.stop during failed-start unwind raised: \(exc)")
            }
            if let b = bind { InputDeviceResolver.restore(b); bind = nil }
            activeDevice = nil
            liveTapFormat = nil
            // Failed engine instance has already pinned the device it tried
            // (t_eec52a7e lesson: engines pin at first touch for their LIFETIME)
            // — swap in a fresh one so the next start() re-pins the CURRENT
            // resolver choice. We are idle by construction here, the same
            // precondition invalidateEngine asserts.
            engine = AVAudioEngine()
            throw error
        }
    }

    /// Drop the pinned engine so the NEXT start() binds the current default
    /// input (t_eec52a7e). Only valid while idle — mid-capture the engine is
    /// deliberately left alone (a mid-session hot-swap of OUTPUTS must not
    /// disturb recording; the bind/restore pair keeps the input stable for
    /// the whole capture window).
    func invalidateEngine() {
        guard !isCapturing else { return }
        engine = AVAudioEngine()
        activeDevice = nil
        liveTapFormat = nil
    }

    /// Returns how many seconds were captured. A last partial window still counts,
    /// so a very short dictation isn't mistaken for silence.
    func stop() -> Double {
        guard isCapturing else { return 0 }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
        if let b = bind { InputDeviceResolver.restore(b); bind = nil }
        return accountingQueue.sync {
            closeWindow()
            return capturedSeconds
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        var energy: Double = 0
        for i in 0..<count { let v = Double(channel[i]); energy += v * v }
        let rms = (energy / Double(count)).squareRoot()
        if let onLevel {
            let level = min(1.0, rms * 6.0)
            if level > peakLevel { peakLevel = level }
            let now = CACurrentMediaTime()
            if now - lastLevelEmit >= 0.015 {
                lastLevelEmit = now
                onLevel(level)
            }
        }
        let seconds = Double(count) / buffer.format.sampleRate
        accountingQueue.sync {
            capturedSeconds += seconds
            windowSeconds += seconds
            windowEnergy += energy
            windowSamples += Int64(count)
            if windowSeconds >= AppInfo.silenceWindowSeconds { closeWindow() }
        }
        onBuffer?(buffer)
    }

    /// Caller holds accountingQueue.
    private func closeWindow() {
        guard windowSamples > 0 else { return }
        let rms = (windowEnergy / Double(windowSamples)).squareRoot()
        if rms < AppInfo.silenceRmsFloor { silentWindows += 1 } else { voicedWindows += 1 }
        windowSeconds = 0
        windowEnergy = 0
        windowSamples = 0
    }
}
