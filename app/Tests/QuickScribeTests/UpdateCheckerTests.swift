import XCTest
@testable import QuickScribeCore

/// Everything here answers GitHub by hand: no network is touched, so the
/// suite says the same thing whether or not the machine can reach GitHub.
final class UpdateCheckerTests: XCTestCase {

    private func release(tag: String, page: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "html_url": page])
    }
    private let page = "https://github.com/example/native/releases/tag/v2.1"

    // MARK: comparison

    func testTenBeatsNineWhereverItSits() {
        XCTAssertTrue(UpdateChecker.isNewer("2.10", than: "2.9"))
        XCTAssertTrue(UpdateChecker.isNewer("2", than: "1.99"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0.1", than: "2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("2.0", than: "2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.9", than: "2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("2.1", than: "2.1.0"), "missing places are zeros, not news")
    }

    func testTheLeadingVIsPackagingNotVersion() {
        XCTAssertFalse(UpdateChecker.isNewer("v2.0", than: "2.0"))
        XCTAssertTrue(UpdateChecker.isNewer("v2.1", than: "2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("2.1", than: "v2.1"))
    }

    func testVersionsThatAreNotNumbersMakeNoClaim() {
        XCTAssertNil(UpdateChecker.pieces(of: "1.0-beta"))
        XCTAssertNil(UpdateChecker.pieces(of: "latest"))
        XCTAssertNil(UpdateChecker.pieces(of: ""))
        XCTAssertNil(UpdateChecker.pieces(of: "v"))
        XCTAssertFalse(UpdateChecker.isNewer("nightly", than: "2.0"))
    }

    // MARK: the request

    func testTheRequestCarriesOnlyAGenericNameAndVersion() {
        let r = UpdateChecker.request(repo: "example/native", appName: "QuickScribe", appVersion: "2.0")
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.url?.absoluteString, "https://api.github.com/repos/example/native/releases/latest")
        XCTAssertEqual(r?.value(forHTTPHeaderField: "User-Agent"), "QuickScribe/2.0")
        XCTAssertEqual(r?.httpMethod, "GET")
        XCTAssertEqual(r?.value(forHTTPHeaderField: "Accept-Language"), "en",
                       "a fixed language, or the session sends the person's real one")
        XCTAssertEqual(r?.allHTTPHeaderFields?.count, 3, "name and version, JSON preference, fixed language")
        XCTAssertNil(r?.httpBody)
    }

    // MARK: answers, through the seam

    private func check(_ data: Data, _ status: Int, current: String = "2.0") async -> UpdateChecker.Check {
        await UpdateChecker.check(repo: "example/native", appName: "QuickScribe", appVersion: current) { _ in
            (data, status)
        }
    }

    func testNewerSameAndOlderAreToldApart() async {
        let up = await check(release(tag: "v2.1", page: page), 200)
        XCTAssertEqual(up, .newer(version: "2.1", page: URL(string: page)!, archive: nil),
                       "the menu must read 'version 2.1', never 'version v2.1'")
        let same = await check(release(tag: "v2.0", page: page), 200)
        XCTAssertEqual(same, .current)
        let behind = await check(release(tag: "v1.0", page: page), 200)
        XCTAssertEqual(behind, .current, "GitHub a year old is no news")
    }

    func testMalformedAnswers() async {
        let junk = await check(Data("not json".utf8), 200)
        XCTAssertEqual(junk, .malformed)
        let noTag = await check(try! JSONSerialization.data(withJSONObject: ["name": "hi"]), 200)
        XCTAssertEqual(noTag, .malformed)
        let nightly = await check(release(tag: "nightly", page: page), 200)
        XCTAssertEqual(nightly, .malformed)
        let brokenURL = await check(release(tag: "v9.9", page: "not a url at all:"), 200)
        XCTAssertEqual(brokenURL, .malformed)
    }

    func testFailuresAreAllTheSameQuietNo() async {
        let limited = await check(Data("{}".utf8), 403)
        XCTAssertEqual(limited, .failed, "rate limited")
        let missing = await check(Data("{}".utf8), 404)
        XCTAssertEqual(missing, .failed, "no releases yet")
        let server = await check(Data("{}".utf8), 500)
        XCTAssertEqual(server, .failed)
        // A transport that throws (no network, timeout) is the same quiet no:
        let fell = await UpdateChecker.check(repo: "example/native", appName: "QuickScribe",
                                             appVersion: "2.0") { _ in throw URLError(.timedOut) }
        XCTAssertEqual(fell, .failed)
    }

    // MARK: the link we will open

    func testOnlyOurOwnReleasesPageOnGithubOpens() async {
        let foreign = await check(release(tag: "v9.9", page: "https://evil.example.com/example/native/releases/tag/v9.9"), 200)
        XCTAssertEqual(foreign, .malformed, "another host is not our release page")
        let otherRepo = await check(release(tag: "v9.9", page: "https://github.com/someone/else/releases/tag/v9.9"), 200)
        XCTAssertEqual(otherRepo, .malformed, "another repository's release is not ours")
        let insecure = await check(release(tag: "v9.9", page: "http://github.com/example/native/releases/tag/v9.9"), 200)
        XCTAssertEqual(insecure, .malformed, "http is not https")
        let local = await check(release(tag: "v9.9", page: "file:///tmp/release.html"), 200)
        XCTAssertEqual(local, .malformed, "a file address never opens a browser")
        let nearMiss = await check(release(tag: "v9.9", page: "https://github.com.evil.example/example/native/releases/tag/v9.9"), 200)
        XCTAssertEqual(nearMiss, .malformed, "a host that starts like github.com is not github.com")
        let madeUp = await check(release(tag: "v9.9", page: "https://notgithub.com/example/native/releases/tag/v9.9"), 200)
        XCTAssertEqual(madeUp, .malformed, "a host that ends like github.com is not github.com either")
    }

    // MARK: v-shape is one version

    func testVAndPlainAreTheSameNewsOnceTold() {
        let pageURL = URL(string: page)!
        XCTAssertEqual(UpdateChecker.noticeVersion(for: .newer(version: "2.1", page: pageURL, archive: nil), lastNotified: "2.1"), nil)
        // (The check itself hands over "2.1" for a "v2.1" tag, which is how
        // the two spellings can never both be announced.)
        XCTAssertEqual(UpdateChecker.displayVersion("v2.1"), "2.1")
        XCTAssertEqual(UpdateChecker.displayVersion("V2.1"), "2.1")
        XCTAssertEqual(UpdateChecker.displayVersion("2.10"), "2.10", "only a leading v goes")
    }

    // MARK: what really goes out on the wire

    func testWhatActuallyGoesOverTheWire() async {
        // Not the request object: the bytes as URLSession hands them over.
        // The shared session adds the person's Accept-Language behind our
        // back, so this is the only honest place to read the truth.
        WireCapture.captured = nil
        WireCapture.reply = release(tag: "v2.1", page: page)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WireCapture.self]
        let answer = await UpdateChecker.check(repo: "example/native", appName: "QuickScribe",
                                              appVersion: "2.0", session: URLSession(configuration: config))
        XCTAssertEqual(answer, .newer(version: "2.1", page: URL(string: page)!, archive: nil))
        let sent = WireCapture.captured
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "User-Agent"), "QuickScribe/2.0")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "Accept-Language"), "en",
                       "fixed, or URLSession leaks the person's language")
        XCTAssertEqual(sent?.url?.absoluteString, "https://api.github.com/repos/example/native/releases/latest")
        let own = Set(["User-Agent", "Accept", "Accept-Language"])
        let extra = (sent?.allHTTPHeaderFields ?? [:]).keys.filter { !own.contains($0) && $0 != "Accept-Encoding" }
        XCTAssertTrue(extra.isEmpty, "our own headers only; URLSession may add encoding: \(extra)")
        XCTAssertNil(sent?.httpBody)
    }

    // MARK: once per version

    func testTheNoticeShowsOncePerVersion() {
        let newer = UpdateChecker.Check.newer(version: "2.1", page: URL(string: page)!, archive: nil)
        XCTAssertEqual(UpdateChecker.noticeVersion(for: newer, lastNotified: nil), "2.1")
        XCTAssertNil(UpdateChecker.noticeVersion(for: newer, lastNotified: "2.1"), "no nagging")
        XCTAssertEqual(UpdateChecker.noticeVersion(for: newer, lastNotified: "2.0"), "2.1")
        for quiet in [UpdateChecker.Check.current, .malformed, .failed] as [UpdateChecker.Check] {
            XCTAssertNil(UpdateChecker.noticeVersion(for: quiet, lastNotified: nil))
        }
    }
}

/// A stand-in wire: records the request as the session really sends it and
/// answers with canned bytes. No network, and nothing our own code set on
/// the request object can hide what the session layer adds.
final class WireCapture: URLProtocol {
    static var captured: URLRequest?
    static var reply = Data("{}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        WireCapture.captured = request
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                                                              httpVersion: "HTTP/2", headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: WireCapture.reply)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// The update archive a release offers, read from GitHub's answer. Only the
/// one named QuickScribe.zip under this repository's release downloads is
/// ever handed to the installer.
final class UpdateArchiveTests: XCTestCase {
    private let page = "https://github.com/example/native/releases/tag/v2.1"
    private let zipURL = "https://github.com/example/native/releases/download/v2.1/QuickScribe.zip"
    private let digest = "sha256:" + String(repeating: "ab", count: 32)

    private func answer(_ assets: [[String: Any]]) -> UpdateChecker.Check {
        let data = try! JSONSerialization.data(withJSONObject: ["tag_name": "v2.1", "html_url": page, "assets": assets])
        return UpdateChecker.evaluate(data: data, status: 200, currentVersion: "2.0", repo: "example/native")
    }
    private func archive(of check: UpdateChecker.Check) -> UpdateChecker.Archive? {
        guard case .newer(_, _, let archive) = check else { XCTFail("expected newer"); return nil }
        return archive
    }

    func testTheArchiveIsFoundWithItsDigestAndSize() {
        let dmg: [String: Any] = ["name": "QuickScribe.dmg",
                                  "browser_download_url": "https://github.com/example/native/releases/download/v2.1/QuickScribe.dmg"]
        let zip: [String: Any] = ["name": "QuickScribe.zip", "browser_download_url": zipURL, "digest": digest, "size": 1234]
        let found = archive(of: answer([dmg, zip]))
        XCTAssertEqual(found, UpdateChecker.Archive(url: URL(string: zipURL)!,
                                                    sha256: String(repeating: "ab", count: 32), size: 1234))
    }

    func testAReleaseWithOnlyADiskImageIsStillAnnounced() {
        let dmg: [String: Any] = ["name": "QuickScribe.dmg",
                                  "browser_download_url": "https://github.com/example/native/releases/download/v2.1/QuickScribe.dmg"]
        XCTAssertEqual(answer([dmg]), .newer(version: "2.1", page: URL(string: page)!, archive: nil))
        XCTAssertNil(archive(of: answer([])))
    }

    func testAnArchiveFromAnywhereElseIsIgnored() {
        for bad in ["https://github.com/other/native/releases/download/v2.1/QuickScribe.zip",
                    "http://github.com/example/native/releases/download/v2.1/QuickScribe.zip",
                    "https://github.com.evil.example/example/native/releases/download/v2.1/QuickScribe.zip",
                    "https://evil.example/example/native/releases/download/v2.1/QuickScribe.zip",
                    "https://github.com/example/native/releases/download/v2.1/QuickScribe.zip?x=1",
                    "https://github.com/example/native/releases/download/../../../other/QuickScribe.zip",
                    "https://github.com/example/native/releases/download/v2.1/Other.zip"] {
            let zip: [String: Any] = ["name": "QuickScribe.zip", "browser_download_url": bad]
            XCTAssertNil(archive(of: answer([zip])), bad)
        }
    }

    func testTwoArchivesOrABrokenDigestMeanNone() {
        let zip: [String: Any] = ["name": "QuickScribe.zip", "browser_download_url": zipURL]
        XCTAssertNil(archive(of: answer([zip, zip])), "which one would we install?")
        let short: [String: Any] = ["name": "QuickScribe.zip", "browser_download_url": zipURL, "digest": "sha256:abc"]
        XCTAssertNil(archive(of: answer([short])))
        let none: [String: Any] = ["name": "QuickScribe.zip", "browser_download_url": zipURL]
        XCTAssertEqual(archive(of: answer([none]))?.sha256, nil, "no digest is allowed: the signature still decides")
    }

    func testTheRehearsalFeedIsThisMacOnly() {
        XCTAssertNotNil(UpdateFeed.local(base: "http://127.0.0.1:8765"))
        XCTAssertNotNil(UpdateFeed.local(base: "http://localhost:8765/"))
        XCTAssertNil(UpdateFeed.local(base: "http://192.168.1.4:8765"))
        XCTAssertNil(UpdateFeed.local(base: "https://example.com"))
        XCTAssertNil(UpdateFeed.local(base: "file:///tmp"))
        let feed = UpdateFeed.local(base: "http://127.0.0.1:8765")!
        XCTAssertEqual(feed.latestRelease.absoluteString, "http://127.0.0.1:8765/releases/latest")
        XCTAssertTrue(feed.allowsDownload(URL(string: "http://127.0.0.1:8765/download/QuickScribe.zip")!))
        XCTAssertFalse(feed.allowsDownload(URL(string: "http://127.0.0.1:9999/download/QuickScribe.zip")!))
        XCTAssertFalse(feed.allowsDownload(URL(string: "https://github.com/x/y/releases/download/v1/QuickScribe.zip")!))
    }
}
