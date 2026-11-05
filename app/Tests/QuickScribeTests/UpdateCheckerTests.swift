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
        XCTAssertEqual(r?.allHTTPHeaderFields?.count, 2, "name, version, and nothing else")
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
        XCTAssertEqual(up, .newer(version: "v2.1", page: URL(string: page)!))
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

    // MARK: once per version

    func testTheNoticeShowsOncePerVersion() {
        let newer = UpdateChecker.Check.newer(version: "2.1", page: URL(string: page)!)
        XCTAssertEqual(UpdateChecker.noticeVersion(for: newer, lastNotified: nil), "2.1")
        XCTAssertNil(UpdateChecker.noticeVersion(for: newer, lastNotified: "2.1"), "no nagging")
        XCTAssertEqual(UpdateChecker.noticeVersion(for: newer, lastNotified: "2.0"), "2.1")
        for quiet in [UpdateChecker.Check.current, .malformed, .failed] as [UpdateChecker.Check] {
            XCTAssertNil(UpdateChecker.noticeVersion(for: quiet, lastNotified: nil))
        }
    }
}
