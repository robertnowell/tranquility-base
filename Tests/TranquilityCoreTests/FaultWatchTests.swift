import XCTest
@testable import TranquilityCore

/// The fault spine: `FaultWatch` reports a row the first time it is amber
/// for a given reason, and never again for a reason it has already reported
/// for that row.
final class FaultWatchTests: XCTestCase {

    private func row(_ id: String, fault: SessionRow.Fault? = nil) -> SessionRow {
        SessionRow(id: id, name: id, aux: fault?.reason ?? id,
                   lamp: fault == nil ? .running : .fault,
                   harness: "claude-code", fault: fault)
    }

    private let dropped = SessionRow.Fault(
        kind: .agentFault,
        reason: "API Error: Connection lost mid-response. The response above may be incomplete.")
    private let expired = SessionRow.Fault(
        kind: .agentFault, reason: "API Error: 401 OAuth access token has expired.")
    private let permission = SessionRow.Fault(kind: .agentWaiting, reason: "waiting on a permission")

    func testTheFirstTickSeedsAndSaysNothing() {
        // A launch that finds standing faults must not page for each of them.
        var watch = FaultWatch()
        XCTAssertEqual(watch.observe([row("a", fault: dropped), row("b")]).map(\.id), [])
    }

    func testANewFaultReportsOnceAndThenHoldsItsTongue() {
        var watch = FaultWatch()
        _ = watch.observe([row("a"), row("b")])
        XCTAssertEqual(watch.observe([row("a", fault: dropped), row("b")]).map(\.id), ["a"])
        XCTAssertEqual(watch.observe([row("a", fault: dropped), row("b")]).map(\.id), [])
        XCTAssertEqual(watch.observe([row("a", fault: dropped), row("b")]).map(\.id), [])
    }

    func testANewReasonOnTheSameRowIsANewFailure() {
        var watch = FaultWatch()
        _ = watch.observe([row("a", fault: dropped)])
        XCTAssertEqual(watch.observe([row("a", fault: expired)]).map(\.fault), [expired])
    }

    func testEveryKindOfAmberReports() {
        // A permission prompt is amber and reports, under its own kind.
        var watch = FaultWatch()
        _ = watch.observe([row("a")])
        let reported = watch.observe([row("a", fault: permission)])
        XCTAssertEqual(reported.map(\.fault?.kind), [.agentWaiting])
    }

    func testAFaultThatClearsAndReturnsReportsAgain() {
        // It happened, it went away, it happened again: two failures.
        var watch = FaultWatch()
        _ = watch.observe([row("a")])
        XCTAssertEqual(watch.observe([row("a", fault: dropped)]).count, 1)
        XCTAssertEqual(watch.observe([row("a")]).count, 0)
        XCTAssertEqual(watch.observe([row("a", fault: dropped)]).count, 1)
    }

    func testAnAmberTheAssemblerDeclinedIsNotReported() {
        // "standing by" is carried as `fault: nil` by the assembler: the
        // person switched the row on a second ago, and nothing is wrong.
        var watch = FaultWatch()
        _ = watch.observe([])
        let standingBy = SessionRow(id: "w", name: "w", aux: "standing by", lamp: .fault)
        XCTAssertEqual(watch.observe([standingBy]).count, 0)
    }

    func testARowThatLeavesTheGridForgetsItsFault() {
        var watch = FaultWatch()
        _ = watch.observe([row("a", fault: dropped)])
        XCTAssertEqual(watch.observe([]).count, 0)
        // Back with the same reason: nothing remembered it, so it is new.
        XCTAssertEqual(watch.observe([row("a", fault: dropped)]).count, 1)
    }
}
