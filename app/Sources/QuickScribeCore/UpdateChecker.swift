import Foundation

/// Where releases are announced and what addresses they may point at. The
/// real feed is one GitHub repository's latest release. A test feed, a local
/// address given at launch, exists so the whole update can be rehearsed on
/// one Mac; it changes where the app asks, never what it accepts, because
/// every download still has to carry the running app's own signature.
public struct UpdateFeed: Equatable, Sendable {
    public let latestRelease: URL
    /// A release page or an archive download must start with one of these.
    let pagePrefix: String
    let downloadPrefix: String

    public static func github(repo: String) -> UpdateFeed? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        return UpdateFeed(latestRelease: url,
                          pagePrefix: "https://github.com/\(repo)/releases/",
                          downloadPrefix: "https://github.com/\(repo)/releases/download/")
    }

    /// A rehearsal feed: http or https on this Mac only (127.0.0.1 or
    /// localhost), answering `<base>/releases/latest` like GitHub does.
    public static func local(base: String) -> UpdateFeed? {
        var text = base
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme ?? ""),
              ["127.0.0.1", "localhost"].contains((url.host ?? "").lowercased()),
              let latest = URL(string: text + "/releases/latest") else { return nil }
        return UpdateFeed(latestRelease: latest, pagePrefix: text + "/", downloadPrefix: text + "/")
    }

    /// Checked as text after parsing, so "github.com.evil" or a userinfo
    /// trick cannot pass: the prefix includes the scheme, host and the slash
    /// after the repository.
    public func allowsPage(_ url: URL) -> Bool { Self.starts(url, with: pagePrefix) }
    public func allowsDownload(_ url: URL) -> Bool { Self.starts(url, with: downloadPrefix) }

    private static func starts(_ url: URL, with prefix: String) -> Bool {
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        let text = url.absoluteString
        return text.hasPrefix(prefix) && !text.contains("/../") && !text.contains("/./")
    }
}

/// "Is there a newer release?" The app ASKS GitHub, sending nothing but a
/// generic app name and version. When the release carries an update archive
/// the answer names it, and `UpdateInstaller` can fetch it on the person's
/// click; nothing downloads on its own. Every failure of the check is silent
/// to the person: dictation never waits on this, and a quiet no is better
/// than a wrong yes.
public enum UpdateChecker {

    /// The file in a release that the in-app installer uses: the signed app,
    /// zipped. The disk image beside it stays for first installs.
    public static let archiveName = "QuickScribe.zip"

    /// The update archive a release offers. `sha256` is GitHub's own digest
    /// of the uploaded file, when it gives one: a transfer check. What makes
    /// the download trusted is its code signature, checked after unpacking.
    public struct Archive: Equatable, Sendable {
        public let url: URL
        public let sha256: String?
        public let size: Int?
        public init(url: URL, sha256: String?, size: Int?) {
            self.url = url; self.sha256 = sha256; self.size = size
        }
    }

    /// What one check decided. `failed` covers unreachable, timeouts and
    /// server errors alike: the person never sees the difference, and the
    /// log keeps only a short reason, never a URL with anything in it.
    /// `archive` is nil for a release with only a disk image: that one is
    /// still announced, and installed by hand from its page.
    public enum Check: Equatable, Sendable {
        case newer(version: String, page: URL, archive: Archive?)
        case current        // same version, or GitHub is older than us
        case malformed      // an answer we cannot read as a release
        case failed
    }

    /// GitHub tags like to wear a "v". It is packaging, not version, and
    /// ignored on both sides. Numbers compare by place: 2.10 is newer than
    /// 2.9, which a string sort gets wrong. Any piece that is not a plain
    /// number ("1.0-beta", "latest") is not a version: nil, and the caller
    /// treats it as malformed.
    public static func pieces(of version: String) -> [Int]? {
        var text = version.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        guard !text.isEmpty else { return nil }
        var out: [Int] = []
        for part in text.split(separator: ".", omittingEmptySubsequences: false) {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
            out.append(value)
        }
        return out
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = pieces(of: candidate), let b = pieces(of: current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The request, on purpose: the address, a generic "QuickScribe/2.0"
    /// user agent, a JSON preference, and a fixed language, because the
    /// shared URLSession otherwise adds the person's real one and a quiet
    /// version check has no business saying what languages they speak. No
    /// key, no identifier, no words. What GitHub still sees is the network
    /// address, like any web request; that is not secretable, so it is said
    /// in the docs rather than worked around.
    public static func request(repo: String, appName: String, appVersion: String) -> URLRequest? {
        guard let feed = UpdateFeed.github(repo: repo) else { return nil }
        return request(feed: feed, appName: appName, appVersion: appVersion)
    }

    public static func request(feed: UpdateFeed, appName: String, appVersion: String) -> URLRequest? {
        var r = URLRequest(url: feed.latestRelease, timeoutInterval: 15)
        r.httpMethod = "GET"
        r.setValue("\(appName)/\(appVersion)", forHTTPHeaderField: "User-Agent")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("en", forHTTPHeaderField: "Accept-Language")
        return r
    }

    /// The version as a person should read it: GitHub tags wear a "v" that
    /// is packaging, not news, and a menu must not say "version v2.1". The
    /// same shape decides once-per-version: "v2.1" told yesterday IS 2.1.
    public static func displayVersion(_ version: String) -> String {
        version.hasPrefix("v") || version.hasPrefix("V") ? String(version.dropFirst()) : version
    }

    /// Read GitHub's answer. The release's own page is what we point at, so
    /// the person lands where they can read what changed. We open it only if
    /// it is github.com over https, under this repository's releases,
    /// checked piece by piece: an answer we cannot trust is malformed, and
    /// the app never launches a browser at whatever a reply says. The update
    /// archive is held to the same rule: an asset named `archiveName` whose
    /// download address is under this repository's release downloads. An
    /// asset that fails that is ignored, and the release is announced
    /// without one, for a hand install.
    public static func evaluate(data: Data, status: Int, currentVersion: String, repo: String) -> Check {
        guard let feed = UpdateFeed.github(repo: repo) else { return .malformed }
        return evaluate(data: data, status: status, currentVersion: currentVersion, feed: feed)
    }

    public static func evaluate(data: Data, status: Int, currentVersion: String, feed: UpdateFeed) -> Check {
        guard (200..<300).contains(status) else { return .failed }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let urlString = json["html_url"] as? String,
              let page = URL(string: urlString),
              feed.allowsPage(page)
        else { return .malformed }
        guard pieces(of: tag) != nil, pieces(of: currentVersion) != nil else { return .malformed }
        guard isNewer(tag, than: currentVersion) else { return .current }
        return .newer(version: displayVersion(tag), page: page, archive: archive(in: json, feed: feed))
    }

    /// The one usable update archive in a release answer, or nil.
    static func archive(in json: [String: Any], feed: UpdateFeed) -> Archive? {
        guard let assets = json["assets"] as? [[String: Any]] else { return nil }
        let named = assets.filter { ($0["name"] as? String) == archiveName }
        guard named.count == 1, let asset = named.first,
              let text = asset["browser_download_url"] as? String,
              let url = URL(string: text), feed.allowsDownload(url),
              url.lastPathComponent == archiveName
        else { return nil }
        var digest: String?
        if let d = asset["digest"] as? String, d.hasPrefix("sha256:") {
            let hex = String(d.dropFirst("sha256:".count)).lowercased()
            if hex.count == 64, hex.allSatisfy(\.isHexDigit) { digest = hex } else { return nil }
        }
        return Archive(url: url, sha256: digest, size: asset["size"] as? Int)
    }

    /// One whole round trip, with the transport as a seam so tests answer
    /// with canned bytes and the real app plugs in URLSession. A thrown
    /// error is just another way of failing, and it stays silent.
    public static func check(repo: String, appName: String, appVersion: String,
                             transport: (URLRequest) async throws -> (Data, Int)) async -> Check {
        guard let feed = UpdateFeed.github(repo: repo) else { return .failed }
        return await check(feed: feed, appName: appName, appVersion: appVersion, transport: transport)
    }

    public static func check(feed: UpdateFeed, appName: String, appVersion: String,
                             transport: (URLRequest) async throws -> (Data, Int)) async -> Check {
        guard let fetch = request(feed: feed, appName: appName, appVersion: appVersion) else { return .failed }
        guard let answer = try? await transport(fetch) else { return .failed }
        return evaluate(data: answer.0, status: answer.1, currentVersion: appVersion, feed: feed)
    }

    /// The real trip, through a session the app hands in. An ephemeral one
    /// is what the app uses: a version check must not keep cookies, a cache
    /// or any state on the person's disk.
    public static func check(repo: String, appName: String, appVersion: String,
                             session: URLSession) async -> Check {
        guard let feed = UpdateFeed.github(repo: repo) else { return .failed }
        return await check(feed: feed, appName: appName, appVersion: appVersion, session: session)
    }

    public static func check(feed: UpdateFeed, appName: String, appVersion: String,
                             session: URLSession) async -> Check {
        await check(feed: feed, appName: appName, appVersion: appVersion) { request in
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// The notice shows once per version: a person who has seen "2.1" needs
    /// no reminder at tomorrow's check, but "2.2" is news again. Compared by
    /// the version's shape, so "v2.1" and "2.1" are the same news once told.
    /// The app remembers the last version it announced and passes it in.
    public static func noticeVersion(for check: Check, lastNotified: String?) -> String? {
        guard case .newer(let version, _, _) = check else { return nil }
        guard pieces(of: displayVersion(version)) != pieces(of: displayVersion(lastNotified ?? "")) else { return nil }
        return version
    }
}
