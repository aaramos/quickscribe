import XCTest
@testable import QuickScribeCore

/// The installer on real bundles: tiny apps assembled and signed here, with
/// codesign's ad-hoc signature, so no certificate is needed. A release build
/// carries the "QuickScribe Release" certificate instead; the checks are the
/// same calls, only the requirement text differs.
final class UpdateInstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("qs-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func run(_ exe: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    /// A signed app bundle: QuickScribe.app, the given id and version.
    private func makeApp(in folder: URL, id: String = "test.quickscribe", version: String,
                         sign: Bool = true) throws -> URL {
        let app = folder.appendingPathComponent("QuickScribe.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macos.appendingPathComponent("QuickScribe").path)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": "QuickScribe",
                                    "CFBundleShortVersionString": version, "CFBundleVersion": version,
                                    "CFBundlePackageType": "APPL"]
        (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        if sign { XCTAssertEqual(try run("/usr/bin/codesign", ["--force", "-s", "-", app.path]), 0) }
        return app
    }

    /// The text of a bundle's own designated requirement, ad-hoc or not.
    private func ownRequirement(_ app: URL) -> String {
        var code: SecStaticCode?
        SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        var req: SecRequirement?
        SecCodeCopyDesignatedRequirement(code!, [], &req)
        var text: CFString?
        SecRequirementCopyString(req!, [], &text)
        return text! as String
    }

    private func target(_ installed: URL, requirement: String, id: String = "test.quickscribe") -> UpdateInstaller.Target {
        UpdateInstaller.Target(bundleURL: installed, bundleID: id, appName: "QuickScribe",
                               currentVersion: "2.0", requirement: requirement)
    }

    private func folder(_ name: String) throws -> URL {
        let f = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    // MARK: who may update itself

    func testABuildFromSourceNeverInstallsOverItself() throws {
        let app = try makeApp(in: folder("adhoc"), version: "2.0")
        guard case .failure(.notSelfUpdatable(let why)) = UpdateInstaller.designatedRequirement(of: app) else {
            return XCTFail("an ad-hoc signature has no requirement another build can meet")
        }
        XCTAssertTrue(why.contains("ad-hoc"))
        let unsigned = try makeApp(in: folder("unsigned"), version: "2.0", sign: false)
        // /usr/bin/true arrives with Apple's own signature; strip it.
        XCTAssertEqual(try run("/usr/bin/codesign", ["--remove-signature",
                                                     unsigned.appendingPathComponent("Contents/MacOS/QuickScribe").path]), 0)
        guard case .failure = UpdateInstaller.designatedRequirement(of: unsigned) else { return XCTFail() }
    }

    // MARK: the candidate

    func testTheRightAppAtTheAnnouncedVersionPasses() throws {
        let installed = try makeApp(in: folder("installed"), version: "2.0")
        let new = try makeApp(in: folder("new"), version: "2.1")
        XCTAssertNoThrow(try UpdateInstaller.verify(candidate: new, target: target(installed, requirement: ownRequirement(new)),
                                                    announcedVersion: "2.1"))
    }

    func testAnotherSignerIsRefused() throws {
        let installed = try makeApp(in: folder("installed"), version: "2.0")
        let new = try makeApp(in: folder("new"), version: "2.1")
        // A requirement naming a certificate the candidate was not signed with.
        let other = "identifier \"test.quickscribe\" and certificate leaf = H\"0477b7bf4bf0f81af3fd7c8fae83651598d70d53\""
        XCTAssertThrowsError(try UpdateInstaller.verify(candidate: new, target: target(installed, requirement: other),
                                                        announcedVersion: "2.1")) { e in
            guard case .signature = e as? UpdateInstaller.Failure else { return XCTFail("\(e)") }
        }
    }

    func testATamperedBundleIsRefused() throws {
        let installed = try makeApp(in: folder("installed"), version: "2.0")
        let new = try makeApp(in: folder("new"), version: "2.1")
        let req = ownRequirement(new)
        try Data("extra".utf8).write(to: new.appendingPathComponent("Contents/MacOS/QuickScribe"))
        XCTAssertThrowsError(try UpdateInstaller.verify(candidate: new, target: target(installed, requirement: req),
                                                        announcedVersion: "2.1"))
    }

    func testWrongIdentityOrVersionIsRefused() throws {
        let installed = try makeApp(in: folder("installed"), version: "2.0")
        let otherID = try makeApp(in: folder("id"), id: "someone.else", version: "2.1")
        XCTAssertThrowsError(try UpdateInstaller.verify(candidate: otherID, target: target(installed, requirement: ownRequirement(otherID)),
                                                        announcedVersion: "2.1")) { e in
            XCTAssertEqual(e as? UpdateInstaller.Failure, .wrongApp("bundle id"))
        }
        let older = try makeApp(in: folder("older"), version: "1.9")
        XCTAssertThrowsError(try UpdateInstaller.verify(candidate: older, target: target(installed, requirement: ownRequirement(older)),
                                                        announcedVersion: "1.9")) { e in
            XCTAssertEqual(e as? UpdateInstaller.Failure, .wrongApp("not newer"), "never a downgrade")
        }
        let mismatch = try makeApp(in: folder("mismatch"), version: "2.2")
        XCTAssertThrowsError(try UpdateInstaller.verify(candidate: mismatch, target: target(installed, requirement: ownRequirement(mismatch)),
                                                        announcedVersion: "2.1")) { e in
            XCTAssertEqual(e as? UpdateInstaller.Failure, .wrongApp("version"), "the release says what it holds")
        }
    }

    func testTheArchiveMustHoldExactlyOneApp() throws {
        let two = try folder("two")
        _ = try makeApp(in: two, version: "2.1")
        try Data().write(to: two.appendingPathComponent("extra.txt"))
        XCTAssertThrowsError(try UpdateInstaller.theApp(in: two, appName: "QuickScribe"))
        let none = try folder("none")
        XCTAssertThrowsError(try UpdateInstaller.theApp(in: none, appName: "QuickScribe"))
    }

    // MARK: the whole install

    private func zip(_ app: URL) throws -> URL {
        let out = root.appendingPathComponent("QuickScribe-\(UUID().uuidString).zip")
        XCTAssertEqual(try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, out.path]), 0)
        return out
    }

    private let feed = UpdateFeed.local(base: "http://127.0.0.1:1")!
    private let archiveURL = URL(string: "http://127.0.0.1:1/download/QuickScribe.zip")!

    private func copyFrom(_ zip: URL) -> (URLRequest, URL) async throws -> Void {
        { _, destination in try FileManager.default.copyItem(at: zip, to: destination) }
    }

    func testAGoodArchiveReplacesTheInstalledApp() async throws {
        let installed = try makeApp(in: folder("Applications"), version: "2.0")
        let new = try makeApp(in: folder("build"), version: "2.1")
        let req = ownRequirement(new)
        let archive = try zip(new)
        let digest = try UpdateInstaller.sha256(of: archive)
        let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let result = try await UpdateInstaller.install(
            archive: .init(url: archiveURL, sha256: digest, size: size), version: "2.1",
            target: target(installed, requirement: req), feed: feed, userAgent: "QuickScribe/2.0",
            download: copyFrom(archive))
        XCTAssertEqual(result.standardizedFileURL.path, installed.standardizedFileURL.path)
        let info = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(info?["CFBundleShortVersionString"] as? String, "2.1")
        XCTAssertEqual(try run("/usr/bin/codesign", ["--verify", "--strict", "--deep", installed.path]), 0,
                       "the swapped-in app is still intact")
    }

    func testADamagedDownloadLeavesTheInstalledAppAlone() async throws {
        let installed = try makeApp(in: folder("Applications"), version: "2.0")
        let new = try makeApp(in: folder("build"), version: "2.1")
        let archive = try zip(new)
        do {
            _ = try await UpdateInstaller.install(
                archive: .init(url: archiveURL, sha256: String(repeating: "0", count: 64), size: nil), version: "2.1",
                target: target(installed, requirement: ownRequirement(new)), feed: feed, userAgent: "QuickScribe/2.0",
                download: copyFrom(archive))
            XCTFail("a wrong digest must stop the install")
        } catch {
            XCTAssertEqual(error as? UpdateInstaller.Failure, .digestMismatch)
        }
        let info = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(info?["CFBundleShortVersionString"] as? String, "2.0")
    }

    func testASignatureMismatchLeavesTheInstalledAppAlone() async throws {
        let installed = try makeApp(in: folder("Applications"), version: "2.0")
        let new = try makeApp(in: folder("build"), version: "2.1")
        let archive = try zip(new)
        do {
            _ = try await UpdateInstaller.install(
                archive: .init(url: archiveURL, sha256: nil, size: nil), version: "2.1",
                target: target(installed, requirement: ownRequirement(installed)), feed: feed,
                userAgent: "QuickScribe/2.0", download: copyFrom(archive))
            XCTFail("an archive signed by someone else must not install")
        } catch {
            guard case .signature = error as? UpdateInstaller.Failure else { return XCTFail("\(error)") }
        }
        let info = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(info?["CFBundleShortVersionString"] as? String, "2.0")
    }

    func testADownloadFromOutsideTheFeedIsNeverFetched() async throws {
        let installed = try makeApp(in: folder("Applications"), version: "2.0")
        var fetched = false
        do {
            _ = try await UpdateInstaller.install(
                archive: .init(url: URL(string: "https://evil.example/QuickScribe.zip")!, sha256: nil, size: nil),
                version: "2.1", target: target(installed, requirement: "identifier x"), feed: feed,
                userAgent: "QuickScribe/2.0", download: { _, _ in fetched = true })
            XCTFail()
        } catch {}
        XCTAssertFalse(fetched)
    }

    // MARK: relaunch

    func testTheRelaunchWaitsForThisProcessThenOpensTheNewApp() {
        let (exe, args) = UpdateInstaller.relaunchCommand(pid: 4242, app: URL(fileURLWithPath: "/Applications/QuickScribe.app"))
        XCTAssertEqual(exe.path, "/bin/sh")
        XCTAssertEqual(Array(args.suffix(2)), ["4242", "/Applications/QuickScribe.app"],
                       "pid and path travel as arguments, never pasted into the script")
        XCTAssertTrue(args[1].contains("kill -0"))
        XCTAssertTrue(args[1].hasSuffix("/usr/bin/open \"$2\""))
    }
}
