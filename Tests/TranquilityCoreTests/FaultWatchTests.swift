import XCTest
@testable import TranquilityCore

/// The fault spine: `FaultWatch` reports a row the first time it is at fault
/// on a given harness sentence, and never for a sentence it has already
/// reported for that row.
final class FaultWatchTests: XCTestCase {

    private func row(_ id: String, fault: String? = nil, aux: String = "") -> SessionRow {
        SessionRow(id: id, name: id, aux: aux, lamp: fault == nil ? .running : .fault,
                   harness: "claude-code", fault: fault)
    }

    private let dropped = "API Error: Connection lost mid-response. The response above may be incomplete."

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

    func testANewSentenceOnTheSameRowIsANewFailure() {
        var watch = FaultWatch()
        _ = watch.observe([row("a", fault: dropped)])
        let reported = watch.observe([row("a", fault: "API Error: 401 OAuth access token has expired.")])
        XCTAssertEqual(reported.map(\.fault), ["API Error: 401 OAuth access token has expired."])
    }

    func testAFaultThatClearsAndReturnsReportsAgain() {
        // The harness said it, it went away, the harness said it again: two
        // failures, because two things happened.
        var watch = FaultWatch()
        _ = watch.observe([row("a")])
        XCTAssertEqual(watch.observe([row("a", fault: dropped)]).count, 1)
        XCTAssertEqual(watch.observe([row("a")]).count, 0)
        XCTAssertEqual(watch.observe([row("a", fault: dropped)]).count, 1)
    }

    func testAnAmberWithoutAHarnessSentenceIsNotAFault() {
        // A permission prompt, a restart, standing by: amber the person
        // caused, carried as `fault: nil` by the assembler, and never filed.
        var watch = FaultWatch()
        _ = watch.observe([])
        let waiting = SessionRow(id: "w", name: "w", aux: "waiting on a permission", lamp: .fault)
        XCTAssertEqual(watch.observe([waiting]).count, 0)
    }

    func testARowThatLeavesTheGridForgetsItsFault() {
        var watch = FaultWatch()
        _ = watch.observe([row("a", fault: dropped)])
        XCTAssertEqual(watch.observe([]).count, 0)
        // Back with the same sentence: nothing remembered it, so it is new.
        XCTAssertEqual(watch.observe([row("a", fault: dropped)]).count, 1)
    }
}
