import AppKit
import XCTest
@testable import QuickScribe
import QuickScribeCore

/// Drives the real Settings window: its controls, the saved file and Apple's model.
@MainActor
final class SettingsWindowTests: XCTestCase {
    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { all(type, in: $0) } + ((view as? T).map { [$0] } ?? [])
    }
    private func button(_ title: String, _ root: NSView) -> NSButton {
        all(NSButton.self, in: root).first { $0.title == title }!
    }

    /// Settings now owns the connection section too, so every test needs a store.
    /// The suite name is throwaway and the secrets live in memory.
    private func makeSettings(library: PromptLibrary) -> SettingsWindow {
        let suite = "qs-settings-tests-\(UUID().uuidString)"
        let store = EndpointSettingsStore(defaults: UserDefaults(suiteName: suite)!, secrets: MemorySecrets.Store())
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return SettingsWindow(library: library, endpointStore: store)
    }

    func testEditSaveResetAndTryItOnSampleText() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("prompts.json")
        let library = PromptLibrary(fileURL: url)
        let settings = makeSettings(library: library)
        settings.show()
        defer { settings.window?.close() }
        let root = try XCTUnwrap(settings.window?.contentView)
        let boxes = all(NSTextView.self, in: root)
        let editor = try XCTUnwrap(boxes.first { $0.string == FactoryPrompts.polish })
        let save = button("Save", root), reset = button("Reset to Default", root)
        XCTAssertFalse(save.isEnabled)

        editor.string = "Remove fillers. Output only the text."
        editor.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: editor))
        XCTAssertTrue(save.isEnabled)
        save.performClick(nil)
        XCTAssertEqual(PromptLibrary(fileURL: url).prompt("polish"), "Remove fillers. Output only the text.")

        reset.performClick(nil)
        XCTAssertEqual(editor.string, FactoryPrompts.polish)
        XCTAssertEqual(PromptLibrary(fileURL: url).prompt("polish"), FactoryPrompts.polish)

        try XCTSkipIf(AppleCleaner.unavailableReason() != nil, "Apple's model isn't available")
        let test = button("Test Prompt", root)
        test.performClick(nil)
        for _ in 0..<150 where !test.isEnabled { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(test.isEnabled, "Test Prompt never finished")
        let output = try XCTUnwrap(boxes.first { !$0.isEditable })
        XCTAssertTrue(output.string.contains("3"), output.string)
        XCTAssertFalse(output.string.lowercased().contains("um so"), output.string)
    }
    func testPromptTestRunsTheSelectedRoute() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("prompts.json")
        let library = PromptLibrary(fileURL: url)
        let settings = makeSettings(library: library)
        settings.show()
        defer { settings.window?.close() }
        let root = try XCTUnwrap(settings.window?.contentView)
        let editor = try XCTUnwrap(all(NSTextView.self, in: root).first { $0.string == FactoryPrompts.polish })
        var seen: [(route: CleanupRoute, prompt: String)] = []
        settings.promptTester = { route, _, instructions, _, _ in
            seen.append((route, instructions)); return "done"
        }
        let test = button("Test Prompt", root)
        func run() async throws {
            test.performClick(nil)
            for _ in 0..<150 where !test.isEnabled {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertTrue(test.isEnabled, "Test Prompt never finished")
        }

        try await run()
        XCTAssertEqual(seen.last?.route, .apple)
        XCTAssertEqual(seen.last?.prompt, FactoryPrompts.polish)

        // Cleanup switched to Custom: the test follows the route and its
        // longer factory set, even though the editor never changed. An
        // address must be set first: Custom without one stays Apple.
        let address = try XCTUnwrap(all(NSTextField.self, in: root).first { $0.placeholderString == "http://192.168.1.20:1234/v1" })
        address.stringValue = "http://127.0.0.1:1234/v1"
        address.sendAction(address.action!, to: address.target)
        let popups = all(NSPopUpButton.self, in: root)
        XCTAssertEqual(popups.count, 2, "expected speech and cleanup pickers only")
        let cleanup = popups[1]
        cleanup.selectItem(at: 1)
        cleanup.sendAction(cleanup.action!, to: cleanup.target)
        try await run()
        XCTAssertEqual(seen.last?.route, .service)
        XCTAssertEqual(seen.last?.prompt, ServicePrompts.polish,
                       "the service route tests its own factory set")

        // A saved prompt of the person's own wins on both routes.
        editor.string = "My own words."
        editor.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: editor))
        button("Save", root).performClick(nil)
        for pick in [0, 1] {
            cleanup.selectItem(at: pick)
            cleanup.sendAction(cleanup.action!, to: cleanup.target)
            try await run()
            XCTAssertEqual(seen.last?.route, pick == 0 ? .apple : .service)
            XCTAssertEqual(seen.last?.prompt, "My own words.")
        }
    }

}
