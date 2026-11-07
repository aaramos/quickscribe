import AVFoundation
import XCTest
@testable import QuickScribe
@testable import QuickScribeCore

/// A live check against a real OpenAI-compatible server, run only when asked
/// for by setting the environment. Everything machine-specific comes from the
/// environment with no defaults; the key is read inside the process from the
/// named file and NEVER printed or stored.
///
///     QS_LIVE=1 QSWIFT_BASE=<url> QSWIFT_KEYFILE=<json file> \
///     QSWIFT_AUDIO_MODEL=<name> QSWIFT_CLEANUP_MODEL=<name> swift test
///
/// Synthetic checks have passed before while real use failed, so the app's
/// exact request shapes go over the wire here, one request at a time.
final class LiveEndpointCheckTests: XCTestCase {
    private func liveConfig() -> (base: String, key: String)? {
        let env = ProcessInfo.processInfo.environment
        guard env["QS_LIVE"] == "1",
              let base = env["QSWIFT_BASE"], !base.isEmpty,
              let keyPath = env["QSWIFT_KEYFILE"], !keyPath.isEmpty,
              let data = FileManager.default.contents(atPath: (keyPath as NSString).expandingTildeInPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = json["auth"] as? [String: Any],
              let key = auth["api_key"] as? String, !key.isEmpty
        else { return nil }
        return (base, key)
    }

    func testLiveSpeechAndCleanupShapes() async throws {
        guard let live = liveConfig() else { throw XCTSkip("live check not requested") }
        let env = ProcessInfo.processInfo.environment
        guard let audioModel = env["QSWIFT_AUDIO_MODEL"], !audioModel.isEmpty,
              let cleanupModel = env["QSWIFT_CLEANUP_MODEL"], !cleanupModel.isEmpty
        else { throw XCTSkip("live check needs both model names from the environment") }
        let settings = EndpointSettings(address: live.base, speechModel: audioModel, cleanupModel: cleanupModel)
        let client = OpenAICompatClient(settings: settings, apiKey: live.key, timeout: 120)

        // 1. Models list (cheap, does not wake a model).
        switch await client.fetchModels() {
        case .success(let entries):
            let ids = entries.map(\.id)
            XCTAssertFalse(ids.isEmpty, "the live server lists no models")
            XCTAssertTrue(ids.contains(audioModel), "\(audioModel) is not offered")
            XCTAssertTrue(ids.contains(cleanupModel), "\(cleanupModel) is not offered")
        case .failure(let e):
            XCTFail("models: \(e.message)")
        }

        // 2. Speech, in the app's exact multipart shape.
        do {
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
