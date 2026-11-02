import XCTest
@testable import QuickScribe

/// Focused regression tests for the polish-budget + blank-result policy
/// (t_a0fb24bb). The policy is pure (PolishPlanner), so no AppKit, no
/// URLSession, no live sidecar — isolated by construction.
final class PolishPlannerTests: XCTestCase {

    // MARK: result classification (usable / blank / degraded)

    func testNormalPolishResultIsUsable() {
        XCTAssertTrue(PolishPlanner.usable(polished: "Clean text.", degraded: false))
    }
    func testEmptyPolishResultIsUnusable() {
        XCTAssertFalse(PolishPlanner.usable(polished: "", degraded: false))
    }
    func testWhitespaceOnlyPolishResultIsUnusable() {
        XCTAssertFalse(PolishPlanner.usable(polished: "  \n \t ", degraded: false))
    }
    func testNilPolishResultIsUnusable() {
        XCTAssertFalse(PolishPlanner.usable(polished: nil, degraded: false))
    }
    func testDegradedEchoIsUnusableRegardlessOfText() {
        XCTAssertFalse(PolishPlanner.usable(polished: "anything", degraded: true))
    }

    // MARK: budget rules

    func testFreshBudgetRequestsFullBucket() {
        XCTAssertEqual(PolishPlanner.firstStep(budget: 1.5, spent: 0), .request(timeout: 1.5))
    }
    func testTimeoutNeverExceedsRemainingBudget() {
        // Binary floats: 5.0 - 3.2 == 1.7999999999999998 — assert the rule
        // (timeout equals the remaining budget, within rounding), never an
        // exact decimal literal.
        guard case .request(let to) = PolishPlanner.firstStep(budget: 5, spent: 3.2) else {
            return XCTFail("expected .request while budget remains")
        }
        XCTAssertEqual(to, 1.8, accuracy: 1e-9)
    }
    func testExhaustedBudgetMeansNoRequestRawImmediately() {
        // The old max(0.2, ...) floor fired a guaranteed-late request here.
        XCTAssertEqual(PolishPlanner.firstStep(budget: 1.5, spent: 1.5), .insertRaw)
        XCTAssertEqual(PolishPlanner.firstStep(budget: 1.5, spent: 1.6), .insertRaw)
    }
    func testRetryOnlyWhileTimeRemains() {
        let step = PolishPlanner.stepAfterResult(budget: 1.5, spent: 0.7, attempt: 1, stale: false,
                                                 polished: "", degraded: true)
        guard case .request(let to) = step else { return XCTFail("expected retry .request, got \(step)") }
        XCTAssertEqual(to, 0.8, accuracy: 1e-9)
    }
    func testNoRetryRoomAfterFirstFailureMeansRaw() {
        XCTAssertEqual(PolishPlanner.stepAfterResult(budget: 1.5, spent: 1.5, attempt: 1, stale: false,
                                                     polished: "", degraded: true),
                       .insertRaw)
    }
    func testRetryAtMostOnceEvenWithPlentyOfBudget() {
        XCTAssertEqual(PolishPlanner.stepAfterResult(budget: 10, spent: 0.1, attempt: 2, stale: false,
                                                     polished: "", degraded: true),
                       .insertRaw)
    }
    func testSecondAttemptUsableResultIsInserted() {
        XCTAssertEqual(PolishPlanner.stepAfterResult(budget: 10, spent: 0.5, attempt: 2, stale: false,
                                                     polished: "Tight prose.", degraded: false),
                       .insertPolished("Tight prose."))
    }

    // MARK: stale-callback rejection (cancel / new session)

    func testStaleCallbackIsAlwaysNoOp() {
        // Usable text from a superseded generation must NOT insert either.
        XCTAssertEqual(PolishPlanner.stepAfterResult(budget: 10, spent: 0, attempt: 1, stale: true,
                                                     polished: "late winner", degraded: false),
                       .stale)
    }

    // MARK: whole-flow simulation (mirrors the SessionController.runPolish
    // glue against a stub polish client; consume = seconds the stub takes)

    private struct Flow { let timeouts: [TimeInterval]; let finalText: String?; let degraded: Bool? }

    private func simulate(budget: Double, consume: TimeInterval,
                          stub: (TimeInterval) -> (String?, Bool)) -> Flow {
        var timeouts: [TimeInterval] = []
        var spent = 0.0
        var attempt = 1
        var step = PolishPlanner.firstStep(budget: budget, spent: 0)
        while true {
            switch step {
            case .stale:                 return Flow(timeouts: timeouts, finalText: nil, degraded: nil)
            case .insertRaw:             return Flow(timeouts: timeouts, finalText: "RAW", degraded: true)
            case .insertPolished(let t): return Flow(timeouts: timeouts, finalText: t, degraded: false)
            case .request(let to):
                timeouts.append(to)
                spent = min(spent + consume, budget)      // requests consume their slice
                let (p, d) = stub(to)
                step = PolishPlanner.stepAfterResult(budget: budget, spent: spent, attempt: attempt,
                                                     stale: false, polished: p, degraded: d)
                attempt += 1
            }
        }
    }

    func testFlowEmptyThenNormalOnRetryInsertsPolished() {
        var n = 0
        let f = simulate(budget: 2.5, consume: 0.4) { _ in
            n += 1; return n == 1 ? ("", false) : ("Clean.", false)
        }
        XCTAssertEqual(f.timeouts.count, 2)
        XCTAssertEqual(f.timeouts[0], 2.5, accuracy: 1e-9)
        XCTAssertEqual(f.timeouts[1], 2.1, accuracy: 1e-9)   // exactly the remaining budget
        XCTAssertEqual(f.finalText, "Clean.")
        XCTAssertEqual(f.degraded, false)
    }

    func testFlowBlankTwiceEndsRawDegraded() {
        let f = simulate(budget: 2.5, consume: 0.4) { _ in ("", false) }
        XCTAssertEqual(f.timeouts.count, 2)
        XCTAssertEqual(f.finalText, "RAW")
        XCTAssertEqual(f.degraded, true)
    }

    func testFlowExhaustedBudgetMakesZeroRequests() {
        let f = simulate(budget: 0, consume: 0) { _ in ("never", false) }
        XCTAssertEqual(f.timeouts, [])
        XCTAssertEqual(f.finalText, "RAW")
        XCTAssertEqual(f.degraded, true)
    }

    func testFlowFullTimeoutConsumptionLeavesNoRetryRoom() {
        // First request burns the entire bucket (timeout == budget): the
        // exhausted budget forbids the retry — raw goes in immediately.
        let f = simulate(budget: 1.5, consume: 1.5) { _ in (nil, true) }
        XCTAssertEqual(f.timeouts, [1.5])
        XCTAssertEqual(f.finalText, "RAW")
        XCTAssertEqual(f.degraded, true)
    }

    func testFlowEveryRequestTimeoutWithinRemainingBudget() {
        let f = simulate(budget: 2.0, consume: 0.5) { _ in (nil, true) }
        XCTAssertEqual(f.timeouts.count, 2)                      // one request + one retry, never more
        XCTAssertLessThanOrEqual(f.timeouts[0], 2.0 + 1e-9)      // never over the full bucket
        XCTAssertLessThanOrEqual(f.timeouts[1], 1.5 + 1e-9)      // budget minus first request
    }
}
