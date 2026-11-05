import AVFoundation
import XCTest
@testable import QuickScribe
@testable import QuickScribeCore

/// The second factory set and the service cleaner behind the shared interface.
final class CleanupPromptsTests: XCTestCase {
    func testServiceSetCoversAllFourModes() {
        XCTAssertEqual(Set(ServicePrompts.all.keys),
                       ["polish", "concise", "active_voice", "rewrite"])
        for (mode, text) in ServicePrompts.all {
            XCTAssertFalse(text.isEmpty, mode)
            XCTAssertFalse(text.contains("\u{2014}"), "\(mode) must not show an em dash")
            XCTAssertTrue(text.lowercased().contains("output only"), "\(mode) must demand bare text")
        }
    }

    func testServicePolishIsTheLongerSetAndApplePolishStaysShort() {
        XCTAssertGreaterThan(ServicePrompts.polish.count, FactoryPrompts.polish.count + 400,
                             "the sidecar set is the long one Apple's short prompt was not tuned for")
        XCTAssertTrue(ServicePrompts.polish.contains("publication-ready"))
        XCTAssertFalse(FactoryPrompts.polish.contains("publication-ready"),
                       "Apple's short Polish stays short")
    }

    func testPromptLibraryPicksTheFactoryByRoute() {
        let library = PromptLibrary(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qs-routes-\(UUID().uuidString).json"))
        XCTAssertEqual(library.prompt("polish", route: .apple), FactoryPrompts.polish)
        XCTAssertEqual(library.prompt("polish", route: .service), ServicePrompts.polish)
        XCTAssertEqual(library.prompt("concise", route: .service), ServicePrompts.concise)
        XCTAssertEqual(library.prompt("active_voice", route: .service), ServicePrompts.activeVoice)
        XCTAssertEqual(library.prompt("rewrite", route: .apple), FactoryPrompts.rewrite)
        XCTAssertEqual(library.prompt("rewrite", route: .service), ServicePrompts.rewrite)
    }

    func testAPersonsOwnPromptAppliesToBothRoutes() throws {
        let library = PromptLibrary(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qs-routes-\(UUID().uuidString).json"))
        try library.save("polish", text: "My own words.")
        XCTAssertEqual(library.prompt("polish", route: .apple), "My own words.")
        XCTAssertEqual(library.prompt("polish", route: .service), "My own words.")
    }



    func testEndpointCleanerRunsThroughTheSameClientShape() async throws {
        let service = try FakeService()
        try service.start()
        defer { service.stop() }
        service.queue(service.text(Self.sse("cleaned words")), forPath: "/v1/chat/completions")
        let settings = EndpointSettings(address: service.baseURL, cleanupModel: "tidier")
        let cleaner = EndpointCleaner(client: OpenAICompatClient(settings: settings, apiKey: "test-key", timeout: 5),
                                      model: "tidier")
        let out = try await cleaner.clean("raw words", instructions: "be tidy")
        XCTAssertEqual(out, "cleaned words")
        let req = try XCTUnwrap(service.lastRequest)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: req.body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "tidier")
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages[0], ["role": "system", "content": "be tidy"])
    }

    private static func sse(_ content: String) -> String {
        "data: {\"choices\":[{\"delta\":{\"content\":\"\(content)\"}}]}\n\n"
            + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
    }
}


/// One SSE chat body: a content delta, a stop line, and [DONE].
private func qsSSE(_ content: String) -> String {
    "data: {\"choices\":[{\"delta\":{\"content\":\"\(content)\"}}]}\n\n"
        + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
}
