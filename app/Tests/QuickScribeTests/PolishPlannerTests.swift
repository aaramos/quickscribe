import XCTest
@testable import QuickScribe

final class PolishPlannerTests: XCTestCase {
    func testTimeLeftAsksTheModelWithOnlyTheTimeLeft() {
        XCTAssertEqual(PolishPlanner.firstStep(raw: "um hi", tidied: "Hi", modelReady: true, budget: 1.5, spent: 0.5),
                       .askModel(timeout: 1.0, tidied: "Hi"))
    }
    func testNoTimeLeftInsertsTidiedTextWithoutAskingTheModel() {
        XCTAssertEqual(PolishPlanner.firstStep(raw: "um hi", tidied: "Hi", modelReady: true, budget: 1.5, spent: 1.5),
                       .insert("Hi", cleaned: false))
    }
    func testModelNotReadyStillInsertsTheWords() {
        XCTAssertEqual(PolishPlanner.firstStep(raw: "um hi", tidied: "Hi", modelReady: false, budget: 1.5, spent: 0),
                       .insert("Hi", cleaned: false))
    }
    func testFillerOnlySpeechIsKeptRatherThanDropped() {
        XCTAssertEqual(PolishPlanner.firstStep(raw: "Um.", tidied: "", modelReady: true, budget: 1.5, spent: 0),
                       .insert("Um.", cleaned: false))
    }
    func testModelAnswerIsInsertedAsCleaned() {
        XCTAssertEqual(PolishPlanner.stepAfterModel(output: "Clean.", tidied: "Tidy"), .insert("Clean.", cleaned: true))
    }
    func testRefusedOrBlankModelAnswerFallsBackToTidiedText() {
        XCTAssertEqual(PolishPlanner.stepAfterModel(output: nil, tidied: "Tidy"), .insert("Tidy", cleaned: false))
        XCTAssertEqual(PolishPlanner.stepAfterModel(output: " \n", tidied: "Tidy"), .insert("Tidy", cleaned: false))
    }
}
