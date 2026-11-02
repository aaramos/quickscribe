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

/// AVAudioEngine capture -> 16 kHz mono int16, flushed as WAV chunks
/// every AppInfo.chunkSeconds to the onChunk callback (runbook topology:
/// the APP owns capture + streaming; the sidecar owns models).
///
/// Silence gate (t_b3e7802c): each flush-chunk's RMS is computed before it
/// leaves the app. Chunks below AppInfo.silenceRmsFloor are NOT emitted —
/// silent audio never reaches Whisper, so the "Thank you." hallucination loop
/// cannot be born. The session tracks voiced vs silent chunk counts so a
/// fully-silent session reports honestly instead of inserting garbage.
final class AudioCapture {
    /// NOT a `let`: AVAudioEngine binds its input device the first time the
    /// node graph is touched and never re-reads the system default (proven
    /// on macOS 27, t_eec52a7e: an engine first touched while default=A keeps
    /// reporting A's format after the default switches to B; only a FRESH
    /// engine reports B). A long-lived engine is therefore exactly the
    /// "new mic ignored until app restart" defect — `invalidateEngine()`
    /// swaps in a fresh instance on device changes while idle.
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                              sampleRate: 16000, channels: 1, interleaved: true)!
    private var pending = Data()           // not-yet-flushed int16 LE samples
    private var totalSamples: Int64 = 0
    private var flushSamples: Int64 = 0   // samples accumulated since last flush
    private var flushEnergy: Double = 0   // sum of x² since last flush
    private(set) var isCapturing = false

    /// Active capture device (resolved at start, shown in the overlay pill).
    private(set) var activeDevice: InputDeviceResolver.Device?
    /// LIVE tap format from the engine that actually captured (t_eec52a7e
    /// proof hook): shows the device the ENGINE bound, not what the resolver
    /// asked for. nil when no capture has run since the last invalidate.
    private(set) var liveTapFormat: AVAudioFormat?
    /// Scoped default-input switch owned by the capture window (t_b3e7802c).
    private var bind: InputDeviceResolver.Bind?
    /// Chunk accounting for the honest "Couldn't hear you" path.
    private(set) var voicedChunks = 0
    private(set) var silentChunks = 0
    private(set) var lastChunkRms: Double = 0

    /// Invoked on a background queue with a complete WAV file's bytes.
    /// `voiced` = chunk RMS at/above the silence floor (only voiced chunks
    /// are ever emitted; the flag stays in the signature for the harness).
    var onChunk: ((_ wav: Data, _ secs: Double, _ voiced: Bool) -> Void)?

    /// LEVEL TAP (t_3db202e7): invoked on a background queue with the live
    /// input level 0...1 for every capture buffer, ~1 frame per 16 ms so a
    /// 60 fps waveform has real data behind it. Pure read-only tap — it
    /// does not touch the chunk pipeline. UI-only consumer (WF1 overlay).
    var onLevel: ((_ level: Double) -> Void)?
    private var lastLevelEmit = CFTimeInterval(0)
    /// Peak raw level since capture started (headless level-tap proof).
    private(set) var peakLevel: Double = 0

    struct CaptureError: Error { let why: String }

    private let flushQueue = DispatchQueue(label: "quickscribe.flush")

    var sessionWasFullySilent: Bool { silentChunks > 0 && voicedChunks == 0 }

    func start() throws {
        guard !isCapturing else { return }
        // Defensive: a previous failed start must never leave a bind dangling —
        // stop() early-returns while !isCapturing, so nothing else restores it.
        if let b = bind { InputDeviceResolver.restore(b); bind = nil }
        voicedChunks = 0
        silentChunks = 0
        lastChunkRms = 0
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
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        pending.removeAll(keepingCapacity: true)
        totalSamples = 0
        flushSamples = 0
        flushEnergy = 0
        // installTap throws NSException on format mismatch — must be inside
        // the exception bridge (t_50da3b54) or AppKit swallows it as a
        // silent no-op.
        if let exc = ExceptionGuard.run({ [engine, inputFormat] in
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buf, _ in
                self?.convert(buf)
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
            converter = nil
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
        converter = nil
        activeDevice = nil
        liveTapFormat = nil
    }

    func stop() -> Double {
        guard isCapturing else { return 0 }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
        if let b = bind { InputDeviceResolver.restore(b); bind = nil }
        return Double(totalSamples) / 16000.0
    }

    /// Flush any buffered audio (< chunk boundary) as the final "tail" WAV.
    /// Called from finish() after stop() — the PCM already sits in `pending`,
    /// so engine teardown does not affect it. Still RMS-gated: a silent tail
    /// is never emitted (t_b3e7802c).
    func flushTail() {
        guard flushSamples > 0 else { return }
        emitChunk()
    }

    private func convert(_ buffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }
        let capacity: AVAudioFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / converter.inputFormat.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var consumed = false
        let status = converter.convert(to: out, error: nil) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let bytes = Data(bytes: ch[0], count: Int(out.frameLength) * 2)
        // Sum of squares over this buffer's int16 samples (in normalized
        // units) — accumulated per chunk so chunk RMS is exact, not sampled.
        let samples = UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength))
        var energy: Double = 0
        for s in samples { let v = Double(s) / 32768.0; energy += v * v }
        // LEVEL TAP: per-buffer RMS → 0...1 level, throttled to ~60 fps.
        if let onLevel = onLevel, out.frameLength > 0 {
            let lvl = min(1.0, (energy / Double(out.frameLength)).squareRoot() * 6.0)
            if lvl > peakLevel { peakLevel = lvl }
            let now = CACurrentMediaTime()
            if now - lastLevelEmit >= 0.015 {
                lastLevelEmit = now
                onLevel(lvl)
            }
        }
        flushQueue.sync {
            pending.append(bytes)
            totalSamples += Int64(out.frameLength)
            flushSamples += Int64(out.frameLength)
            flushEnergy += energy
            if flushSamples >= Int64(16000 * AppInfo.chunkSeconds) {
                emitChunkLocked()
            }
        }
    }

    private func emitChunk() {
        flushQueue.sync { emitChunkLocked() }
    }

    /// Caller holds flushQueue. Non-overlapping chunks: whatever is buffered
    /// goes out and the buffer resets — partials concatenate verbatim.
    /// SILENCE GATE: chunks whose RMS is below the floor are counted and
    /// dropped; they are never sent to the decoder.
    private func emitChunkLocked() {
        guard flushSamples > 0 else { return }
        let rms = (flushEnergy / Double(flushSamples)).squareRoot()
        let secs = Double(flushSamples) / 16000.0
        flushSamples = 0
        flushEnergy = 0
        lastChunkRms = rms
        if rms < AppInfo.silenceRmsFloor {
            silentChunks += 1
            NSLog(String(format: "QuickScribe: chunk %.1fs rms=%.5f BELOW floor %.4f — gated (no decode)",
                         secs, rms, AppInfo.silenceRmsFloor))
            return
        }
        voicedChunks += 1
        let wav = WavWriter.wav(int16LE: pending, sampleRate: 16000)
        pending.removeAll(keepingCapacity: true)
        onChunk?(wav, secs, true)
    }

}

enum WavWriter {
    /// Exact byte size of the header written below (44) — callers merging
    /// WAV payloads (SessionController.takePendingChunks) drop this prefix to
    /// get at the raw int16 PCM. Keep in sync with `wav(int16LE:sampleRate:)`.
    static let headerSize = 44

    /// Minimal RIFF/WAVE writer: 16-bit PCM mono.
    static func wav(int16LE data: Data, sampleRate: UInt32) -> Data {
        var out = Data()
        let dataLen = UInt32(data.count)
        out.append(contentsOf: "RIFF".utf8)
        out.append(le(36 + dataLen))
        out.append(contentsOf: "WAVE".utf8)
        out.append(contentsOf: "fmt ".utf8)
        out.append(le(16))                       // fmt chunk size
        out.append(le16(1))                     // PCM
        out.append(le16(1))                     // mono
        out.append(le(sampleRate))
        out.append(le(sampleRate * 2))         // byte rate
        out.append(le16(2))                     // block align
        out.append(le16(16))                    // bits
        out.append(contentsOf: "data".utf8)
        out.append(le(dataLen))
        out.append(data)
        return out
    }

    private static func le(_ v: UInt32) -> Data {
        var v = v.littleEndian; return Data(bytes: &v, count: 4)
    }
    private static func le16(_ v: UInt16) -> Data {
        var v = v.littleEndian; return Data(bytes: &v, count: 2)
    }
}
