import XCTest
@testable import TranquilityCore

final class ExitWatchTests: XCTestCase {

    private func live(_ id: String, _ harness: String = "claude-code",
                      _ name: String? = nil)
        -> (id: String, harness: String, sessionName: String?) {
        (id: id, harness: harness, sessionName: name)
    }

    func testFirstObserveSeedsAndReportsNothing() {
        var watch = ExitWatch()
        // Two agents already running when the watch is constructed. The first
        // call must only learn the baseline, never report them as dead.
        let out = watch.observe([live("a", "claude-code", "tb-a"),
                                 live("b", "codex", "tb-b")])
        XCTAssertTrue(out.isEmpty)
    }

    func testAnAgentThatLeavesIsReportedOnce() {
        var watch = ExitWatch()
        _ = watch.observe([live("a", "claude-code", "tb-a"),
                           live("b", "claude-code", "tb-b")])
        // b is gone this tick.
        let gone = watch.observe([live("a", "claude-code", "tb-a")])
        XCTAssertEqual(gone.map(\.id), ["b"])
        XCTAssertEqual(gone.first?.harness, "claude-code")
        XCTAssertEqual(gone.first?.sessionName, "tb-b")
        // Not reported again on the next tick.
        let again = watch.observe([live("a", "claude-code", "tb-a")])
        XCTAssertTrue(again.isEmpty)
    }

    func testALiveAgentIsNeverReported() {
        var watch = ExitWatch()
        _ = watch.observe([live("a")])
        for _ in 0..<5 {
            XCTAssertTrue(watch.observe([live("a")]).isEmpty)
        }
    }

    func testSessionNameResolvedLaterIsCarriedForward() {
        var watch = ExitWatch()
        // Seen alive first with no name resolved yet, then with a name.
        _ = watch.observe([live("a", "claude-code", nil)])
        _ = watch.observe([live("a", "claude-code", "tb-a")])
        // Now it vanishes, and a tick where the name is momentarily nil must
        // still carry the name learned earlier.
        let gone = watch.observe([])
        XCTAssertEqual(gone.first?.sessionName, "tb-a")
    }

    func testSecondsAliveMeasuresFromFirstSighting() {
        var watch = ExitWatch()
        let t0 = Date()
        _ = watch.observe([live("a", "claude-code", "tb-a")], now: t0)
        // Stays alive for a while, changing nothing.
        _ = watch.observe([live("a", "claude-code", "tb-a")], now: t0.addingTimeInterval(30))
        let gone = watch.observe([], now: t0.addingTimeInterval(90))
        XCTAssertEqual(gone.first?.secondsAlive, 90)
    }

    func testAnAgentWithNoSessionNameStillReportsButHasNowhereToLook() {
        var watch = ExitWatch()
        _ = watch.observe([live("a", "codex", nil)])
        let gone = watch.observe([])
        XCTAssertEqual(gone.map(\.id), ["a"])
        XCTAssertNil(gone.first?.sessionName)
    }
}
