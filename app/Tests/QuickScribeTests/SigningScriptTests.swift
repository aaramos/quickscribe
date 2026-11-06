import XCTest

/// The release key decides which build macOS calls "the same app", so its
/// use belongs to codesign alone. Apple's own words on the -A import flag:
/// "Allow any application to access the imported key without warning
/// (insecure, not recommended!)". The script runs once on a person's real
/// login keychain, where a silent mistake cannot be undone quietly, so the
/// mistake is pinned here instead.
final class SigningScriptTests: XCTestCase {
    private func scriptText() throws -> String {
        let here = URL(fileURLWithPath: #filePath)          // app/Tests/QuickScribeTests/SigningScriptTests.swift
        let script = here.deletingLastPathComponent()       // app/Tests/QuickScribeTests
            .deletingLastPathComponent()                    // app/Tests
            .deletingLastPathComponent()                    // app
            .appendingPathComponent("make_signing_identity.sh")
        return try String(contentsOf: script, encoding: .utf8)
    }

    func testTheImportNamesCodesignAndNothingElse() throws {
        let text = try scriptText()
        var sawImport = false
        for line in text.split(separator: "\n") where line.contains("security import") {
            sawImport = true
            XCTAssertFalse(line.contains(" -A"),
                           "the imported key must not open itself to every app: \(line)")
            XCTAssertTrue(line.contains("-T /usr/bin/codesign"),
                          "codesign is the one named user of the key: \(line)")
        }
        XCTAssertTrue(sawImport, "the script must still import an identity")
    }

    func testTheFirstUseConfirmationIsAnnouncedAndTriggered() throws {
        // The script warns in plain words, THEN signs a throwaway file, so if
        // macOS is going to ask about the key it asks during the one-time setup
        // and not mid-release. Most imports name codesign as the key's user up
        // front and no dialog ever appears, so the text must offer the ask as
        // a possibility, never promise one.
        let text = try scriptText()
        XCTAssertTrue(text.contains("may ask"), "the confirmation is offered, not promised")
        XCTAssertFalse(text.contains("expect a confirmation"), "no outcome may be promised")
        XCTAssertTrue(text.contains("Always Allow"), "the person is told what to click if it appears")
        XCTAssertTrue(text.contains("codesign --force -s \"$NAME\""),
                      "the script signs a probe file so any question comes during setup")
    }
}
