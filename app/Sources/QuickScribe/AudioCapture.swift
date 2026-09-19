import AVFoundation
import Foundation

/// AVAudioEngine capture -> 16 kHz mono int16, flushed as WAV chunks
/// every AppInfo.chunkSeconds to the onChunk callback (runbook topology:
/// the APP owns capture + streaming; the sidecar owns models).
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                              sampleRate: 16000, channels: 1, interleaved: true)!
    private var pending = Data()           // not-yet-flushed int16 LE samples
    private var totalSamples: Int64 = 0
    private var flushSamples: Int64 = 0   // samples accumulated since last flush
    private(set) var isCapturing = false

    /// Invoked on a background queue with a complete WAV file's bytes.
    var onChunk: ((Data, Double) -> Void)?

    struct CaptureError: Error { let why: String }

    private let flushQueue = DispatchQueue(label: "quickscribe.flush")

    func start() throws {
        guard !isCapturing else { return }
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
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buf, _ in
            self?.convert(buf)
        }
        isCapturing = true
    }

    private func startEngine() throws -> AVAudioFormat {
        engine.prepare()
        try engine.start()
        return engine.inputNode.outputFormat(forBus: 0)
    }

    func stop() -> Double {
        guard isCapturing else { return 0 }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
        return Double(totalSamples) / 16000.0
    }

    /// Flush any buffered audio (< chunk boundary) as the final "tail" WAV.
    /// Called on hotkey release before stop so the tail goes out immediately.
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
        flushQueue.sync {
            pending.append(bytes)
            totalSamples += Int64(out.frameLength)
            flushSamples += Int64(out.frameLength)
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
    private func emitChunkLocked() {
        guard flushSamples > 0 else { return }
        let wav = WavWriter.wav(int16LE: pending, sampleRate: 16000)
        let secs = Double(flushSamples) / 16000.0
        pending.removeAll(keepingCapacity: true)
        flushSamples = 0
        onChunk?(wav, secs)
    }
}

enum WavWriter {
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
