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

    func testEditSaveResetAndTryItOnSampleText() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("prompts.json")
        let library = PromptLibrary(fileURL: url)
        let settings = SettingsWindow(library: library)
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
}
