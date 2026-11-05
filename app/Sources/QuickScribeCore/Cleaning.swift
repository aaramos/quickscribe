import Foundation

/// Which model cleans up: Apple's on-device one, or the person's service.
public enum CleanupRoute: Equatable, Sendable { case apple, service }

/// Text cleanup behind one interface, so the session asks for cleaned words
/// without knowing whose model answers. `AppleCleaner` is the default;
/// `EndpointCleaner` runs the person's own OpenAI-compatible service.
public protocol Cleaning: Sendable {
    func clean(_ text: String, instructions: String) async throws -> String
}

extension AppleCleaner: Cleaning {}

/// Cleanup on the person's service, through the same client as speech.
/// Failures arrive as `EndpointError`, whose `message` is already a plain
/// sentence the app can show.
public struct EndpointCleaner: Cleaning {
    private let client: OpenAICompatClient
    private let model: String

    public init(client: OpenAICompatClient, model: String) {
        self.client = client
        self.model = model
    }

    public func clean(_ text: String, instructions: String) async throws -> String {
        try await client.clean(text: text, model: model, systemPrompt: instructions)
    }
}
