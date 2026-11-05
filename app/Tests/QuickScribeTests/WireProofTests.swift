import XCTest
@testable import QuickScribeCore

/// The honest place to read what a check really sends: a real ephemeral
/// URLSession, no protocol class in the way, answering to a listener on
/// this machine's own loopback. The review found Accept-Language: en-US
/// arriving here even when the request object never set it, so this test
/// reads the bytes, not the object.
final class WireProofTests: XCTestCase {
    func testWhatTheRealStackSends() async throws {
        let listener = Listener()
        try listener.start()
        guard let req = UpdateChecker.request(repo: "example/native", appName: "QuickScribe",
                                              appVersion: "2.0") else { return XCTFail("no request") }
        // Send the app's own request (headers untouched) to loopback.
        var sent = req
        sent.url = URL(string: "http://127.0.0.1:\(listener.port)/")!
        sent.timeoutInterval = 5
        let session = URLSession(configuration: .ephemeral)
        _ = try? await session.data(for: sent)
        let raw = await listener.received()
        XCTAssertTrue(raw.contains("User-Agent: QuickScribe/2.0"), raw)
        XCTAssertTrue(raw.contains("Accept-Language: en\r\n"),
                      "must be the fixed value, not the person's language: \(raw)")
        XCTAssertFalse(raw.lowercased().contains("q=0.9"), "no negotiation, no dialect detail")
        XCTAssertFalse(raw.lowercased().contains("cookie"), "nothing stored, nothing replayed")
    }
}

final class Listener: @unchecked Sendable {
    var port: UInt16 = 0
    private let sock = socket(AF_INET, SOCK_STREAM, 0)
    private var lock = NSLock()
    private var text = ""
    init() {}
    func start() throws {
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0).bigEndian
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { q in
            _ = bind(sock, q, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(sock, 4)
        var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { q in
            _ = getsockname(sock, q, &len) } }
        port = UInt16(bigEndian: bound.sin_port)
        DispatchQueue.global().async { [weak self] in self?.acceptOnce() }
    }
    private func acceptOnce() {
        let fd = accept(sock, nil, nil)
        guard fd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 65_536)
        let n = read(fd, &buf, buf.count)
        if n > 0 { let s = String(bytes: buf[0..<n], encoding: .utf8) ?? ""
                   lock.lock(); text = s; lock.unlock() }
        let ok = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".cString(using: .utf8)!
        write(fd, ok, ok.count); close(fd)
    }
    func received() async -> String {
        for _ in 0..<50 { lock.lock(); let t = text; lock.unlock(); if !t.isEmpty { return t }
            try? await Task.sleep(nanoseconds: 100_000_000) }
        return text
    }
}
