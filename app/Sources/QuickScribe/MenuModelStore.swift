import Foundation
import QuickScribeCore

/// What the menu bar shows for each route, and how it is kept fresh without
/// ever making anyone wait.
///
/// The rules, in one place so they can be read and tested:
/// - Apple Native is always first in both lists.
/// - With no address, both lists are Apple Native only, and the Keychain is
///   never opened.
/// - With an address, the last known list is shown at once; a refresh runs
///   beside it with a short limit, and its answer replaces the list for the
///   NEXT menu open. A menu that is already open is never changed underneath
///   the person reading it.
/// - A chosen server model that the service no longer lists stays shown, with
///   a note, so the choice is never silently swapped for something else.
@MainActor
final class MenuModelStore {
    /// The short limit the review asked for. A slow service answers nothing and
    /// the last list stands; the app never waits on it.
    static var refreshLimit: TimeInterval = 3.0

    /// One route's menu: what to offer, and which one is chosen.
    struct Route: Equatable {
        var entries: [String]
        /// The service could not be reached, so the list is the last known one
        /// (or empty on a first failure).
        var unreachable: Bool
        /// A chosen model the service no longer lists. Shown with a note.
        var missingChoice: String?
        /// A refresh is out and no answer has come yet. The menu says so
        /// instead of claiming the server has no models.
        var checking: Bool = false
        /// The service answered but refused the key, so there is nothing to list.
        var keyRefused: Bool = false
    }

    /// A whole menu's worth of state, read once per open.
    struct Snapshot: Equatable {
        var speech: Route
        var cleanup: Route
        /// True when Apple Native is the live choice on each route.
        var speechIsApple: Bool
        var cleanupIsApple: Bool
    }

    static let appleNative = "Apple Native"

    private let endpointStore: EndpointSettingsStore
    /// The fetch, injected so tests never need a real server or a real clock.
    private let fetch: @Sendable (EndpointSettings, String?) async -> Result<[ModelEntry], EndpointError>

    /// The last list a service actually gave us, per route, in the order the
    /// service sent it. Empty means "nothing known yet".
    private(set) var speechModels: [String] = []
    private(set) var cleanupModels: [String] = []
    /// The address the current lists belong to. A new address invalidates them.
    private var knownAddress = ""
    private(set) var unreachable = false
    private(set) var lastFailure: EndpointError?
    private var inFlight = false
    /// Generation bumps when the address or the key changes, so an answer to a
    /// question that is no longer being asked is thrown away.
    private var generation = 0

    /// The key is read at most once per launch, unless it changes: a Keychain
    /// read can prompt, and a menu opening is no reason to ever prompt.
    private var keyForLaunch: String?
    private var keyRead = false
    /// Told after every refresh settles (an answer, a refusal, or the limit).
    /// The app rebuilds its menu then, so a fresh list is not left unseen.
    var onRefreshFinished: (() -> Void)?
    /// True while a request is out. Read by snapshot() to say "Checking server…".
    private(set) var fetching = false

    init(endpointStore: EndpointSettingsStore,
         fetch: @escaping @Sendable (EndpointSettings, String?) async -> Result<[ModelEntry], EndpointError>
            = { settings, key in
                await OpenAICompatClient(settings: settings, apiKey: key, timeout: 3).fetchModels()
            }) {
        self.endpointStore = endpointStore
        self.fetch = fetch
    }

    // MARK: - What the menu shows

    /// The lists as they stand now. Reading them never touches the network and
    /// never opens the Keychain, so a menu always opens at once.
    func snapshot() -> Snapshot {
        let settings = endpointStore.load()
        guard settings.isEnabled else {
            let appleOnly = Route(entries: [Self.appleNative], unreachable: false, missingChoice: nil)
            return Snapshot(speech: appleOnly, cleanup: appleOnly, speechIsApple: true, cleanupIsApple: true)
        }
        let speech = route(settings.speechModel, models: speechModels, usesService: settings.speechUsesEndpoint)
        let cleanup = route(settings.cleanupModel, models: cleanupModels, usesService: settings.cleanupUsesEndpoint)
        return Snapshot(speech: speech, cleanup: cleanup,
                        speechIsApple: !settings.speechUsesEndpoint,
                        cleanupIsApple: !settings.cleanupUsesEndpoint)
    }

    /// One list: Apple Native, then the service's models, then a note for a
    /// choice the service has stopped listing.
    private func route(_ chosen: String, models: [String], usesService: Bool) -> Route {
        var entries = [Self.appleNative] + models
        // A chosen server model that is no longer listed stays shown. It is
        // appended rather than removed, so the choice reads back honestly.
        let missing = usesService && !chosen.isEmpty && !models.contains(chosen) ? chosen : nil
        if let missing { entries.append(missing) }
        // Before any answer has come, the menu says it is checking rather than
        // claiming the server has no models. A refusal is named as itself, and
        // is not the same thing as a server that cannot be reached.
        let nothingKnown = models.isEmpty
        let refused: Bool
        if case .unauthorized? = lastFailure { refused = true } else { refused = false }
        return Route(entries: entries,
                     unreachable: unreachable && !refused,
                     missingChoice: missing,
                     checking: nothingKnown && fetching,
                     keyRefused: refused)
    }

    // MARK: - Keeping it fresh

    /// Asks the service for its models if that is worth doing right now. Safe to
    /// call from anywhere, including a menu about to open: it returns at once
    /// and the answer arrives later.
    func refreshIfUseful() {
        let settings = endpointStore.load()
        guard settings.isEnabled else {
            // No address: nothing to ask, and no reason to open the Keychain.
            speechModels = []; cleanupModels = []; unreachable = false; lastFailure = nil
            knownAddress = ""
            return
        }
        guard !inFlight else { return }
        let address = settings.normalizedAddress
        if address != knownAddress {
            // A different server: the old lists describe a different machine.
            knownAddress = address
            speechModels = []; cleanupModels = []
            unreachable = false
            generation += 1
        }
        inFlight = true
        fetching = true
        let gen = generation
        Task { [weak self] in
            guard let self else { return }
            let key = self.keyForFetch()
            let result: Result<[ModelEntry], EndpointError>
            do {
                result = try await withDeadline(Self.refreshLimit) { await self.fetch(settings, key) }
            } catch {
                result = .failure(.timedOut)
            }
            self.finish(result, generation: gen)
        }
    }

    /// A key change makes the last known lists suspect (a different key may see
    /// a different set), and makes the cached key stale.
    func keyChanged() {
        keyForLaunch = nil
        keyRead = false
        generation += 1
        unreachable = false
        speechModels = []; cleanupModels = []
    }

    /// The address changed under us: drop what described the old server.
    func addressChanged() {
        generation += 1
        knownAddress = ""
        speechModels = []; cleanupModels = []
        unreachable = false
    }

    private func keyForFetch() -> String? {
        // One read per launch, and only when there is an address to use it on.
        // The app's own Settings already reads it when the person edits it.
        if !keyRead {
            keyRead = true
            keyForLaunch = endpointStore.apiKey()
        }
        return keyForLaunch
    }

    private func finish(_ result: Result<[ModelEntry], EndpointError>, generation gen: Int) {
        inFlight = false
        fetching = false
        guard gen == generation else { return }   // an answer to a question we no longer ask
        switch result {
        case .success(let entries):
            let lists = ModelCatalog.split(entries)
            speechModels = lists.speech
            cleanupModels = lists.cleanup
            unreachable = false
            lastFailure = nil
        case .failure(let error):
            lastFailure = error
            unreachable = true
        }
        onRefreshFinished?()
    }
}
