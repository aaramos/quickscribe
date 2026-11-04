import Foundation

public struct HistoryEntry: Codable, Equatable, Sendable {
    public let raw: String
    public let polished: String
    public let profile: String
    public let ts: Double
    public init(raw: String, polished: String, profile: String, ts: Double) {
        self.raw = raw; self.polished = polished; self.profile = profile; self.ts = ts
    }
}

/// The last 50 dictations, in a file only this user can read. Saving happens off
/// the main thread and a failed save never affects the dictation.
public final class HistoryStore: @unchecked Sendable {
    public static let limit = 50

    private let fileURL: URL
    private let queue = DispatchQueue(label: "quickscribe.history")
    private var entries: [HistoryEntry]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let data = try? Data(contentsOf: fileURL)
        entries = data.flatMap { try? JSONDecoder().decode([HistoryEntry].self, from: $0) } ?? []
    }

    /// Newest first.
    public func recent() -> [HistoryEntry] {
        queue.sync { Array(entries.reversed()) }
    }

    public func add(_ entry: HistoryEntry) {
        queue.async { [self] in
            entries.append(entry)
            entries.removeFirst(max(0, entries.count - Self.limit))
            do {
                try save()
            } catch {
                // Never the dictation itself: only the failure goes in the log.
                NSLog("QuickScribe: history not saved: \(error.localizedDescription)")
            }
        }
    }

    /// For tests: returns once pending saves are done.
    public func waitForSaves() { queue.sync {} }

    private func save() throws {
        let folder = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
