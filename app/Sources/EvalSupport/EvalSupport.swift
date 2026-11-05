import Foundation
import QuickScribeCore

/// Plumbing the eval runners share: a corpus line, a JSON line out, and the
/// service cleaner built from the environment with no defaults, so nothing
/// about a particular machine ever hides in the tool.
public struct Item: Decodable, Sendable {
    public let id: String
    public let raw: String
    public init(id: String, raw: String) { self.id = id; self.raw = raw }
}

public func evalCorpus(_ path: String) throws -> [Item] {
    try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
}

public func evalEmit(_ row: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}

/// "service_polish" checks the same guard as "polish".
public func evalGuardMode(_ variant: String) -> String {
    variant.hasPrefix("service_") ? String(variant.dropFirst("service_".count)) : variant
}

/// QSE_BASE=<url> QSE_MODEL=<name> and QSE_KEY=<key> or QSE_KEYFILE=<json>.
public func evalServiceCleaner() -> any Cleaning {
    let env = ProcessInfo.processInfo.environment
    let address = env["QSE_BASE"] ?? ""
    let model = env["QSE_MODEL"] ?? ""
    var key = env["QSE_KEY"]
    if key == nil, let keyPath = env["QSE_KEYFILE"], !keyPath.isEmpty {
        let path = (keyPath as NSString).expandingTildeInPath
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let auth = json["auth"] as? [String: Any] {
            key = auth["api_key"] as? String
        }
    }
    let settings = EndpointSettings(address: address, cleanupModel: model, useCustomCleanup: true)
    return EndpointCleaner(client: OpenAICompatClient(settings: settings, apiKey: key, timeout: 120),
                           model: model)
}

/// True when the environment names a server, a model and a key: the runners
/// skip the service side quietly otherwise.
public func evalServiceNamed() -> Bool {
    let env = ProcessInfo.processInfo.environment
    return !(env["QSE_BASE"] ?? "").isEmpty && !(env["QSE_MODEL"] ?? "").isEmpty
        && !((env["QSE_KEY"] ?? "").isEmpty && (env["QSE_KEYFILE"] ?? "").isEmpty)
}
