import Foundation
import XCTest
@testable import TranquilityCore

/// How long a launch that is never going to register should take to say so.
///
/// Measured 3 Sep on a real machine: a healthy launch registers in about seven
/// seconds. The budget is thirty, and until now the only early exit was
/// success, so every blocked launch paid the full thirty in silence. These
/// tests pin the two properties that make ending early safe: a still pane ends
/// the wait, and a pane that has not been still for long enough does not.
final class RegistrationWaitTests: XCTestCase {

    /// A registry that never has anything in it.
    private struct Empty: ClaudeAgentsReading {
        func sessions() -> [LiveSession]? { [] }
    }

    /// A registry that produces the session after `afterPolls` reads.
    private final class Appears: ClaudeAgentsReading, @unchecked Sendable {
        let afterPolls: Int
        let cwd: String
        var polls = 0
        init(afterPolls: Int, cwd: String) { self.afterPolls = afterPolls; self.cwd = cwd }
        func sessions() -> [LiveSession]? {
            polls += 1
            guard polls > afterPolls else { return [] }
            return [LiveSession(harness: ClaudeCodeAdapter().id, pid: 1,
                                sessionId: "s1", cwd: cwd, status: nil,
                                name: nil, waitingFor: nil)]
        }
    }

    /// A clock that advances by `interval` on every simulated sleep, so these
    /// run instantly and still exercise the real floor arithmetic.
    private final class Clock: @unchecked Sendable {
        var t = Date(timeIntervalSince1970: 0)
        func now() -> Date { t }
        func sleep(_ s: TimeInterval) { t = t.addingTimeInterval(s) }
    }

    func testStillPaneEndsTheWaitSoonAfterTheFloor() {
        let clock = Clock()
        var reads = 0
        let result = LaunchGreeting.awaitRegistration(
            directory: "/tmp/p", excluding: [], agents: Empty(),
            timeout: 30, interval: 1,
            screen: { reads += 1; return "❯ No, exit\n  Yes, I accept" },
            quietFloor: 12, stillThreshold: 3,
            now: clock.now, sleep: clock.sleep)
        XCTAssertNil(result)
        let elapsed = clock.t.timeIntervalSince1970
        XCTAssertGreaterThanOrEqual(elapsed, 12, "must not conclude before the floor")
        XCTAssertLessThan(elapsed, 17, "a frozen pane should not cost the whole budget")
        XCTAssertGreaterThan(reads, 0)
    }

    /// The property that keeps the floor honest: a healthy launch returns on
    /// registration long before anything looks at the screen.
    func testHealthyLaunchIsUnaffected() {
        let clock = Clock()
        var reads = 0
        let agents = Appears(afterPolls: 6, cwd: "/tmp/p")
        let result = LaunchGreeting.awaitRegistration(
            directory: "/tmp/p", excluding: [], agents: agents,
            timeout: 30, interval: 1,
            screen: { reads += 1; return "a screen" },
            quietFloor: 12, stillThreshold: 3,
            now: clock.now, sleep: clock.sleep)
        XCTAssertEqual(result, "s1")
        XCTAssertLessThan(clock.t.timeIntervalSince1970, 12)
        XCTAssertEqual(reads, 0, "a launch that registers must never be judged on its screen")
    }

    /// A pane that is still WORKING keeps its patience. This is the case the
    /// floor alone cannot cover: something on screen is moving, so it is not
    /// stopped, and it deserves the rest of the budget.
    func testChangingPaneKeepsTheFullBudget() {
        let clock = Clock()
        var n = 0
        let result = LaunchGreeting.awaitRegistration(
            directory: "/tmp/p", excluding: [], agents: Empty(),
            timeout: 30, interval: 1,
            screen: { n += 1; return "spinner frame \(n)" },
            quietFloor: 12, stillThreshold: 3,
            now: clock.now, sleep: clock.sleep)
        XCTAssertNil(result)
        XCTAssertGreaterThanOrEqual(clock.t.timeIntervalSince1970, 30,
                                    "a pane that is still redrawing has not stopped")
    }

    /// An unreadable capture is not evidence. It must not accumulate toward a
    /// verdict, or a tmux hiccup becomes a false "it stopped".
    func testUnreadableScreenNeverConcludes() {
        let clock = Clock()
        let result = LaunchGreeting.awaitRegistration(
            directory: "/tmp/p", excluding: [], agents: Empty(),
            timeout: 30, interval: 1,
            screen: { "" },
            quietFloor: 12, stillThreshold: 3,
            now: clock.now, sleep: clock.sleep)
        XCTAssertNil(result)
        XCTAssertGreaterThanOrEqual(clock.t.timeIntervalSince1970, 30)
    }

    /// No pane to read is the old behaviour exactly, for every caller that has
    /// none.
    func testNoScreenMeansUnchangedBehaviour() {
        let clock = Clock()
        let result = LaunchGreeting.awaitRegistration(
            directory: "/tmp/p", excluding: [], agents: Empty(),
            timeout: 30, interval: 1, screen: nil,
            now: clock.now, sleep: clock.sleep)
        XCTAssertNil(result)
        XCTAssertGreaterThanOrEqual(clock.t.timeIntervalSince1970, 30)
    }
}
