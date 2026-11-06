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
        // The script is expected to warn in plain words before it wakes the
        // dialog, and to wake it itself with a throwaway signing, so the
        // click happens during the one-time setup and not mid-release.
        let text = try scriptText()
        XCTAssertTrue(text.contains("Always Allow"), "the person must be told what to click")
        XCTAssertTrue(text.contains("codesign --force -s \"$NAME\""),
                      "the script signs a probe file so macOS asks once, during setup")
    }
}
