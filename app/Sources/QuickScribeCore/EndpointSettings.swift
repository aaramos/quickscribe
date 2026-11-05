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
            self.value = (value?.isEmpty ?? true) ? nil : value   // clearing is the same as the Keychain store
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
        let status = value.flatMap({ $0.isEmpty ? nil : $0 })
            .map { data in
                var add = query
                add[kSecValueData as String] = Data(data.utf8)
                let made = SecItemAdd(add as CFDictionary, nil)
                if made == errSecSuccess || made == errSecDuplicateItem { return made }
                return made
            }
        if value?.isEmpty ?? true {
            let removed = SecItemDelete(query as CFDictionary)
            if removed != errSecSuccess && removed != errSecItemNotFound {
                throw endpointError("Could not clear the saved key (keychain status \(removed)).")
            }
            return
        }
        guard let status else { return }
        if status == errSecDuplicateItem {
            let updated = SecItemUpdate(query as CFDictionary,
                                        [kSecValueData as String: Data((value ?? "").utf8)] as CFDictionary)
            if updated != errSecSuccess { throw endpointError("Could not save the key (keychain status \(updated)).") }
        } else if status != errSecSuccess {
            throw endpointError("Could not save the key (keychain status \(status)).")
        }
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

    public init(address: String = "", speechModel: String = "", cleanupModel: String = "", language: String = "en",
                useCustomSpeech: Bool = false, useCustomCleanup: Bool = false) {
        self.address = address
        self.speechModel = speechModel
        self.cleanupModel = cleanupModel
        self.language = language
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
    public static func isLocal(host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".local") { return true }
        if h == "::1" { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return h.hasPrefix("127.") }
        switch (parts[0], parts[1]) {
        case (127, _): return true
        case (10, _): return true
        case (172, let b) where (16...31).contains(b): return true
        case (192, 168): return true
        case (169, 254): return true
        default: return false
        }
    }

    public var usesPlainHTTP: Bool { normalizedAddress.hasPrefix("http://") }

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
    private let languageKey = "endpoint.language"
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
                         language: defaults.string(forKey: languageKey) ?? "en",
                         useCustomSpeech: defaults.bool(forKey: speechCustomKey),
                         useCustomCleanup: defaults.bool(forKey: cleanupCustomKey))
    }

    public func save(_ settings: EndpointSettings) {
        defaults.set(settings.address, forKey: addressKey)
        defaults.set(settings.speechModel, forKey: speechKey)
        defaults.set(settings.cleanupModel, forKey: cleanupKey)
        defaults.set(settings.language, forKey: languageKey)
        defaults.set(settings.useCustomSpeech, forKey: speechCustomKey)
        defaults.set(settings.useCustomCleanup, forKey: cleanupCustomKey)
        defaults.synchronize()
    }

    public func apiKey() -> String? { secrets.secret() }
    public func setAPIKey(_ key: String?) throws { try secrets.setSecret(key) }
}
