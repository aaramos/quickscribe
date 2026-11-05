import Foundation
import Security

/// Where the API key lives. The real store is the macOS Keychain; tests use the
/// in-memory one. The key is NEVER kept in preference files.
public protocol SecretStoring: Sendable {
    func secret() -> String?
    func setSecret(_ value: String?) throws
}

public enum MemorySecrets {
    /// For tests only.
    public final class Store: SecretStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        public init(_ value: String? = nil) { self.value = value }
        public func secret() -> String? { lock.lock(); defer { lock.unlock() }; return value }
        public func setSecret(_ value: String?) throws {
            lock.lock(); defer { lock.unlock() }
            self.value = KeychainSecrets.usable(value)   // blank means cleared, same as the Keychain store
        }
    }
}

/// Keychain-backed key storage (Apple's Security framework, generic password).
public final class KeychainSecrets: SecretStoring {
    private let service: String
    public init(service: String) { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "api-key"]
    }

    /// An empty or blank value means "no key": it clears the entry instead of
    /// storing nothing, so a pasted-then-deleted key leaves no stray item.
    static func usable(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    public func secret() -> String? {
        var item: CFTypeRef?
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ value: String?) throws {
        guard let key = Self.usable(value) else {
            let removed = SecItemDelete(query as CFDictionary)
            if removed != errSecSuccess && removed != errSecItemNotFound {
                throw endpointError("Could not clear the saved key (keychain status \(removed)).")
            }
            return
        }
        var add = query
        add[kSecValueData as String] = Data(key.utf8)
        let made = SecItemAdd(add as CFDictionary, nil)
        if made == errSecSuccess { return }
        guard made == errSecDuplicateItem else {
            throw endpointError("Could not save the key (keychain status \(made)).")
        }
        let updated = SecItemUpdate(query as CFDictionary,
                                    [kSecValueData as String: Data(key.utf8)] as CFDictionary)
        if updated != errSecSuccess { throw endpointError("Could not save the key (keychain status \(updated)).") }
    }
}

private func endpointError(_ message: String) -> NSError {
    NSError(domain: "local.quickscribe.native", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

/// A person's own OpenAI-compatible service. Empty address means "use Apple"
/// (the default), so nothing about a custom service is active until typed in.
public struct EndpointSettings: Equatable, Sendable {
    /// As typed, e.g. "http://127.0.0.1:1234/v1". "" means Apple on both routes.
    public var address: String
    public var speechModel: String
    public var cleanupModel: String
    public var language: String
    /// Apple stays the default; Custom only applies with an address set.
    public var useCustomSpeech: Bool
    public var useCustomCleanup: Bool

    /// Apple's speech follows the Mac's language, so custom speech defaults to
    /// the same. A language explicitly typed or saved wins over the default.
    public static var deviceLanguage: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    public init(address: String = "", speechModel: String = "", cleanupModel: String = "", language: String? = nil,
                useCustomSpeech: Bool = false, useCustomCleanup: Bool = false) {
        self.address = address
        self.speechModel = speechModel
        self.cleanupModel = cleanupModel
        self.language = language ?? Self.deviceLanguage
        self.useCustomSpeech = useCustomSpeech
        self.useCustomCleanup = useCustomCleanup
    }

    public var isEnabled: Bool { !normalizedAddress.isEmpty }
    public var speechUsesEndpoint: Bool { isEnabled && useCustomSpeech }
    public var cleanupUsesEndpoint: Bool { isEnabled && useCustomCleanup }

    /// Trimmed, scheme added when missing, no trailing slash.
    public var normalizedAddress: String {
        var a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return "" }
        if !a.contains("://") { a = "http://" + a }
        while a.hasSuffix("/") { a = String(a.dropLast()) }
        return a
    }

    /// Most OpenAI-compatible servers put these calls under `/v1`; add it only
    /// when the typed address has no path yet.
    public var apiBase: URL? {
        let a = normalizedAddress
        guard !a.isEmpty, let url = URL(string: a), url.host != nil else { return nil }
        if url.path.isEmpty || url.path == "/" { return url.appendingPathComponent("v1") }
        return url
    }

    public var hostName: String { apiBase?.host ?? "" }

    /// Loopback, `.local`, and private LAN ranges count as local.
    /// True for loopback and private network numbers, and only for them. Host
    /// names are never local: "127.evil.com" points wherever its owner says,
    /// so a name that merely begins with a private number gets no free pass.
    public static func isLocal(host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))   // URL.host wraps IPv6 in brackets
        if h == "localhost" || h.hasSuffix(".local") { return true }
        if h == "::1" || h.hasPrefix("fe80:") { return true }   // loopback and link-local IPv6
        guard let octets = ipv4Octets(h) else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _): return true
        case (172, let b): return (16...31).contains(b)
        case (192, 168): return true
        case (169, 254): return true
        default: return false
        }
    }

    /// Exactly four decimal numbers from 0 to 255, nothing else. Leading
    /// zeros, blanks, "-1", "256" and names all fail.
    static func ipv4Octets(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber),
                  part.utf8.first != 0x30 || part.count == 1,   // no leading zeros
                  let value = Int(part), (0...255).contains(value)
            else { return nil }
            octets.append(value)
        }
        return octets
    }

    /// nil when the address is fine (or absent). Otherwise a plain sentence
    /// explaining what to fix. Non-local plain http is refused because words
    /// and the key would travel unencrypted.
    public var addressProblem: String? {
        let a = normalizedAddress
        if a.isEmpty { return address.trimmingCharacters(in: .whitespaces).isEmpty ? nil : "Remove the spaces from the address, or clear it." }
        guard let url = URL(string: a), let host = url.host, !host.isEmpty else { return "That does not look like a service address. For example: http://192.168.1.20:1234/v1" }
        if url.scheme == "http" && !Self.isLocal(host: host) {
            return "Plain http is refused for a non-local address. Your words and key would travel unencrypted. Use https, or an address on this Mac or your local network."
        }
        guard url.scheme == "http" || url.scheme == "https" else { return "The address must start with http or https." }
        return nil
    }
}

/// Reads and writes the connection settings. Address and model names live in
/// preferences; the API key lives only in the given secret store (Keychain).
public final class EndpointSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    public let secrets: SecretStoring
    private let addressKey = "endpoint.address"
    private let speechKey = "endpoint.speechModel"
    private let cleanupKey = "endpoint.cleanupModel"
    private let speechCustomKey = "endpoint.useCustomSpeech"
    private let cleanupCustomKey = "endpoint.useCustomCleanup"

    public init(defaults: UserDefaults = .standard, secrets: SecretStoring) {
        self.defaults = defaults
        self.secrets = secrets
    }

    public func load() -> EndpointSettings {
        EndpointSettings(address: defaults.string(forKey: addressKey) ?? "",
                         speechModel: defaults.string(forKey: speechKey) ?? "",
                         cleanupModel: defaults.string(forKey: cleanupKey) ?? "",
                         // Language is not persisted: there is no setting for it, and a stored
                         // one would go stale when the Mac's language changes.
                         useCustomSpeech: defaults.bool(forKey: speechCustomKey),
                         useCustomCleanup: defaults.bool(forKey: cleanupCustomKey))
    }

    public func save(_ settings: EndpointSettings) {
        defaults.set(settings.address, forKey: addressKey)
        defaults.set(settings.speechModel, forKey: speechKey)
        defaults.set(settings.cleanupModel, forKey: cleanupKey)
        defaults.set(settings.useCustomSpeech, forKey: speechCustomKey)
        defaults.set(settings.useCustomCleanup, forKey: cleanupCustomKey)
        defaults.synchronize()
    }

    public func apiKey() -> String? { secrets.secret() }
    public func setAPIKey(_ key: String?) throws { try secrets.setSecret(key) }
}
