import Foundation

/// Minimal client for the QuickScribe sidecar (runbook §Contracts).
/// Localhost only — no other hosts, ever (brief AC8).
final class SidecarClient {
    static let shared = SidecarClient()
    private init() {}

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    struct Health: Decodable { let status: String; let stt_ready: Bool; let llm_ready: Bool; var model: String? }
    struct Transcript: Decodable { let text: String; let language: String; var ms: Int? }
    struct Polished: Decodable { let text: String; let degraded: Bool }
    struct CaptureEntry: Decodable { let raw: String; let polished: String; let profile: String; let ts: Double }
    struct ModelList: Decodable { let models: [String]; let current: String }
    struct ModelSwitch: Decodable { let ok: Bool; let model: String }

    func health(timeout: TimeInterval = 2, completion: @escaping (Health?) -> Void) {
        get("/health", timeout: timeout) { (data: Data?) in
            guard let data = data else { completion(nil); return }
            completion(try? JSONDecoder().decode(Health.self, from: data))
        }
    }

    /// POST /transcribe — multipart wav. partial=true for in-flight chunks.
    /// Completion carries (text?, sttMs).
    func transcribe(wav: Data, partial: Bool, timeout: TimeInterval = 8,
                    completion: @escaping (String?, Int) -> Void) {
        let boundary = "qs-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        guard let url = URL(string: "\(AppInfo.sidecarBase)/transcribe?partial=\(partial ? "true" : "false")") else {
            completion(nil, 0); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        session.dataTask(with: req) { data, _, _ in
            guard let data = data, let t = try? JSONDecoder().decode(Transcript.self, from: data) else {
                completion(nil, 0); return
            }
            completion(t.text, t.ms ?? 0)
        }.resume()
    }

    /// POST /polish. degraded=true means the sidecar echoed raw back (LLM down).
    func polish(text: String, profile: String, timeout: TimeInterval,
                completion: @escaping (String?, Bool) -> Void) {
        guard let url = URL(string: "\(AppInfo.sidecarBase)/polish") else { completion(nil, true); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "profile": profile])
        session.dataTask(with: req) { data, _, _ in
            guard let data = data, let p = try? JSONDecoder().decode(Polished.self, from: data) else {
                completion(nil, true); return
            }
            completion(p.text, p.degraded)
        }.resume()
    }

    /// POST /capture — history write; fire-and-forget (failure never affects UX).
    func capture(raw: String, polished: String, profile: String, msStt: Int, msPolish: Int) {
        guard let url = URL(string: "\(AppInfo.sidecarBase)/capture") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 3
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "raw": raw, "polished": polished, "profile": profile,
            "ms_stt": msStt, "ms_polish": msPolish,
        ])
        session.dataTask(with: req) { _, _, _ in }.resume()
    }

    /// GET /models (polish LLM) or /stt/models (transcription) — live model
    /// list for the menu-bar pickers. Same shape; only the path differs.
    func listModels(path: String = "/models", timeout: TimeInterval = 4,
                    completion: @escaping (ModelList?) -> Void) {
        get(path, timeout: timeout) { (data: Data?) in
            guard let data = data else { completion(nil); return }
            completion(try? JSONDecoder().decode(ModelList.self, from: data))
        }
    }

    /// POST /models | /stt/models — hot-swap the active model (no sidecar
    /// restart). Completion: (ok, activeModel). On failure the previous model
    /// stays active. STT switches warm-load (possibly download) a model first,
    /// so the caller passes a longer timeout.
    func switchModel(_ model: String, path: String = "/models", timeout: TimeInterval = 130,
                     completion: @escaping (Bool, String?) -> Void) {
        guard let url = URL(string: "\(AppInfo.sidecarBase)\(path)") else { completion(false, nil); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        session.dataTask(with: req) { data, _, _ in
            guard let data = data, let s = try? JSONDecoder().decode(ModelSwitch.self, from: data) else {
                completion(false, nil); return
            }
            completion(s.ok, s.model)
        }.resume()
    }

    /// GET /history?limit=50.
    func history(limit: Int = 50, completion: @escaping ([CaptureEntry]?) -> Void) {
        get("/history?limit=\(limit)", timeout: 3) { (data: Data?) in
            guard let data = data else { completion(nil); return }
            completion(try? JSONDecoder().decode([CaptureEntry].self, from: data))
        }
    }

    private func get<T>(_ path: String, timeout: TimeInterval, completion: @escaping (T?) -> Void) {
        guard let url = URL(string: "\(AppInfo.sidecarBase)\(path)") else { completion(nil); return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        session.dataTask(with: req) { data, _, _ in
            completion(data as? T)
        }.resume()
    }
}
