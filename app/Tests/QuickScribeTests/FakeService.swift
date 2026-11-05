import Foundation
import Network

/// A real HTTP/1.1 server on 127.0.0.1 for tests, so the app's URLSession sees
/// exactly what it will see from a real service. One canned reply per path,
/// plus the raw request for shape assertions.
final class FakeService: @unchecked Sendable {
    struct Received {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    struct Rule {
        var status: Int = 200
        var contentType: String = "application/json"
        var body: Data
        /// seconds to wait before answering; for the timeout case
        var delay: TimeInterval = 0
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-service")
    private let lock = NSLock()
    private var rules: [String: [Rule]] = [:]     // path → queued replies (FIFO)
    private var receivedList: [Received] = []
    private var conns: [NWConnection] = []

    init() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Port 0 asks the OS for a free one, so parallel test cases never collide.
        listener = try NWListener(using: params, on: .any)
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var baseURL: String { "http://127.0.0.1:\(port)/v1" }

    /// Blocks until the listener is actually ready to accept, so tests never
    /// race the socket coming up.
    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        // Written only from the listener queue, read here after wait() returns;
        // the semaphore hands off the happens-before edge.
        let failure = FailureBox()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let e): failure.set(e); ready.signal()
            case .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut {
            throw FakeServiceError.timeoutStarting
        }
        if let e = failure.value { throw FakeServiceError.listenerFailed(e) }
    }

    private final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: NWError?
        func set(_ e: NWError) { lock.lock(); stored = e; lock.unlock() }
        var value: NWError? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    enum FakeServiceError: Error {
        case timeoutStarting
        case listenerFailed(NWError)
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let open = conns
        conns = []
        lock.unlock()
        open.forEach { $0.cancel() }
    }

    func queue(_ rule: Rule, forPath path: String) {
        lock.lock(); rules[path, default: []].append(rule); lock.unlock()
    }

    /// Drop queued replies for a path (and recorded requests), for a test that
    /// needs a different answer than setUp queued.
    func reset(path: String) {
        lock.lock(); rules[path] = []; lock.unlock()
    }

    func text(_ s: String, status: Int = 200, contentType: String = "application/json", delay: TimeInterval = 0) -> Rule {
        Rule(status: status, contentType: contentType, body: Data(s.utf8), delay: delay)
    }

    var received: [Received] { lock.lock(); defer { lock.unlock() }; return receivedList }
    var lastRequest: Received? { received.last }

    private func handle(_ conn: NWConnection) {
        lock.lock(); conns.append(conn); lock.unlock()
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if error != nil || (isComplete && buf.isEmpty) { conn.cancel(); return }
            // Header terminator present?
            guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else {
                self.readRequest(conn, buffer: buf)
                return
            }
            let headData = buf[buf.startIndex..<sep.lowerBound]
            let head = String(decoding: headData, as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let parts = lines.first?.components(separatedBy: " ") ?? []
            guard parts.count >= 2 else { conn.cancel(); return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                if let i = line.firstIndex(of: ":") {
                    headers[String(line[..<i]).lowercased()] = String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            var body = Data(buf[sep.upperBound...])
            let need = Int(headers["content-length"] ?? "0") ?? 0
            if body.count < need {
                self.readBodyThenAnswer(conn, method: parts[0], path: parts[1], headers: headers, body: body, remaining: need - body.count)
                return
            }
            self.answer(conn, method: parts[0], path: parts[1], headers: headers, body: body)
        }
    }

    private func readBodyThenAnswer(_ conn: NWConnection, method: String, path: String, headers: [String: String], body: Data, remaining: Int) {
        conn.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { [weak self] data, _, _, _ in
            guard let self else { return }
            var full = body
            if let data { full.append(data) }
            self.answer(conn, method: method, path: path, headers: headers, body: full)
        }
    }

    private func answer(_ conn: NWConnection, method: String, path: String, headers: [String: String], body: Data) {
        lock.lock()
        receivedList.append(Received(method: method, path: path, headers: headers, body: body))
        var queue = rules[path] ?? []
        var rule: Rule?
        if !queue.isEmpty { rule = queue.removeFirst(); rules[path] = queue }
        lock.unlock()

        guard let rule else {
            respond(conn, status: 404, contentType: "application/json", body: Data(#"{"error":"no rule for \#(path)"}"#.utf8), delay: 0)
            return
        }
        respond(conn, status: rule.status, contentType: rule.contentType, body: rule.body, delay: rule.delay)
    }

    private func respond(_ conn: NWConnection, status: Int, contentType: String, body: Data, delay: TimeInterval) {
        let head = "HTTP/1.1 \(status) X\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        func send() {
            var out = Data(head.utf8)
            out.append(body)
            conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
        }
        if delay > 0 { queue.asyncAfter(deadline: .now() + delay) { send() } } else { send() }
    }
}
