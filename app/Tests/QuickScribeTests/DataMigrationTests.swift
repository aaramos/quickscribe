import XCTest
@testable import QuickScribe

/// The folder rename "QuickScribe Native" → "QuickScribe" must never lose custom
/// prompts. Three cases: old only (moved), new only (untouched), both (new kept,
/// old left alone).
final class DataMigrationTests: XCTestCase {
    private func sandbox() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Creates <root>/<name>/prompts.json holding `marker`, so we can see where it went.
    @discardableResult
    private func makeFolder(in root: URL, named name: String, marker: String) -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try! marker.write(to: folder.appendingPathComponent("prompts.json"), atomically: true, encoding: .utf8)
        return folder
    }

    private func marker(in folder: URL) -> String? {
        try? String(contentsOf: folder.appendingPathComponent("prompts.json"), encoding: .utf8)
    }

    func testOldFolderOnlyIsMovedAndKeepsCustomPrompts() {
        let root = sandbox()
        let old = makeFolder(in: root, named: "QuickScribe Native", marker: #"{"concise":"my custom prompt"}"#)
        let new = root.appendingPathComponent("QuickScribe", isDirectory: true)

        XCTAssertEqual(DataMigration.migrate(oldFolder: old, newFolder: new), .moved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "old folder should be gone after the move")
        XCTAssertEqual(marker(in: new), #"{"concise":"my custom prompt"}"#, "custom prompts must arrive intact")
    }

    func testNewFolderOnlyIsUntouchedAndNothingMoves() {
        let root = sandbox()
        let old = root.appendingPathComponent("QuickScribe Native", isDirectory: true)  // absent
        let new = makeFolder(in: root, named: "QuickScribe", marker: "fresh install")

        XCTAssertEqual(DataMigration.migrate(oldFolder: old, newFolder: new), .nothingToMove)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(marker(in: new), "fresh install")
    }

    func testBothFoldersKeepsTheNewOneAndLeavesTheOldAlone() {
        let root = sandbox()
        let old = makeFolder(in: root, named: "QuickScribe Native", marker: "old prompts")
        let new = makeFolder(in: root, named: "QuickScribe", marker: "new prompts")

        XCTAssertEqual(DataMigration.migrate(oldFolder: old, newFolder: new), .newFolderExists)
        XCTAssertEqual(marker(in: old), "old prompts", "the old folder must survive untouched")
        XCTAssertEqual(marker(in: new), "new prompts", "the new folder must win")
    }

    func testMoveFailureKeepsBothFolders() throws {
        // A new folder whose parent path is a file makes the move fail; both
        // folders must survive regardless.
        let root = sandbox()
        let old = makeFolder(in: root, named: "QuickScribe Native", marker: "old prompts")
        try "not a directory".write(to: root.appendingPathComponent("blocked"), atomically: true, encoding: .utf8)
        let new = root.appendingPathComponent("blocked/QuickScribe", isDirectory: true)

        XCTAssertEqual(DataMigration.migrate(oldFolder: old, newFolder: new), .failed)
        XCTAssertEqual(marker(in: old), "old prompts", "a refused move must not destroy anything")
    }
}
