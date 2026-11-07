import Foundation

/// Errors with a plain sentence a person can act on. Never carries the key or
/// dictated words.
public enum EndpointError: Error, Equatable, Sendable {
    case noAddress
    case badAddress(String)
    case notReached(String)
    case unauthorized
    case notFound(String)
    case serverError(Int)
    case timedOut
    case invalidReply
    case emptyReply
    case truncated

    public var message: String {
        switch self {
        case .noAddress: return "No service address is set."
        case .badAddress(let why): return why
        case .notReached(let why): return "Could not reach the address. \(why)"
        case .unauthorized: return "The service refused the key (401). Check the API key."
        case .notFound(let what): return "The service has no \(what) address (404). Check the path, often it needs /v1."
        case .serverError(let code): return "The service failed with code \(code)."
        case .timedOut: return "The service took too long to answer."
        case .invalidReply: return "The service answered, but not in the expected form."
        case .emptyReply: return "The service answered with nothing."
        case .truncated: return "The service ran out of room mid-sentence, so the text would be cut."
        }
    }
}

/// The OpenAI-compatible calls the app makes. One place for the wire shape so
/// tests and the real service see exactly the same requests.
public struct OpenAICompatClient: Sendable {
    public var settings: EndpointSettings
    public var apiKey: String?
    /// Cleanup waits for a whole streamed answer; speech uploads a clip.
    public var timeout: TimeInterval
    private let session: URLSession

    /// One session for every client: other callers build a client per
    /// dictation, and fresh sessions each time would throw away connection
    /// reuse. Ephemeral: no cookies or cache ever touch the disk.
    public static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30      // per-call timeout rides on each request
        config.timeoutIntervalForResource = 20 * 60
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    public init(settings: EndpointSettings, apiKey: String?, timeout: TimeInterval = 30, session: URLSession? = nil) {
        self.settings = settings
        self.apiKey = apiKey
        self.timeout = timeout
        self.session = session ?? Self.sharedSession
    }

    private var base: URL {
        get throws {
            if settings.normalizedAddress.isEmpty { throw EndpointError.noAddress }
            guard let url = settings.apiBase else { throw EndpointError.badAddress("That service address does not parse. For example: http://127.0.0.1:1234/v1") }
            if let problem = settings.addressProblem { throw EndpointError.badAddress(problem) }
            return url
        }
    }

    private func request(to url: URL, method: String = "GET", body: Data? = nil, contentType: String? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let key = apiKey, !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.httpBody = body
        return req
    }

    /// Map a transport/status failure to a plain error. `what` names the call in replies.
    private static func classify(status: Int?, transport: Error?, what: String) -> EndpointError? {
        if let status {
            switch status {
            case 200...299: return nil
            case 401, 403: return .unauthorized
            case 404: return .notFound(what)
            default: return .serverError(status)
            }
        }
        if let urlError = transport as? URLError {
            switch urlError.code {
            case .timedOut: return .timedOut
            default: return .notReached(urlError.localizedDescription)
            }
        }
        if transport != nil { return .notReached("The connection failed.") }
        return nil
    }

    // MARK: - GET /models

    public func listModels() async -> [String] {
        // Used to fill pickers; a service that does not list models is fine,
        // the person types names instead. Failures read as an empty list.
        if case .success(let ids) = await checkModels() { return ids }
        return []
    }

    /// Same call, but reports why it failed. Test Connection uses this so a
    /// refused key reads differently from an address that never answered.
    public func checkModels() async -> Result<[String], EndpointError> {
        do {
            let url = try base.appendingPathComponent("models")
            let (data, response) = try await session.data(for: request(to: url))
            // One place decides what each status means; classify answers 404 too.
            guard let http = response as? HTTPURLResponse else { throw EndpointError.notFound("models") }
            if let failure = Self.classify(status: http.statusCode, transport: nil, what: "models") {
                throw failure
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["data"] as? [[String: Any]] else { return .success([]) }
            return .success(items.compactMap { $0["id"] as? String }.sorted())
        } catch let failure as EndpointError {
            return .failure(failure)
        } catch {
            return .failure(Self.classify(status: nil, transport: error, what: "models") ?? .invalidReply)
        }
    }

    // MARK: - POST /audio/transcriptions

    /// One clip's answer: the words, plus the service's own opinion about
    /// whether anyone spoke. Services that know nothing about speech
    /// detection simply leave `heardSpeech` true.
    public struct Transcription: Sendable, Equatable {
        public let text: String
        /// False only when the service says NOTHING was spoken, on every
        /// segment it reported. A service that sends no such field counts as
        /// having heard speech: silence is then decided the old way.
        public let heardSpeech: Bool
    }

    /// Above this, Whisper-style services are saying "this segment is not
    /// speech". Room noise with no words scores about 0.83 to 0.85; real
    /// speech scores about 0.004.
    static let noSpeechThreshold = 0.6

    /// Multipart upload of a wav clip, with model and language fields.
    public func transcribe(wav: Data, model: String) async throws -> String {
        try await transcribeDetailed(wav: wav, model: model).text
    }

    /// The same upload, keeping the service's no-speech verdict. The app's own
    /// dictation path uses this one so an invented "Thank you." from a noisy
    /// room never reaches the document.
    ///
    /// Some services refuse the detailed reply outright (OpenAI's
    /// gpt-4o-transcribe family is reported to answer HTTP 400, and a gateway
    /// can answer an opaque 400 too). For them this is the one retry: exactly
    /// once, immediately, with no response_format at all. Its answer is
    /// treated as a service that sends no no-speech field, so `heardSpeech` is
    /// true and the app's other rules (the silence floor, empty replies) still
    /// decide. Nothing else is retried: 401, 403, 404, 429, 5xx and transport
    /// failures surface as they are, and a second 400 surfaces too.
    public func transcribeDetailed(wav: Data, model: String) async throws -> Transcription {
        let url = try base.appendingPathComponent("audio/transcriptions")
        let first = Self.uploadBody(wav: wav, model: model, language: settings.language,
                                    responseFormat: "verbose_json",
                                    boundary: "qs-\(UUID().uuidString)")
        do {
            return try await upload(first.body, boundary: first.boundary, to: url)
        } catch let failure as EndpointError {
            guard failure == .serverError(400) else { throw failure }
            // The service will not take the field. Ask again the plain way,
            // and read its reply as one without a verdict.
            let retry = Self.uploadBody(wav: wav, model: model, language: settings.language,
                                        responseFormat: nil,
                                        boundary: "qs-\(UUID().uuidString)")
            let plain = try await upload(retry.body, boundary: retry.boundary, to: url)
            return Transcription(text: plain.text, heardSpeech: true)
        }
    }

    /// The multipart body for one upload. The response_format part is only
    /// written when asked for, so the retry is byte-for-byte the request every
    /// older build sent.
    static func uploadBody(wav: Data, model: String, language: String,
                           responseFormat: String?, boundary: String) -> (body: Data, boundary: String) {
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n")
        if !model.isEmpty {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n")
        }
        if !language.isEmpty {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n\(language)\r\n")
        }
        // verbose_json is what carries per-segment no_speech_prob. A service
        // that ignores it still answers with text, and then nothing is dropped.
        if let responseFormat {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\n\(responseFormat)\r\n")
        }
        append("--\(boundary)--\r\n")
        return (body, boundary)
    }

    /// One upload, classified. Both the first try and the retry go through
    /// here, so a retry can never be made twice or on the wrong error.
    private func upload(_ body: Data, boundary: String, to url: URL) async throws -> Transcription {
        let req = request(to: url, method: "POST", body: body,
                          contentType: "multipart/form-data; boundary=\(boundary)")
        let data: Data
        do {
            let (d, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw EndpointError.invalidReply }
            if let failure = Self.classify(status: http.statusCode, transport: nil, what: "transcription") {
                throw failure
            }
            data = d
        } catch let failure as EndpointError {
            throw failure
        } catch {
            throw Self.classify(status: nil, transport: error, what: "transcription") ?? EndpointError.invalidReply
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else { throw EndpointError.invalidReply }
        return Transcription(text: text, heardSpeech: Self.heardSpeech(in: json))
    }

    /// The service's verdict, read only where it can be trusted. A reply with
    /// no segments, or a segment without the field, gets the old behavior:
    /// whatever came back is treated as words, and the app's other rules
    /// (the silence floor, empty replies) still apply.
    static func heardSpeech(in json: [String: Any]) -> Bool {
        guard let segments = json["segments"] as? [[String: Any]], !segments.isEmpty else { return true }
        var sawField = false
        for segment in segments {
            guard let probability = segment["no_speech_prob"] as? Double else {
                return true                       // a service that does not say: no new rule
            }
            sawField = true
            if probability <= noSpeechThreshold { return true }
        }
        return !sawField
    }

    // MARK: - POST /chat/completions (streaming)

    /// Ported from an earlier version's cleanup client, which ran in production: system
    /// and user messages, streamed tokens, thinking off, and `finish_reason:
    /// length` treated as a failure because cut-off prose looks finished.
    public func clean(text: String, model: String, systemPrompt: String) async throws -> String {
        let body = try cleanBody(text: text, model: model, systemPrompt: systemPrompt, thinkingOff: true)
        let url = try base.appendingPathComponent("chat/completions")
        do {
            return try await streamChat(url: url, body: body)
        } catch let failure as CleanHTTPStatus where failure.code == 400 {
            // Some services reject unknown fields. Retry once without the
            // thinking toggle. A compatibility retry, not a safety retry.
            let retry = try cleanBody(text: text, model: model, systemPrompt: systemPrompt, thinkingOff: false)
            do {
                return try await streamChat(url: url, body: retry)
            } catch let again as CleanHTTPStatus {
                throw EndpointError.serverError(again.code)   // no third attempt
            }
        }
    }

    private struct CleanHTTPStatus: Error { let code: Int }

    private func cleanBody(text: String, model: String, systemPrompt: String, thinkingOff: Bool) throws -> Data {
        var payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
            "temperature": 0.3,
            "stream": true,
            // Headroom, not a target: a stray reasoner spends tokens on
            // thinking; a big cap costs nothing when generation stops normally.
            "max_tokens": min(4096, max(1024, text.count * 8)),
        ]
        if thinkingOff {
            payload["chat_template_kwargs"] = ["enable_thinking": false]
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func streamChat(url: URL, body: Data) async throws -> String {
        let req = request(to: url, method: "POST", body: body, contentType: "application/json")
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: req)
        } catch {
            throw Self.classify(status: nil, transport: error, what: "cleanup") ?? EndpointError.invalidReply
        }
        guard let http = response as? HTTPURLResponse else { throw EndpointError.invalidReply }
        if http.statusCode == 400 { throw CleanHTTPStatus(code: 400) }
        if let failure = Self.classify(status: http.statusCode, transport: nil, what: "cleanup") {
            throw failure
        }
        var buffer = ""
        var finish: String?
        var sawDone = false
        var sawDataLine = false
        var sawParseableChunk = false
        do {
            for try await line in bytes.lines {
                // Servers may write "data: x" or "data:x"; both are the same frame.
                guard line.hasPrefix("data:") else { continue }
                let chunk = line.dropFirst("data:".count).drop(while: { $0 == " " })
                if chunk.trimmingCharacters(in: .whitespaces) == "[DONE]" { sawDone = true; break }
                sawDataLine = true
                guard let json = try? JSONSerialization.jsonObject(with: Data(chunk.utf8)) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let choice = choices.first else { continue }
                sawParseableChunk = true
                if let reason = choice["finish_reason"] as? String { finish = reason }
                if let delta = choice["delta"] as? [String: Any], let content = delta["content"] as? String {
                    buffer += content
                }
            }
        } catch {
            // The link dropped mid-stream: report it like any other failure,
            // not as a raw networking error.
            throw Self.classify(status: nil, transport: error, what: "cleanup") ?? EndpointError.invalidReply
        }
        // Data lines that never parse as the expected shape are an invalid
        // reply; well-formed JSON with no content is an empty one.
        guard sawDataLine, sawParseableChunk else { throw EndpointError.invalidReply }
        // A stream that ends with no finish_reason and no [DONE] was cut off.
        // Counting its half-finished words as success would lose the rest.
        if finish == nil && !sawDone { throw EndpointError.truncated }
        let out = Self.withoutLineEndSpaces(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
        if out.isEmpty { throw EndpointError.emptyReply }
        if finish == "length" { throw EndpointError.truncated }
        return out
    }

    /// Models copy Markdown's invisible hard-break padding: spaces or tabs at
    /// the end of a line. Only line ends; spacing inside a line is the speaker's.
    static func withoutLineEndSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: #"[ \t]+(?=\n|$)"#, with: "", options: .regularExpression)
    }
}
