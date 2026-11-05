import AVFoundation
import XCTest
@testable import QuickScribe
@testable import QuickScribeCore

/// A live check against a real OpenAI-compatible server, run only when asked
/// for by setting the environment. The key is read from the local settings
/// file inside the process and NEVER printed or stored.
///
///     QS_LIVE_OMLX=1 QSWIFT_AUDIO_MODEL=<name> QSWIFT_CLEANUP_MODEL=<name> swift test
///
/// Synthetic checks have passed before while real use failed, so the app's
/// exact request shapes go over the wire here, one request at a time.
final class LiveEndpointCheckTests: XCTestCase {
    private func liveConfig() -> (base: String, key: String)? {
        guard ProcessInfo.processInfo.environment["QS_LIVE_OMLX"] == "1" else { return nil }
        let settingsPath = ("~/.omlx/settings.json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = json["auth"] as? [String: Any],
              let key = auth["api_key"] as? String, !key.isEmpty
        else { return nil }
        return ("http://127.0.0.1:1234/v1", key)
    }

    func testLiveSpeechAndCleanupShapes() async throws {
        guard let live = liveConfig() else { throw XCTSkip("live check not requested") }
        let audioModel = ProcessInfo.processInfo.environment["QSWIFT_AUDIO_MODEL"] ?? "whisper-large-v3-turbo-4bit"
        let cleanupModel = ProcessInfo.processInfo.environment["QSWIFT_CLEANUP_MODEL"] ?? "Qwen3.6-35B-A3B-4bit"
        let settings = EndpointSettings(address: live.base, speechModel: audioModel, cleanupModel: cleanupModel)
        let client = OpenAICompatClient(settings: settings, apiKey: live.key, timeout: 120)

        // 1. Models list (cheap, does not wake a model).
        switch await client.checkModels() {
        case .success(let ids):
            XCTAssertFalse(ids.isEmpty, "the live server lists no models")
            XCTAssertTrue(ids.contains(audioModel), "\(audioModel) is not offered")
            XCTAssertTrue(ids.contains(cleanupModel), "\(cleanupModel) is not offered")
        case .failure(let e):
            XCTFail("models: \(e.message)")
        }

        // 2. Speech, in the app's exact multipart shape. With QSWIFT_WAV set the
        // words go to stdout: a one-off measurement run the owner asked for,
        // on synthetic clips, not recorded dictation.
        if let wavPath = ProcessInfo.processInfo.environment["QSWIFT_WAV"],
           let d = FileManager.default.contents(atPath: (wavPath as NSString).expandingTildeInPath) {
            // Measure the WHOLE release path the app takes: feed the clip the
            // way capture would, run processRelease (the finish() ordering
            // from fix 4), and time until text reaches the inserter.
            let (seconds, waited, text) = try await measureThroughRelease(wav: d, live: live, audioModel: audioModel)
            print("MEASURE \(wavPath) seconds=\(String(format: "%.1f", seconds)) waited=\(String(format: "%.1f", waited))")
            print("TEXT \(text)")
            return   // a measurement run: this path only
        } else {
            let text = try await client.transcribe(wav: SettingsWindow.silenceWAV(), model: audioModel)
            print("LIVE speech reply chars:", text.count)  // words are NOT logged
        }

        // 3. Cleanup, the ported streaming body, one real sentence.
        do {
            let out = try await client.clean(
                text: "Um so the invoice total is fourteen hundred and fifty dollars, due March twelfth.",
                model: cleanupModel,
                systemPrompt: "Remove filler words. Keep every number and date exactly. Output only the text.")
            XCTAssertFalse(out.isEmpty)
            XCTAssertTrue(out.contains("1450") || out.lowercased().contains("fourteen hundred"),
                          "cleanup must keep the number; reply shape differs")
            XCTAssertTrue(out.contains("March") || out.contains("3") || out.contains("twelfth"),
                          "cleanup must keep the date")
            print("LIVE cleanup reply chars:", out.count)
        } catch {
            XCTFail("cleanup: \((error as? EndpointError)?.message ?? "\(error)")")
        }
    }

    // MARK: - The full release path, end to end

    /// A recognizer stub: the real mic is not involved in a file measurement.
    private final class QuietSpeech: SpeechAccepting, @unchecked Sendable {
        func append(_ buffer: AVAudioPCMBuffer) {}
        func finish() async throws -> String { "" }
        func cancel() {}
    }

    private final class InsertBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        func got(_ text: String) { lock.lock(); stored = text; lock.unlock() }
        var value: String? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    @MainActor
    private func measureThroughRelease(wav: Data, live: (base: String, key: String),
                                       audioModel: String) async throws
        -> (seconds: Double, waited: Double, text: String) {
        let suite = "quickscribe.live.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(live.base, forKey: "endpoint.address")
        defaults.set(audioModel, forKey: "endpoint.speechModel")
        defaults.set(true, forKey: "endpoint.useCustomSpeech")
        let store = EndpointSettingsStore(defaults: defaults, secrets: MemorySecrets.Store(live.key))
        let prompts = PromptLibrary(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qs-live-\(UUID().uuidString).json"))
        let session = SessionController(prompts: prompts, endpointStore: store)
        session.silentSessionOverride = false
        session.targetReader = { .textField }
        let box = InsertBox()
        session.textInserter = { text, done in box.got(text); done(true, false) }
        session.transcription = QuietSpeech()
        session.armRecording()
        // Feed the clip the way capture would: real file buffers, half-second chunks.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("qs-live-\(UUID().uuidString).wav")
        try wav.write(to: tmp)
        let file = try AVAudioFile(forReading: tmp)
        let total = AVAudioFrameCount(file.length)
        let chunk: AVAudioFrameCount = 22_050
        var offset: AVAudioFrameCount = 0
        while offset < total {
            let n = min(chunk, total - offset)
            let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n)!
            try file.read(into: b, frameCount: n)
            session.recording?.append(b)
            offset += n
        }
        try? FileManager.default.removeItem(at: tmp)
        let start = Date()
        session.processRelease(customChosen: true, silent: false, live: QuietSpeech())
        let deadline = start.addingTimeInterval(60)
        while box.value == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let waited = Date().timeIntervalSince(start)
        defaults.removePersistentDomain(forName: suite)
        guard let text = box.value else {
            XCTFail("nothing reached the inserter within 60 s")
            return (Double(wav.count - 44) / 32_000, waited, "<none>")
        }
        return (Double(wav.count - 44) / 32_000, waited, text)
    }
}
