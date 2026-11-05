import AVFoundation
import Foundation

/// Holds the whole dictation in memory as it is captured, and produces one
/// WAV of it on release. Cutting speech into pieces is what mangled numbers
/// in the old build, so the final text comes from a single whole recording.
///
/// Audio never leaves memory: nothing here writes a file.
public final class RecordingBuffer: @unchecked Sendable {
    public static let sampleRate: Double = 16_000
    /// Anything past this is refused out loud rather than dropped in silence.
    public var maxSeconds: Double = 300.0

    private let queue = DispatchQueue(label: "quickscribe.recording-buffer")
    private var bridge: AudioFormatBridge?
    private var samples: [Int16] = []
    private var cancelled = false

    public init() {}

    /// True once audio arrived after the limit. The captured words still make
    /// a valid clip; the person has to be told the rest is missing.
    public private(set) var didOverflow: Bool = false

    public var seconds: Double {
        queue.sync { Double(samples.count) / Self.sampleRate }
    }

    /// Called from the audio thread. The engine reuses its buffer, so a copy
    /// is made before the work hops to the queue.
    public func append(_ buffer: AVAudioPCMBuffer) {
        guard let initial = Self.copy(buffer) else { return }
        queue.async { [weak self] in
            guard let self, !self.cancelled else { return }
            var copy = initial
            // A buffer already 16 kHz mono goes straight in; the converter is
            // only for formats that differ.
            if copy.format.sampleRate != Self.sampleRate || copy.format.channelCount != 1 {
                if self.bridge == nil {
                    self.bridge = AudioFormatBridge(from: copy.format,
                                                    to: AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!)
                }
                guard let converted = self.bridge?.convert(copy) else { return }
                copy = converted
            }
            guard let pcm = Self.int16(copy) else { return }
            let space = Int(self.maxSeconds * Self.sampleRate) - self.samples.count
            if space <= 0 {
                self.didOverflow = true
            } else if pcm.count > space {
                self.samples.append(contentsOf: pcm.prefix(space))
                self.didOverflow = true
            } else {
                self.samples.append(contentsOf: pcm)
            }
        }
    }

    /// The clip, and whether it was cut by the limit. Blocks until every
    /// append so far is in: the caller is about to read the recording.
    public func wav() -> (data: Data, overflowed: Bool) {
        queue.sync { (Self.wavData(samples), didOverflow) }
    }

    /// Clears and stops accepting appends: a recording that is gone must not
    /// grow again from buffers that were already in flight.
    public func discard() {
        queue.sync {
            self.cancelled = true
            self.samples.removeAll()
            self.didOverflow = false
        }
    }

    // MARK: - Encoding

    static func wavData(_ samples: [Int16]) -> Data {
        let pcm = samples.count * 2
        var data = Data(capacity: 44 + pcm)
        func ascii(_ s: String) { data.append(Data(s.utf8)) }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(36 + pcm); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1)
        u32(Int(sampleRate)); u32(Int(sampleRate) * 2); u16(2); u16(16)
        ascii("data"); u32(pcm)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// Float frames, clamped, first channel, little-endian 16-bit.
    private static func int16(_ buffer: AVAudioPCMBuffer) -> [Int16]? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        let count = Int(buffer.frameLength)
        var out = [Int16]()
        out.reserveCapacity(count)
        for i in 0..<count {
            let v = max(-1.0, min(1.0, channel[i]))
            out.append(Int16(v >= 0 ? v * 32767.0 : v * 32768.0))
        }
        return out
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        out.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let src = from.mData, let dst = to.mData else { return nil }
            memcpy(dst, src, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return out
    }
}
