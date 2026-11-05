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

    /// The request, exactly four lines' worth of nothing: the address, a
    /// generic "QuickScribe/2.0" user agent, JSON preference, nothing else.
    /// No key, no identifier, no words.
    public static func request(repo: String, appName: String, appVersion: String) -> URLRequest? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.httpMethod = "GET"
        r.setValue("\(appName)/\(appVersion)", forHTTPHeaderField: "User-Agent")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return r
    }

    /// Read GitHub's answer. The release's own page URL is what we point at,
    /// so the person lands where they can read what changed.
    public static func evaluate(data: Data, status: Int, currentVersion: String) -> Check {
        guard (200..<300).contains(status) else { return .failed }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let urlString = json["html_url"] as? String,
              let page = URL(string: urlString)
        else { return .malformed }
        guard pieces(of: tag) != nil, pieces(of: currentVersion) != nil else { return .malformed }
        return isNewer(tag, than: currentVersion) ? .newer(version: tag, page: page) : .current
    }

    /// One whole round trip, with the transport as a seam so tests answer
    /// with canned bytes and the real app plugs in URLSession. A thrown
    /// error is just another way of failing, and it stays silent.
    public static func check(repo: String, appName: String, appVersion: String,
                             transport: (URLRequest) async throws -> (Data, Int)) async -> Check {
        guard let fetch = request(repo: repo, appName: appName, appVersion: appVersion) else { return .failed }
        guard let answer = try? await transport(fetch) else { return .failed }
        return evaluate(data: answer.0, status: answer.1, currentVersion: appVersion)
    }

    /// The notice shows once per version: a person who has seen "2.1" needs
    /// no reminder at tomorrow's check, but "2.2" is news again. The app
    /// remembers the last version it announced and passes it in.
    public static func noticeVersion(for check: Check, lastNotified: String?) -> String? {
        guard case .newer(let version, _) = check else { return nil }
        return version == lastNotified ? nil : version
    }
}
