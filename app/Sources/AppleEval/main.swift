import AVFoundation
import Foundation
import QuickScribeCore

// Compares Apple's speech and cleanup with today's QuickScribe on the same
// scripted dictations. Usage:
//   apple-eval speech <corpus.json> <audio-dir>               -> JSON lines
//   apple-eval clean <corpus.json> <variant>                  -> JSON lines
//       variants: rules | polish | concise | active_voice | rewrite
//       ... or service_polish and friends, which run the person's service
//       (address QSE_BASE, model QSE_MODEL, key QSE_KEY or key file
//       QSE_KEYFILE, defaulting to the local server and its settings file)
//   apple-eval limits
//   apple-eval live <file.wav> ...

struct Item: Decodable { let id: String; let raw: String }

func corpus(_ path: String) throws -> [Item] {
    try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
}

func emit(_ row: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}

func transcribe(file: URL) async throws -> (String, Double, Double) {
    let audio = try AVAudioFile(forReading: file)
    let duration = Double(audio.length) / audio.processingFormat.sampleRate
    let session = try await AppleSpeechSession.start()
    guard let bridge = AudioFormatBridge(from: audio.processingFormat, to: session.format) else {
        throw SpeechFailure.noAudioFormat
    }
    let start = Date()
    let frames: AVAudioFrameCount = 4096
    while audio.framePosition < audio.length {
        let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: frames)!
        try audio.read(into: buffer, frameCount: frames)
        if let converted = bridge.convert(buffer) { session.feed(converted) }
    }
    let text = try await session.finish()
    return (text, duration, Date().timeIntervalSince(start))
}

func runSpeech(_ args: [String]) async throws {
    try await AppleSpeechSession.ensureInstalled()
    for item in try corpus(args[0]) {
        let file = URL(fileURLWithPath: args[1]).appendingPathComponent("\(item.id).wav")
        do {
            let (text, duration, seconds) = try await transcribe(file: file)
            emit(["id": item.id, "text": text, "audio_s": duration, "seconds": seconds])
        } catch {
            emit(["id": item.id, "error": "\(error)"])
        }
    }
}

func instructions(_ variant: String) -> (String?, AppleCleaner.Filter) {
    switch variant {
    case "rules": return (nil, .permissive)
    case "polish": return (FactoryPrompts.polish, .permissive)
    case "concise": return (FactoryPrompts.concise, .permissive)
    case "active_voice": return (FactoryPrompts.activeVoice, .permissive)
    case "rewrite": return (FactoryPrompts.rewrite, .permissive)
    case "service_polish": return (ServicePrompts.polish, .permissive)
    case "service_concise": return (ServicePrompts.concise, .permissive)
    case "service_active_voice": return (ServicePrompts.activeVoice, .permissive)
    case "service_rewrite": return (ServicePrompts.rewrite, .permissive)
    default: fatalError("unknown variant \(variant)")
    }
}

/// "service_polish" checks the same guard as "polish".
func guardMode(_ variant: String) -> String {
    variant.hasPrefix("service_") ? String(variant.dropFirst("service_".count)) : variant
}

func serviceCleaner() -> any Cleaning {
    let env = ProcessInfo.processInfo.environment
    let address = env["QSE_BASE"] ?? "http://127.0.0.1:1234/v1"
    let model = env["QSE_MODEL"] ?? ""
    var key = env["QSE_KEY"]
    if key == nil {
        let path = (env["QSE_KEYFILE"] ?? "~/.omlx/settings.json")
            .replacingOccurrences(of: "~", with: NSHomeDirectory())
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let auth = json["auth"] as? [String: Any] {
            key = auth["api_key"] as? String
        }
    }
    let settings = EndpointSettings(address: address, cleanupModel: model, useCustomCleanup: true)
    return EndpointCleaner(client: OpenAICompatClient(settings: settings, apiKey: key, timeout: 120),
                           model: model)
}

func runClean(_ args: [String]) async throws {
    let variant = args[1]
    let (prompt, filter) = instructions(variant)
    let cleaner: any Cleaning = variant.hasPrefix("service_") ? serviceCleaner() : AppleCleaner(filter: filter)
    for item in try corpus(args[0]) {
        let tidied = TextCleanup.tidy(item.raw)
        guard let prompt else {
            emit(["id": item.id, "text": tidied, "seconds": 0.0])
            continue
        }
        let start = Date()
        do {
            let text = try await cleaner.clean(tidied, instructions: prompt)
            let seconds = Date().timeIntervalSince(start)
            if CleanupGuard.accepts(output: text, input: tidied, mode: guardMode(variant)) {
                emit(["id": item.id, "text": text, "seconds": seconds])
            } else {
                emit(["id": item.id, "text": tidied, "seconds": seconds, "guarded": text])
            }
        } catch {
            emit(["id": item.id, "error": "\(error)", "seconds": Date().timeIntervalSince(start)])
        }
    }
}

/// How long can a dictation get before it stops fitting, with the short prompt
/// and with the longest prompt the settings screen allows?
func runLimits() async {
    let cleaner = AppleCleaner()
    emit(["context_size": cleaner.contextSize, "unavailable": AppleCleaner.unavailableReason() ?? "none"])
    let sentence = "We should move the meeting to Thursday because the flight lands late and nobody can join before ten. "
    let longPrompt = String(repeating: "Keep every fact, name and number exactly as the speaker said it. ",
                            count: 122)
    for (name, prompt) in [("short", FactoryPrompts.polish), ("concise", FactoryPrompts.concise), ("longest_allowed", longPrompt)] {
        for words in [100, 500] {
            let text = String(repeating: sentence, count: words / 18)
            let start = Date()
            do {
                let out = try await cleaner.clean(text, instructions: prompt)
                emit(["prompt": name, "dictation_words": words, "result": "ok", "out_chars": out.count,
                      "in_chars": text.count, "seconds": Date().timeIntervalSince(start)])
            } catch {
                emit(["prompt": name, "dictation_words": words, "result": "\(error)",
                      "seconds": Date().timeIntervalSince(start)])
            }
        }
    }
}

/// The app's own path at real speed: audio arrives as if spoken, starting before the
/// recognizer is up. Times what a person feels after releasing the hotkey.
func runLive(_ paths: [String]) async throws {
    if let reason = AppleCleaner.unavailableReason() { print("cleanup unavailable:", reason) }
    let warmStart = Date()
    try await AppleSpeechSession.prewarm()
    emit(["prewarm_seconds": Date().timeIntervalSince(warmStart)])
    for path in paths {
        let audio = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let began = Date()
        let firstWords = FirstWords()
        let live = LiveTranscription { words in if !words.isEmpty { firstWords.mark() } }
        let chunk: AVAudioFrameCount = 1024
        let seconds = Double(chunk) / audio.processingFormat.sampleRate
        while audio.framePosition < audio.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: chunk)!
            try audio.read(into: buffer, frameCount: chunk)
            live.append(buffer)
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        let released = Date()
        let raw = try await live.finish()
        let transcribed = Date()
        let tidied = TextCleanup.tidy(raw)
        let cleaned = try await AppleCleaner().clean(tidied, instructions: FactoryPrompts.polish)
        emit(["file": URL(fileURLWithPath: path).lastPathComponent,
              "first_words_after_start_s": firstWords.seconds(since: began) ?? -1,
              "speech_after_release_s": transcribed.timeIntervalSince(released),
              "total_after_release_s": Date().timeIntervalSince(released),
              "output": cleaned])
    }
}

final class FirstWords: @unchecked Sendable {
    private let lock = NSLock()
    private var at: Date?
    func mark() { lock.lock(); if at == nil { at = Date() }; lock.unlock() }
    func seconds(since start: Date) -> Double? { lock.lock(); defer { lock.unlock() }; return at?.timeIntervalSince(start) }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "speech": try await runSpeech(Array(arguments.dropFirst()))
case "clean": try await runClean(Array(arguments.dropFirst()))
case "limits": await runLimits()
case "live": try await runLive(Array(arguments.dropFirst()))
default: print("usage: apple-eval speech|clean|limits|live ...")
}
