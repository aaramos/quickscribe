import AVFoundation
import XCTest
@testable import QuickScribeCore

/// Drives the real client against a real localhost HTTP server: every failure
/// form an address can answer with, plus the exact wire shapes this client
/// has always sent.
final class OpenAICompatClientTests: XCTestCase {
    var service: FakeService!
    var settings: EndpointSettings!
    var client: OpenAICompatClient!

    override func setUpWithError() throws {
        service = try FakeService()
        try service.start()
        settings = EndpointSettings(address: service.baseURL, speechModel: "speechy", cleanupModel: "tidier")
        client = OpenAICompatClient(settings: settings, apiKey: "test-key-local", timeout: 1.0)
    }

    override func tearDown() {
        service.stop()
        service = nil
    }

    /// SSE body with one content delta and a finish line. JSON-escapes both so
    /// content can carry newlines and spaces.
    private func sse(_ content: String, finish: String = "stop") -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
             .replacingOccurrences(of: "\n", with: "\\n")
        }
        return "data: {\"choices\":[{\"delta\":{\"content\":\"\(esc(content))\"}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"\(esc(finish))\"}]}\n\ndata: [DONE]\n\n"
    }

    // MARK: - Cleanup chat

    func testSuccessReturnsStreamedText() async throws {
        service.queue(service.text(sse("Cleaned  \ntext")), forPath: "/v1/chat/completions")
        let out = try await client.clean(text: "raw words", model: "tidier", systemPrompt: "be clean")
        XCTAssertEqual(out, "Cleaned\ntext")   // line-end spaces removed
    }

    func testRequestShapeMatchesThePortedSidecarClient() async throws {
        service.queue(service.text(sse("ok")), forPath: "/v1/chat/completions")
        _ = try await client.clean(text: String(repeating: "x", count: 200), model: "tidier", systemPrompt: "be clean")
        let req = try XCTUnwrap(service.lastRequest)
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/v1/chat/completions")
        XCTAssertEqual(req.headers["authorization"], "Bearer test-key-local")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: req.body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "tidier")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["temperature"] as? Double, 0.3)
        // min(4096, max(1024, len*8)) — 200 chars → 1600
        XCTAssertEqual(json["max_tokens"] as? Int, 1600)
        XCTAssertEqual((json["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool, false)
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0], ["role": "system", "content": "be clean"])
        XCTAssertEqual(messages[1]["role"], "user")
        XCTAssertEqual(messages[1]["content"], String(repeating: "x", count: 200))
    }

    func testThinkingRejectGetsOneRetryWithoutTheField() async throws {
        service.queue(service.text(#"{"error":"unknown field enable_thinking"}"#, status: 400), forPath: "/v1/chat/completions")
        service.queue(service.text(sse("second try")), forPath: "/v1/chat/completions")
        let out = try await client.clean(text: "words", model: "tidier", systemPrompt: "p")
        XCTAssertEqual(out, "second try")
        XCTAssertEqual(service.received.count, 2)
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: service.received[1].body) as? [String: Any])
        XCTAssertNil(second["chat_template_kwargs"], "the retry must drop the field that caused the 400")
    }

    func testSecond400IsNotRetriedForever() async throws {
        for _ in 0..<2 { service.queue(service.text("{}", status: 400), forPath: "/v1/chat/completions") }
        await XCTAssertThrowsErrorAsync(try await self.client.clean(text: "words", model: "m", systemPrompt: "p")) {
            XCTAssertEqual($0 as? EndpointError, .serverError(400))
        }
    }

    func testFinishReasonLengthIsAFailure() async throws {
        service.queue(service.text(sse("half a sent", finish: "length")), forPath: "/v1/chat/completions")
        await XCTAssertThrowsErrorAsync(try await self.client.clean(text: "words", model: "m", systemPrompt: "p")) {
            XCTAssertEqual($0 as? EndpointError, .truncated)
        }
    }

    func testEmptyContentIsAFailure() async throws {
        service.queue(service.text(sse("")), forPath: "/v1/chat/completions")
        await XCTAssertThrowsErrorAsync(try await self.client.clean(text: "words", model: "m", systemPrompt: "p")) {
            XCTAssertEqual($0 as? EndpointError, .emptyReply)
        }
    }

    func testInvalidJSONIsAFailure() async throws {
        service.queue(service.text("data: this is not json\n\ndata: [DONE]\n\n", contentType: "text/event-stream"), forPath: "/v1/chat/completions")
        await XCTAssertThrowsErrorAsync(try await self.client.clean(text: "words", model: "m", systemPrompt: "p")) {
            XCTAssertEqual($0 as? EndpointError, .invalidReply)
        }
    }

    /// The lost-words case: a stream carrying a half answer that simply stops,
    /// with no finish_reason and no [DONE]. Counting it as success would paste
    /// a half sentence and call the dictation done.
    func testStreamEndingWithNoProperCloseIsTruncated() async throws {
        service.queue(service.text("data: {\"choices\":[{\"delta\":{\"content\":\"The total is\"}}]}\n\n",
                                   contentType: "text/event-stream"), forPath: "/v1/chat/completions")
        await XCTAssertThrowsErrorAsync(try await self.client.clean(text: "words", model: "m", systemPrompt: "p")) {
            XCTAssertEqual($0 as? EndpointError, .truncated)
        }
    }

    /// [DONE] counts as a proper close even when no finish_reason arrived.
    func testDoneMarkerAloneClosesTheStream() async throws {
        service.queue(service.text("data: {\"choices\":[{\"delta\":{\"content\":\"whole answer\"}}]}\n\ndata: [DONE]\n\n",
                                   contentType: "text/event-stream"), forPath: "/v1/chat/completions")
        let out = try await client.clean(text: "words", model: "m", systemPrompt: "p")
        XCTAssertEqual(out, "whole answer")
    }

    /// Some servers write the frame without a space after the colon.
    func testDataWithoutSpaceAfterColonParses() async throws {
        service.queue(service.text("data:{\"choices\":[{\"delta\":{\"content\":\"no space\"}}]}\n\ndata:[DONE]\n\n",
                                   contentType: "text/event-stream"), forPath: "/v1/chat/completions")
        let out = try await client.clean(text: "words", model: "m", systemPrompt: "p")
        XCTAssertEqual(out, "no space")
    }

    /// The link dying between chunks reports as a plain EndpointError, never a
    /// raw URLSession error.
    func testConnectionDroppedMidStreamIsAnEndpointError() async throws {
        service.queue(FakeService.Rule(contentType: "text/event-stream",
                                       body: Data("data: {\"choices\":[{\"delta\":{\"content\":\"half\"}}]}\n\n".utf8),
                                       cutShort: true), forPath: "/v1/chat/completions")
        await XCTAssertThrowsErrorAsync(try await self.client.clean(text: "words", model: "m", systemPrompt: "p")) { error in
            guard let e = error as? EndpointError else { return XCTFail("raw error leaked: \(error)") }
            XCTAssertTrue(e.message.hasPrefix("Could not reach the address."), e.message)
        }
    }

    // MARK: - Status codes

    func test401MeansBadKey() async throws {
        service.queue(service.text("{}", status: 401), forPath: "/v1/chat/completions")
        await XCTAssertThrowsErrorAsync(try await self.client.clean(text: "w", model: "m", systemPrompt: "p")) {
            XCTAssertEqual($0 as? EndpointError, .unauthorized)
        }
    }

    func test404NamesTheMissingEndpoint() async throws {
        // No rule queued: the fake answers 404.
        await XCTAssertThrowsErrorAsync(try await self.client.clean(text: "w", model: "m", systemPrompt: "p")) {
            XCTAssertEqual($0 as? EndpointError, .notFound("cleanup"))
        }
    }

    func test500IsReportedPlainly() async throws {
        service.queue(service.text("{}", status: 500), forPath: "/v1/chat/completions")
        await XCTAssertThrowsErrorAsync(try await self.client.clean(text: "w", model: "m", systemPrompt: "p")) {
            XCTAssertEqual($0 as? EndpointError, .serverError(500))
        }
    }

    func testTimeoutIsReportedPlainly() async throws {
        service.queue(service.text(sse("late"), delay: 3), forPath: "/v1/chat/completions")
        await XCTAssertThrowsErrorAsync(try await self.client.clean(text: "w", model: "m", systemPrompt: "p")) {
            XCTAssertEqual($0 as? EndpointError, .timedOut)
        }
    }

    func testNothingListeningIsNotReached() async throws {
        let dead = OpenAICompatClient(settings: EndpointSettings(address: "http://127.0.0.1:1/v1"), apiKey: nil, timeout: 0.5)
        await XCTAssertThrowsErrorAsync(try await dead.clean(text: "w", model: "m", systemPrompt: "p")) {
            XCTAssertTrue(($0 as? EndpointError)?.message.hasPrefix("Could not reach the address.") ?? false, "\($0)")
        }
    }

    // MARK: - Speech

    func testTranscriptionSendsMultipartWithModelAndLanguage() async throws {
        service.queue(service.text(#"{"text":"fourteen hundred fifty"}"#), forPath: "/v1/audio/transcriptions")
        let wav = Data([0x52, 0x49, 0x46, 0x46]) + Data(repeating: 0, count: 40)
        let text = try await client.transcribe(wav: wav, model: "speechy")
        XCTAssertEqual(text, "fourteen hundred fifty")
        let req = try XCTUnwrap(service.lastRequest)
        XCTAssertEqual(req.path, "/v1/audio/transcriptions")
        XCTAssertTrue(req.headers["content-type"]?.hasPrefix("multipart/form-data; boundary=") ?? false)
        let body = String(decoding: req.body, as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"audio.wav\""), body)
        XCTAssertTrue(body.contains("Content-Type: audio/wav"), body)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nspeechy"), body)
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\n\(settings.language)"), body)
        XCTAssertFalse(settings.language.isEmpty, "custom speech follows the Mac's language, it is never blank")
        XCTAssertTrue(req.body.range(of: wav) != nil, "the clip itself must be in the body")
        XCTAssertEqual(req.headers["authorization"], "Bearer test-key-local")
    }

    /// The whole recording's path in miniature: captured buffers become a whole WAV and
    /// reach the service as the upload file, in the app's own multipart shape.
    func testWholeRecordingUploadsAsTheTranscriptionFile() async throws {
        service.queue(service.text(#"{"text":"fourteen hundred fifty"}"#), forPath: "/v1/audio/transcriptions")
        let rec = RecordingBuffer()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        for _ in 0..<4 {                       // 0.4 s across four capture callbacks
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
            b.frameLength = 4_800
            rec.append(b)
        }
        let (clip, overflowed) = rec.wav()
        XCTAssertFalse(overflowed)
        let text = try await client.transcribe(wav: clip, model: "speechy")
        XCTAssertEqual(text, "fourteen hundred fifty")
        let req = try XCTUnwrap(service.lastRequest)
        XCTAssertEqual(req.path, "/v1/audio/transcriptions")
        XCTAssertTrue(req.body.range(of: clip) != nil, "the whole clip must arrive as one file, unchanged")
    }

    func testTranscriptionEmptyReplyAndBadJSON() async throws {
        service.queue(service.text("{}"), forPath: "/v1/audio/transcriptions")
        await XCTAssertThrowsErrorAsync(try await self.client.transcribe(wav: Data([1]), model: "m")) {
            XCTAssertEqual($0 as? EndpointError, .invalidReply)
        }
        service.queue(service.text("", contentType: "text/plain"), forPath: "/v1/audio/transcriptions")
        await XCTAssertThrowsErrorAsync(try await self.client.transcribe(wav: Data([1]), model: "m")) {
            XCTAssertEqual($0 as? EndpointError, .invalidReply)
        }
    }

    // MARK: - Models

    func testModelListFromAFriendlyService() async throws {
        service.queue(service.text(#"{"data":[{"id":"b-model"},{"id":"a-model"},{"nodata":1}]}"#), forPath: "/v1/models")
        let ids = await client.listModels()
        XCTAssertEqual(ids, ["a-model", "b-model"])
    }

    func testModelListEmptyOnFailureIsEmptyNotNull() async {
        service.queue(service.text("{}", status: 500), forPath: "/v1/models")
        let ids = await client.listModels()
        XCTAssertTrue(ids.isEmpty)
    }

    // MARK: - Address rules

    func testEmptyAddressMeansApple() {
        let s = EndpointSettings()
        XCTAssertFalse(s.isEnabled)
        XCTAssertNil(s.addressProblem)
    }

    func testNonLocalPlainHTTPIsRefused() {
        var s = EndpointSettings(address: "http://example.com/v1")
        XCTAssertNotNil(s.addressProblem)
        XCTAssertTrue(s.addressProblem!.contains("unencrypted"))
        s = EndpointSettings(address: "https://example.com/v1")
        XCTAssertNil(s.addressProblem)
    }

    func testLocalPlainHTTPIsAllowed() {
        for a in ["http://127.0.0.1:1234/v1", "http://localhost:1234", "http://192.168.1.20:1234/v1", "http://my-mac.local:1234/v1"] {
            XCTAssertNil(EndpointSettings(address: a).addressProblem, a)
        }
    }

    /// Names that only look like private numbers are not local. Trusted
    /// prefixes there would let a public host skip both the refusal and the
    /// words-leave-the-Mac warning.
    func testFakePrivateNumbersAreNotLocal() {
        for host in ["127.evil.com", "10.0.0.1.evil.com", "192.168.1.1.attacker.net", "127.1", "127.0.0.1.example.org"] {
            XCTAssertFalse(EndpointSettings.isLocal(host: host), host)
            var s = EndpointSettings(address: "http://\(host):1234/v1")
            XCTAssertNotNil(s.addressProblem, "plain http to \(host) must be refused")
        }
    }

    func testOnlyRealPrivateNumbersAreLocal() {
        for host in ["127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.86.48", "169.254.1.2", "localhost", "server.local", "::1"] {
            XCTAssertTrue(EndpointSettings.isLocal(host: host), host)
        }
        for host in ["172.15.0.1", "172.32.0.1", "8.8.8.8", "1.1.1.1", "256.1.1.1", "10.0.0", "10.0.0.1.2", "10.0.0.-1", "010.0.0.1", "10.0.0.999", "evil.com"] {
            XCTAssertFalse(EndpointSettings.isLocal(host: host), host)
        }
    }

    func testBaseAddsV1OnlyWhenNoPath() {
        XCTAssertEqual(EndpointSettings(address: "http://127.0.0.1:1234").apiBase?.path, "/v1")
        XCTAssertEqual(EndpointSettings(address: "http://127.0.0.1:1234/v1/").apiBase?.path, "/v1")
        XCTAssertEqual(EndpointSettings(address: "http://127.0.0.1:1234/other").apiBase?.path, "/other")
    }

    func testClientRefusesNonLocalPlainHTTPBeforeSending() async {
        let c = OpenAICompatClient(settings: EndpointSettings(address: "http://example.com"), apiKey: "k", timeout: 1)
        await XCTAssertThrowsErrorAsync(try await c.clean(text: "w", model: "m", systemPrompt: "p")) {
            guard case .badAddress = ($0 as? EndpointError) else { return XCTFail("\($0)") }
        }
    }
}

func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure @escaping () async throws -> T,
                                  _ evaluate: (Error) -> Void = { _ in }) async {
    do {
        _ = try await expression()
        XCTFail("expected a failure, got a result")
    } catch {
        evaluate(error)
    }
}
