import AVFoundation
import Foundation

/// What the session controller needs from a live recognizer. A stub can drive
/// the release path in tests without Apple's models.
public protocol SpeechAccepting: Sendable {
    func append(_ buffer: AVAudioPCMBuffer)
    func finish() async throws -> String
    func cancel()
}

extension LiveTranscription: SpeechAccepting {}

/// Connects the microphone to Apple's recognizer. Capture has to start the instant
/// the hotkey fires, but the recognizer takes a moment to come up, so early audio
/// waits here and goes in first. No words are lost to that startup gap.
public final class LiveTranscription: @unchecked Sendable {
    private let queue = DispatchQueue(label: "quickscribe.transcription")
    private var session: AppleSpeechSession?
    private var bridge: AudioFormatBridge?
    private var held: [AVAudioPCMBuffer] = []
    private var failure: Error?
    private var cancelled = false
    private var starting: Task<Void, Never>?

    public init(onUpdate: (@Sendable (String) -> Void)? = nil) {
        starting = Task { [weak self] in
            do {
                let session = try await AppleSpeechSession.start(onUpdate: onUpdate)
                self?.queue.async { self?.didStart(session) }
            } catch {
                self?.queue.async { self?.failure = error; self?.held.removeAll() }
            }
        }
    }

    /// Called on the audio thread. The engine reuses its buffer, so this keeps a copy.
    public func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copy(buffer) else { return }
        queue.async { [weak self] in
            guard let self, !self.cancelled, self.failure == nil else { return }
            if self.session == nil {
                self.held.append(copy)
            } else {
                self.feed(copy)
            }
        }
    }

    /// Finishes once every captured word has been processed.
    public func finish() async throws -> String {
        await starting?.value
        let session: AppleSpeechSession? = try await withCheckedThrowingContinuation { done in
            queue.async {
                if let failure = self.failure { done.resume(throwing: failure) } else { done.resume(returning: self.session) }
            }
        }
        return try await session?.finish() ?? ""
    }

    public func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelled = true
            self.held.removeAll()
            self.session?.cancel()
        }
    }

    private func didStart(_ session: AppleSpeechSession) {
        if cancelled { session.cancel(); return }
        self.session = session
        let waiting = held
        held.removeAll()
        waiting.forEach(feed)
    }

    private func feed(_ buffer: AVAudioPCMBuffer) {
        guard let session else { return }
        if bridge == nil { bridge = AudioFormatBridge(from: buffer.format, to: session.format) }
        if let converted = bridge?.convert(buffer) { session.feed(converted) }
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
