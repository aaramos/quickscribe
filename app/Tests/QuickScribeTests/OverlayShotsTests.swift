import AppKit
import XCTest
@testable import QuickScribe

/// Walks the pill through every state and checks its layout. Set QS_OVERLAY_SHOTS to a
/// folder to also save a picture of each state's contents (live glass isn't included).
@MainActor
final class OverlayShotsTests: XCTestCase {
    func testEveryStateFitsAndHides() async throws {
        let overlay = OverlayController()
        let folder = ProcessInfo.processInfo.environment["QS_OVERLAY_SHOTS"]
        let states: [(String, OverlayController.State)] = [
            ("recording", .recording(mode: "Polish")),
            ("words", .recording(mode: "Polish", words: "Revenue was 4.2 million last quarter")),
            ("long", .recording(mode: "Polish", words: "Revenue was 4.2 million last quarter, up 17 percent, and we are hiring 12 more engineers by December 15th, so let's meet on Friday")),
            ("processing", .processing), ("inserted", .inserted),
            ("degraded", .degraded), ("cancelled", .cancelled), ("copied", .copied), ("mode", .modeChanged("Concise")),
            ("error", .error("Couldn't hear you. Check your mic (device: Logitech C920).")),
        ]
        for (name, state) in states {
            overlay.show(state)
            if state.isRecording { for i in 0..<60 { overlay.pushLevel(0.18) } }   // an ordinary speaking voice
            try await Task.sleep(nanoseconds: 350_000_000)
            let frame = overlay.panelFrameForTesting
            XCTAssertTrue(overlay.panelIsVisibleForTesting, name)
            XCTAssertEqual(frame.height, state.isRecording ? 78 : 40, name)
            let screen = try XCTUnwrap(NSScreen.screens.first { $0.frame.contains(frame) })
            XCTAssertEqual(frame.midX, screen.visibleFrame.midX, accuracy: 1, name)
            XCTAssertLessThanOrEqual(frame.maxY, screen.visibleFrame.maxY, name)
            XCTAssertGreaterThan(frame.maxY, screen.visibleFrame.maxY - 20, name)
            XCTAssertLessThanOrEqual(frame.width, 520, name)
            XCTAssertGreaterThanOrEqual(frame.width, 40, name)
            print("PILL", name, Int(frame.width), "x", Int(frame.height))
            if let folder, let view = overlay.panelContentForTesting {
                view.appearance = NSAppearance(named: .aqua)
                save(view, to: "\(folder)/\(name).png")
                view.appearance = NSAppearance(named: .darkAqua)
                save(view, to: "\(folder)/\(name)-dark.png")
                view.appearance = nil
            }
        }
        overlay.show(.hidden)
        XCTAssertEqual(overlay.state, .hidden)
    }

    func testNormalSpeechFillsMostOfTheWaveHeight() {
        func loudness(rms: Double) -> Double { WaveformView.loudness(fromLevel: rms * 6) }
        XCTAssertEqual(WaveformView.loudness(fromLevel: 0), 0)
        XCTAssertEqual(loudness(rms: 0.003), 0, "room noise stays flat")
        XCTAssertGreaterThan(loudness(rms: 0.01), 0.25, "quiet speech")
        XCTAssertGreaterThan(loudness(rms: 0.03), 0.6, "normal speech")
        XCTAssertEqual(loudness(rms: 0.1), 1, "loud speech")
    }

    private func save(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

final class InsertionTargetTests: XCTestCase {
    func testChoosesWhereTextGoes() {
        XCTAssertEqual(InsertionTarget.classify(role: "AXTextArea", hasTextCursor: false), .textField)
        XCTAssertEqual(InsertionTarget.classify(role: "AXGroup", hasTextCursor: true), .textField)
        XCTAssertEqual(InsertionTarget.classify(role: "AXList", hasTextCursor: false), .notText)
        XCTAssertEqual(InsertionTarget.classify(role: "AXButton", hasTextCursor: false), .notText)
        XCTAssertEqual(InsertionTarget.classify(role: "AXWebArea", hasTextCursor: false), .unsure)
        XCTAssertEqual(InsertionTarget.classify(role: nil, hasTextCursor: false), .unsure)
    }
}
