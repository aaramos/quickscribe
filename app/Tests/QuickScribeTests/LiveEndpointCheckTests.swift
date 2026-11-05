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
            let started = Date()
            let text = try await client.transcribe(wav: d, model: audioModel)
            print("MEASURE \(wavPath) seconds=\(String(format: "%.1f", Double(d.count - 44) / 32_000)) waited=\(String(format: "%.1f", Date().timeIntervalSince(started)))")
            print("TEXT \(text)")
            return   // a measurement run: speech only
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
}
