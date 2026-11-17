import CryptoKit
import Foundation
import Security

/// Installs an update on the person's click: download the release's zipped
/// app, prove it is ours, swap it in for the running bundle, relaunch.
///
/// What makes a download trusted is its code signature. The new app must
/// satisfy the running app's own designated requirement, the same rule macOS
/// uses to decide an update is "the same app" for Microphone, Accessibility
/// and the keychain: this bundle identifier, signed by the same certificate
/// (for releases, "QuickScribe Release"). A build signed ad-hoc, as anyone
/// building from source gets, has no stable requirement to match, so it never
/// installs over itself and the person is sent to the release page instead.
/// GitHub's SHA-256 digest of the upload is checked too, as a transfer check.
///
/// No step is half-done in place: everything is downloaded, unpacked and
/// checked in a temporary folder on the app's own volume, and only the final
/// swap touches the installed app, in one rename that either happens or not.
/// Nothing here adds a quarantine flag, and nothing removes one the system put
/// on: the files are written by this app, which macOS does not quarantine.
public enum UpdateInstaller {

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notSelfUpdatable(String)      // this build cannot check a signature against itself
        case download(String)
        case digestMismatch
        case unpack(String)
        case notOneApp
        case wrongApp(String)              // bundle id, version, or name are not what was announced
        case signature(String)
        case install(String)
        case busy

        /// Short, for the pill and the log. No path, no URL.
        public var description: String {
            switch self {
            case .notSelfUpdatable(let why): return "this copy can't update itself (\(why))"
            case .download(let why): return "the download failed (\(why))"
            case .digestMismatch: return "the download was damaged"
            case .unpack(let why): return "the download could not be opened (\(why))"
            case .notOneApp: return "the download did not hold one app"
            case .wrongApp(let why): return "the download is not this app's update (\(why))"
            case .signature(let why): return "the download's signature did not match (\(why))"
            case .install(let why): return "the app could not be replaced (\(why))"
            case .busy: return "a dictation is running"
            }
        }
    }

    /// What the running app must be for an update to land on it.
    public struct Target: Sendable {
        public let bundleURL: URL
        public let bundleID: String
        public let appName: String          // "QuickScribe": the archive must hold QuickScribe.app
        public let currentVersion: String
        /// The text form of the designated requirement the new app must meet.
        public let requirement: String
        public init(bundleURL: URL, bundleID: String, appName: String, currentVersion: String, requirement: String) {
            self.bundleURL = bundleURL; self.bundleID = bundleID; self.appName = appName
            self.currentVersion = currentVersion; self.requirement = requirement
        }
    }

    // MARK: who am I

    /// The running app as an update target, or why it cannot be one. The
    /// requirement is read from the signature itself, never written down in
    /// the source, so a re-keyed release would need a hand install by design.
    public static func target(bundle: Bundle, appName: String, currentVersion: String) -> Result<Target, Failure> {
        let url = bundle.bundleURL
        guard url.pathExtension == "app", let id = bundle.bundleIdentifier else {
            return .failure(.notSelfUpdatable("not running from an app bundle"))
        }
        if url.path.contains("/AppTranslocation/") {
            return .failure(.notSelfUpdatable("macOS is running it from a temporary copy; move it to Applications"))
        }
        switch designatedRequirement(of: url) {
        case .failure(let f): return .failure(f)
        case .success(let req):
            return .success(Target(bundleURL: url, bundleID: id, appName: appName,
                                   currentVersion: currentVersion, requirement: req))
        }
    }

    /// The designated requirement of a signed bundle, as text. Refused when
    /// the signature names no certificate: an ad-hoc signature's requirement
    /// is its own hash, which no other build can ever meet.
    public static func designatedRequirement(of url: URL) -> Result<String, Failure> {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return .failure(.notSelfUpdatable("no code signature"))
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else {
            return .failure(.notSelfUpdatable("unreadable signature"))
        }
        guard let certs = dict[kSecCodeInfoCertificates as String] as? [Any], !certs.isEmpty else {
            return .failure(.notSelfUpdatable("built from source with an ad-hoc signature"))
        }
        var req: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &req) == errSecSuccess, let req else {
            return .failure(.notSelfUpdatable("no designated requirement"))
        }
        var text: CFString?
        guard SecRequirementCopyString(req, [], &text) == errSecSuccess, let text else {
            return .failure(.notSelfUpdatable("unreadable requirement"))
        }
        return .success(text as String)
    }

    // MARK: the steps, each one testable on its own

    /// A folder for one attempt, on the same volume as the installed app so
    /// the final swap is a rename, not a copy.
    public static func workFolder(near bundleURL: URL) throws -> URL {
        try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: bundleURL, create: true)
    }

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func checkDigest(_ file: URL, expected: String?) throws {
        guard let expected else { return }
        guard (try? sha256(of: file)) == expected.lowercased() else { throw Failure.digestMismatch }
    }

    /// `ditto` is what Finder uses for zip archives, and what made this one:
    /// it keeps the bundle's symlinks, permissions and signature intact.
    public static func unpack(_ zip: URL, into folder: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, folder.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw Failure.unpack("ditto did not start") }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure.unpack("ditto exit \(p.terminationStatus)") }
    }

    /// Exactly one item at the top of the archive, and it is `<appName>.app`.
    public static func theApp(in folder: URL, appName: String) throws -> URL {
        let items = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "__MACOSX" }
        guard items.count == 1, let app = items.first, app.lastPathComponent == "\(appName).app" else {
            throw Failure.notOneApp
        }
        let values = try app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.notOneApp }
        return app
    }

    /// The candidate is this app, at the announced version, newer than us,
    /// and signed to our own requirement, every file of it.
    public static func verify(candidate: URL, target: Target, announcedVersion: String) throws {
        guard let info = NSDictionary(contentsOf: candidate.appendingPathComponent("Contents/Info.plist")) else {
            throw Failure.wrongApp("no Info.plist")
        }
        guard info["CFBundleIdentifier"] as? String == target.bundleID else { throw Failure.wrongApp("bundle id") }
        guard let version = info["CFBundleShortVersionString"] as? String,
              let got = UpdateChecker.pieces(of: version),
              got == UpdateChecker.pieces(of: announcedVersion) else { throw Failure.wrongApp("version") }
        guard UpdateChecker.isNewer(version, than: target.currentVersion) else { throw Failure.wrongApp("not newer") }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(candidate as CFURL, [], &code) == errSecSuccess, let code else {
            throw Failure.signature("unsigned")
        }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(target.requirement as CFString, [], &req) == errSecSuccess, let req else {
            throw Failure.signature("bad requirement")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate
                               | kSecCSCheckNestedCode)
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, req, &error)
        error?.release()
        guard status == errSecSuccess else { throw Failure.signature("status \(status)") }
    }

    /// The one step that touches the installed app: an atomic swap. The old
    /// bundle survives in `folder` until that folder is removed, so a failed
    /// swap leaves the person exactly where they were.
    @discardableResult
    public static func swapIn(_ candidate: URL, over installed: URL) throws -> URL {
        do {
            guard let result = try FileManager.default.replaceItemAt(installed, withItemAt: candidate,
                                                                     backupItemName: nil, options: []) else {
                throw Failure.install("no result")
            }
            return result
        } catch let f as Failure {
            throw f
        } catch {
            let code = (error as NSError).code
            throw Failure.install(code == NSFileWriteNoPermissionError ? "no permission to write there" : "error \(code)")
        }
    }

    /// The relaunch, as a tiny shell outside the app: wait for this process to
    /// be gone, then open the new bundle. Waiting matters: two copies running
    /// at once would both hear the hotkey and paste twice.
    public static func relaunchCommand(pid: Int32, app: URL) -> (URL, [String]) {
        let script = "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\""
        return (URL(fileURLWithPath: "/bin/sh"), ["-c", script, "sh", String(pid), app.path])
    }

    public static func startRelauncher(pid: Int32, app: URL) throws {
        let (exe, args) = relaunchCommand(pid: pid, app: app)
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    // MARK: the whole thing

    /// Download, check, unpack, check, swap. Returns the installed app's URL;
    /// the caller starts the relauncher and quits. The download is a fresh
    /// ephemeral session's, with the same generic user agent as the check.
    public static func install(archive: UpdateChecker.Archive, version: String, target: Target,
                               feed: UpdateFeed, userAgent: String,
                               download: (URLRequest, URL) async throws -> Void) async throws -> URL {
        guard feed.allowsDownload(archive.url) else { throw Failure.download("address not allowed") }
        let work = try workFolder(near: target.bundleURL)
        defer { try? FileManager.default.removeItem(at: work) }
        let zip = work.appendingPathComponent(UpdateChecker.archiveName)
        var request = URLRequest(url: archive.url, timeoutInterval: 120)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        do { try await download(request, zip) } catch let f as Failure { throw f } catch {
            throw Failure.download("\((error as NSError).code)")
        }
        if let size = archive.size,
           let got = (try? zip.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, got != size {
            throw Failure.digestMismatch
        }
        try checkDigest(zip, expected: archive.sha256)
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: false)
        try unpack(zip, into: unpacked)
        let app = try theApp(in: unpacked, appName: target.appName)
        try verify(candidate: app, target: target, announcedVersion: version)
        return try swapIn(app, over: target.bundleURL)
    }

    /// The real download: redirects followed (GitHub sends release files from
    /// its storage host), nothing cached, the file moved into `to`.
    public static func urlSessionDownload(_ request: URLRequest, to destination: URL) async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (file, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: file)
            throw Failure.download("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        try FileManager.default.moveItem(at: file, to: destination)
    }
}
