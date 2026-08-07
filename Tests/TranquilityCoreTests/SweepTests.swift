import XCTest
@testable import TranquilityCore

/// The sweep decides which sessions stop being watched, so its failure mode is the
/// worst one this app has: a real session, quietly dropped, with no evidence.
///
/// Every rule the sweep claims is asserted here, including the two that exist only
/// because their absence caused a real incident — the tty filter that inferred
/// "nobody is here" from a proxy and hid live conversations, and the per-poll skip
/// line that wrote 2.3 GB in five days.
final class SweepTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Coordinator.resetSweepStateForTesting()
        collector.reset()
        let sink = collector
        Coordinator.trace = { line in sink.append(line) }
    }

    override func tearDown() {
        Coordinator.trace = nil
        Coordinator.resetSweepStateForTesting()
        super.tearDown()
    }

    /// `trace` is `@Sendable` and fires from whatever thread swept, so the sink is
    /// a locked reference type rather than test-case state.
    final class Collector: @unchecked Sendable {
        private var lines: [String] = []
        private let lock = NSLock()
        func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        func reset() { lock.lock(); lines = []; lock.unlock() }
        func all() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }
    private let collector = Collector()
    private func logged() -> [String] { collector.all() }
    private func lines(containing needle: String) -> [String] {
        logged().filter { $0.contains(needle) }
    }

    private func session(_ id: String, cwd: String = "/Users/x/Projects/promotions") -> WaitingSession {
        WaitingSession(sessionId: id, latestId: 1, createdAtMs: 0, cwd: cwd,
                       tty: "ttys001", promptId: nil, transcriptPath: nil,
                       lastAssistantMessage: "done", notificationMatcher: nil,
                       summaryText: nil, hookEvent: .stop, callsign: nil)
    }

    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    // MARK: - Rule 1: liveness governs, and only liveness

    func testALiveSessionIsNeverRetiredNoMatterHowLongItSits() {
        let s = [session("live-1")]
        // A full day of polling while live.
        for minute in stride(from: 0, through: 24 * 60, by: 5) {
            Coordinator.sweep(s, live: ["live-1"], now: t0.addingTimeInterval(Double(minute) * 60))
        }
        XCTAssertTrue(Coordinator.retiredSessionsForTesting().isEmpty,
                      "a session the agents API still reports must never be retired")
        XCTAssertTrue(lines(containing: "session is gone").isEmpty,
                      "a live session must never be described as gone")
    }

    func testReturningToLifeUnretiresAndSaysSo() {
        let s = [session("flaky-1")]
        Coordinator.sweep(s, live: [], now: t0)
        Coordinator.sweep(s, live: [], now: t0.addingTimeInterval(200))
        XCTAssertEqual(Coordinator.retiredSessionsForTesting(), ["flaky-1"])

        Coordinator.sweep(s, live: ["flaky-1"], now: t0.addingTimeInterval(300))
        XCTAssertTrue(Coordinator.retiredSessionsForTesting().isEmpty,
                      "the agents API reporting it live must un-retire it immediately")
        XCTAssertEqual(lines(containing: "is live again").count, 1,
                       "coming back is an important event and must be said exactly once")
    }

    // MARK: - Rule 2: retirement is timed, not counted

    func testManyPollsInsideTheDelayDoNotRetire() {
        let s = [session("gone-1")]
        // The liveness probe is cached for 6s, so a burst of polls can be ONE
        // observation. Counting polls would retire on the third of these.
        for i in 0..<50 {
            Coordinator.sweep(s, live: [], now: t0.addingTimeInterval(Double(i) * 0.2))
        }
        XCTAssertTrue(Coordinator.retiredSessionsForTesting().isEmpty,
                      "50 polls across 10 seconds is not 50 observations")
    }

    func testRetiresOnlyAfterSustainedAbsence() {
        let s = [session("gone-2")]
        Coordinator.sweep(s, live: [], now: t0)
        Coordinator.sweep(s, live: [], now: t0.addingTimeInterval(119))
        XCTAssertTrue(Coordinator.retiredSessionsForTesting().isEmpty, "119s is inside the delay")

        Coordinator.sweep(s, live: [], now: t0.addingTimeInterval(121))
        XCTAssertEqual(Coordinator.retiredSessionsForTesting(), ["gone-2"])
        // "retired" alone also matches the heartbeat's counts, which is a different
        // line saying a different thing — match the announcement itself.
        XCTAssertEqual(logged().filter { $0.hasPrefix("retired ") }.count, 1,
                       "retirement is an important event and must be said exactly once")
    }

    // MARK: - Rule 3: never overlog

    func testGoneIsSaidOncePerSessionNotOncePerPoll() {
        let s = [session("gone-3")]
        for i in 0..<500 {
            Coordinator.sweep(s, live: [], now: t0.addingTimeInterval(Double(i) * 0.1))
        }
        XCTAssertEqual(lines(containing: "session is gone").count, 1,
                       "the 2.3 GB incident: this line was written once per poll")
    }

    func testARetiredSessionIsSilentForever() {
        let s = [session("gone-4")]
        Coordinator.sweep(s, live: [], now: t0)
        Coordinator.sweep(s, live: [], now: t0.addingTimeInterval(200))   // retires
        let afterRetirement = logged().count
        for i in 0..<1_000 {
            Coordinator.sweep(s, live: [], now: t0.addingTimeInterval(300 + Double(i)))
        }
        // Only heartbeats may accumulate, and at most one per 300s of the 1000s span.
        let added = logged().count - afterRetirement
        XCTAssertLessThanOrEqual(added, 4, "a retired session must not narrate itself")
        XCTAssertEqual(lines(containing: "session is gone").count, 1)
    }

    func testTwoHundredDeadSessionsCostTwoHundredLinesTotalNotPerPoll() {
        let many = (0..<200).map { session("dead-\($0)") }
        for i in 0..<100 {
            Coordinator.sweep(many, live: [], now: t0.addingTimeInterval(Double(i)))
        }
        // 200 "gone" lines, and nothing else until the delay elapses.
        XCTAssertEqual(lines(containing: "session is gone").count, 200)
        XCTAssertLessThan(logged().count, 210,
                          "the real queue: 200 dead sessions must not scale with poll count")
    }

    // MARK: - Never miss the state

    func testHeartbeatReportsStateEvenWhenNothingChanges() {
        let s = [session("gone-5")]
        Coordinator.sweep(s, live: [], now: t0)                              // first: heartbeat
        Coordinator.sweep(s, live: [], now: t0.addingTimeInterval(301))      // second
        Coordinator.sweep(s, live: [], now: t0.addingTimeInterval(602))      // third
        let beats = lines(containing: "sweep:")
        XCTAssertEqual(beats.count, 3,
                       "a log that rolled must still be able to answer 'what is it doing'")
        XCTAssertTrue(beats.last!.contains("retired"), "the heartbeat carries the counts")
    }

    // MARK: - Bookkeeping cannot outlive the queue

    func testLeavingTheQueueIsForgottenSoAReturnIsObservedFresh() {
        let s = session("recycled-1")
        Coordinator.sweep([s], live: [], now: t0)
        Coordinator.sweep([s], live: [], now: t0.addingTimeInterval(200))    // retired
        XCTAssertEqual(Coordinator.retiredSessionsForTesting(), ["recycled-1"])

        Coordinator.sweep([], live: [], now: t0.addingTimeInterval(300))     // dismissed
        XCTAssertTrue(Coordinator.retiredSessionsForTesting().isEmpty,
                      "state must not outlive the queue it describes")

        Coordinator.sweep([s], live: [], now: t0.addingTimeInterval(400))    // returns
        XCTAssertEqual(lines(containing: "session is gone").count, 2,
                       "a session that comes back is observed from scratch, not assumed dead")
    }
}
