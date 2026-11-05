import Foundation

/// "Is there a newer release?" The app only ever ASKS GitHub. It downloads
/// nothing, installs nothing, and sends nothing but a generic app name and
/// version. Every failure is silent to the person: dictation never waits on
/// this, and a quiet no is better than a wrong yes.
public enum UpdateChecker {

    /// What one check decided. `failed` covers unreachable, timeouts and
    /// server errors alike: the person never sees the difference, and the
    /// log keeps only a short reason, never a URL with anything in it.
    public enum Check: Equatable, Sendable {
        case newer(version: String, page: URL)
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
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 15)
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
    /// the app never launches a browser at whatever a reply says.
    public static func evaluate(data: Data, status: Int, currentVersion: String, repo: String) -> Check {
        guard (200..<300).contains(status) else { return .failed }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let urlString = json["html_url"] as? String,
              let page = URL(string: urlString),
              page.scheme == "https",
              (page.host ?? "").lowercased() == "github.com",
              page.path.hasPrefix("/\(repo)/releases/")
        else { return .malformed }
        guard pieces(of: tag) != nil, pieces(of: currentVersion) != nil else { return .malformed }
        return isNewer(tag, than: currentVersion) ? .newer(version: displayVersion(tag), page: page) : .current
    }

    /// One whole round trip, with the transport as a seam so tests answer
    /// with canned bytes and the real app plugs in URLSession. A thrown
    /// error is just another way of failing, and it stays silent.
    public static func check(repo: String, appName: String, appVersion: String,
                             transport: (URLRequest) async throws -> (Data, Int)) async -> Check {
        guard let fetch = request(repo: repo, appName: appName, appVersion: appVersion) else { return .failed }
        guard let answer = try? await transport(fetch) else { return .failed }
        return evaluate(data: answer.0, status: answer.1, currentVersion: appVersion, repo: repo)
    }

    /// The real trip, through a session the app hands in. An ephemeral one
    /// is what the app uses: a version check must not keep cookies, a cache
    /// or any state on the person's disk.
    public static func check(repo: String, appName: String, appVersion: String,
                             session: URLSession) async -> Check {
        await check(repo: repo, appName: appName, appVersion: appVersion) { request in
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// The notice shows once per version: a person who has seen "2.1" needs
    /// no reminder at tomorrow's check, but "2.2" is news again. Compared by
    /// the version's shape, so "v2.1" and "2.1" are the same news once told.
    /// The app remembers the last version it announced and passes it in.
    public static func noticeVersion(for check: Check, lastNotified: String?) -> String? {
        guard case .newer(let version, _) = check else { return nil }
        guard pieces(of: displayVersion(version)) != pieces(of: displayVersion(lastNotified ?? "")) else { return nil }
        return version
    }
}
