import AVFoundation
import Foundation
import Speech

public enum SpeechFailure: Error, Equatable, Sendable {
    case languageUnsupported
    case noAudioFormat
}

/// One dictation through Apple's on-device speech recognition. Audio goes in as
/// it is captured; words come back as they settle.
public final class AppleSpeechSession: @unchecked Sendable {
    /// Audio must arrive in this format.
    public let format: AVAudioFormat

    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let collector: Task<String, Error>

    private init(format: AVAudioFormat, analyzer: SpeechAnalyzer,
                 input: AsyncStream<AnalyzerInput>.Continuation, collector: Task<String, Error>) {
        self.format = format
        self.analyzer = analyzer
        self.input = input
        self.collector = collector
    }

    /// Builds and starts a session. `onUpdate` gets the words so far, for display only.
    public static func start(locale: Locale = .current,
                             onUpdate: (@Sendable (String) -> Void)? = nil) async throws -> AppleSpeechSession {
        let (module, collector) = try await makeModule(locale: locale, onUpdate: onUpdate)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            collector.cancel()
            throw SpeechFailure.noAudioFormat
        }
        // Keeping the model loaded between dictations is what makes the next one quick.
        let analyzer = SpeechAnalyzer(modules: [module],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: stream)
        return AppleSpeechSession(format: format, analyzer: analyzer, input: continuation, collector: collector)
    }

    /// Downloads the language model through the OS when it isn't installed yet. The
    /// download is Apple's, shared across apps, and doesn't add to this app's size.
    public static func ensureInstalled(locale: Locale = .current) async throws {
        let (module, collector) = try await makeModule(locale: locale, onUpdate: nil)
        collector.cancel()
        if await AssetInventory.status(forModules: [module]) == .installed { return }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    /// Loads the recognizer ahead of the first dictation.
    public static func prewarm(locale: Locale = .current) async throws {
        let (module, collector) = try await makeModule(locale: locale, onUpdate: nil)
        defer { collector.cancel() }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw SpeechFailure.noAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [module],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        try await analyzer.prepareToAnalyze(in: format)
        await analyzer.cancelAndFinishNow()
    }

    public func feed(_ buffer: AVAudioPCMBuffer) {
        input.yield(AnalyzerInput(buffer: buffer))
    }

    /// Ends the audio and returns the finished transcript.
    public func finish() async throws -> String {
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    public func cancel() {
        input.finish()
        collector.cancel()
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }

    /// SpeechTranscriber rather than DictationTranscriber: in testing it punctuated
    /// and made fewer errors, while DictationTranscriber barely punctuated at all.
    private static func makeModule(locale: Locale,
                                   onUpdate: (@Sendable (String) -> Void)?) async throws -> (any SpeechModule, Task<String, Error>) {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SpeechFailure.languageUnsupported
        }
        let module = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        let results = module.results
        return (module, Task {
            var assembler = TranscriptAssembler()
            for try await result in results {
                let words = assembler.add(String(result.text.characters), isFinal: result.isFinal)
                onUpdate?(words)
            }
            return assembler.finished
        })
    }
}

/// Settled words stay; the words still being worked out get replaced by each update.
public struct TranscriptAssembler: Sendable {
    private var settled = ""
    private var pending = ""

    public init() {}

    public mutating func add(_ text: String, isFinal: Bool) -> String {
        if isFinal {
            settled += text
            pending = ""
        } else {
            pending = text
        }
        return Self.normalized(settled + pending)
    }

    public var finished: String { Self.normalized(settled + pending) }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Converts captured or file audio to the format the recognizer asked for.
public final class AudioFormatBridge {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat

    public init?(from source: AVAudioFormat, to target: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
        self.converter = converter
        self.target = target
    }

    public func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        let status = converter.convert(to: out, error: nil) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }
}
