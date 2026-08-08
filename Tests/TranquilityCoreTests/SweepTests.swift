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

    /// Durations are monotonic now, so the fixture clock is an instant we advance.

    /// The app polls every 1–5s. Absence only ages while it is being watched, so a
    /// test that jumps two minutes in one step is simulating an OUTAGE, not waiting.
    @discardableResult
    private func poll(_ sessions: [WaitingSession], live: Set<String> = [],
                      from start: ContinuousClock.Instant,
                      seconds: Int, every step: Int = 5) -> ContinuousClock.Instant {
        var t = start
        for _ in stride(from: 0, through: seconds, by: step) {
            Coordinator.sweep(sessions, live: live, now: t)
            t = t.advanced(by: .seconds(step))
        }
        return t
    }

    private let t0 = ContinuousClock.now

    // MARK: - Rule 1: liveness governs, and only liveness

    func testALiveSessionIsNeverRetiredNoMatterHowLongItSits() {
        let s = [session("live-1")]
        // A full day of polling while live.
        for minute in stride(from: 0, through: 24 * 60, by: 5) {
            Coordinator.sweep(s, live: ["live-1"], now: t0.advanced(by: .milliseconds(Int(Double(minute) * 60 * 1000))))
        }
        XCTAssertTrue(Coordinator.retiredSessionsForTesting().isEmpty,
                      "a session the agents API still reports must never be retired")
        XCTAssertTrue(lines(containing: "skipping").isEmpty,
                      "a live session must never be described as gone")
    }

    func testReturningToLifeUnretiresAndSaysSo() {
        let s = [session("flaky-1")]
        let t = poll(s, from: t0, seconds: 200)
        XCTAssertEqual(Coordinator.retiredSessionsForTesting(), ["flaky-1"])

        Coordinator.sweep(s, live: ["flaky-1"], now: t)
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
            Coordinator.sweep(s, live: [], now: t0.advanced(by: .milliseconds(Int(Double(i) * 0.2 * 1000))))
        }
        XCTAssertTrue(Coordinator.retiredSessionsForTesting().isEmpty,
                      "50 polls across 10 seconds is not 50 observations")
    }

    func testRetiresOnlyAfterSustainedAbsence() {
        let s = [session("gone-2")]
        let t = poll(s, from: t0, seconds: 115)
        XCTAssertTrue(Coordinator.retiredSessionsForTesting().isEmpty, "115s is inside the delay")

        Coordinator.sweep(s, live: [], now: t)
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
            Coordinator.sweep(s, live: [], now: t0.advanced(by: .milliseconds(Int(Double(i) * 0.1 * 1000))))
        }
        XCTAssertEqual(lines(containing: "skipping").count, 1,
                       "the 2.3 GB incident: this line was written once per poll")
    }

    func testARetiredSessionIsSilentForever() {
        let s = [session("gone-4")]
        let t = poll(s, from: t0, seconds: 200)                       // retires
        let afterRetirement = logged().count
        poll(s, from: t, seconds: 1_000)
        // Only heartbeats may accumulate: one per 300s across a 1000s span.
        let added = logged().count - afterRetirement
        XCTAssertLessThanOrEqual(added, 5, "a retired session must not narrate itself")
        XCTAssertEqual(lines(containing: "skipping").count, 1)
    }

    func testTwoHundredDeadSessionsCostOneLineNotTwoHundred() {
        let many = (0..<200).map { session("dead-\($0)") }
        for i in 0..<100 {
            Coordinator.sweep(many, live: [], now: t0.advanced(by: .seconds(i)))
        }
        // Each line is a synchronous write on the main thread, so a burst is a
        // stall. One line carries the same facts: how many, and which projects.
        let announcements = lines(containing: "skipping")
        XCTAssertEqual(announcements.count, 1,
                       "200 dead sessions must cost one line, not two hundred")
        XCTAssertTrue(announcements[0].contains("200 sessions, all gone"),
                      "the count must survive the collapse: \(announcements[0])")
        XCTAssertTrue(announcements[0].contains("promotions×200"),
                      "and so must which projects: \(announcements[0])")
        XCTAssertLessThan(logged().count, 5,
                          "the real queue: 200 dead sessions must not scale with poll count")
    }

    func testAManyLineSummaryNamesTheWorstOffendersAndCountsTheRest() {
        // The real shape of the queue that caused this: replay dominating, a long
        // tail of others. The summary must name the big ones and not print 12 labels.
        var sessions: [WaitingSession] = []
        for (project, n) in [("replay", 107), ("voter", 40), ("commenter", 20),
                             ("content-engine", 12), ("contributor", 6),
                             ("syndit", 2), ("kopi", 1)] {
            for i in 0..<n {
                sessions.append(session("\(project)-\(i)", cwd: "/Users/x/Projects/\(project)"))
            }
        }
        Coordinator.sweep(sessions, live: [], now: t0)
        let line = lines(containing: "skipping").first ?? ""
        XCTAssertTrue(line.contains("188 sessions, all gone"), line)
        XCTAssertTrue(line.contains("replay×107"), line)
        XCTAssertTrue(line.contains("+2 more"), "the tail is counted, not listed: \(line)")
    }

    // MARK: - Never miss the state

    func testHeartbeatReportsStateEvenWhenNothingChanges() {
        let s = [session("gone-5")]
        Coordinator.sweep(s, live: [], now: t0)                              // first: heartbeat
        Coordinator.sweep(s, live: [], now: t0.advanced(by: .seconds(301)))      // second
        Coordinator.sweep(s, live: [], now: t0.advanced(by: .seconds(602)))      // third
        let beats = lines(containing: "sweep:")
        XCTAssertEqual(beats.count, 3,
                       "a log that rolled must still be able to answer 'what is it doing'")
        XCTAssertTrue(beats.last!.contains("retired"), "the heartbeat carries the counts")
    }

    // MARK: - Bookkeeping cannot outlive the queue

    /// `waitingSessions()` is LIMIT 200, so a session can leave the RESULT without
    /// leaving the QUEUE. Forgetting on that basis re-announced older dead sessions
    /// every time a newer one was dismissed and slid one back into view — retirement
    /// never converged. Records expire on their own clock instead.
    func testSlidingOutOfTheQueryWindowDoesNotResurrectASession() {
        let s = session("recycled-1")
        let t = poll([s], from: t0, seconds: 200)                    // retired
        XCTAssertEqual(Coordinator.retiredSessionsForTesting(), ["recycled-1"])
        let announced = lines(containing: "skipping").count

        // Pushed out of the newest-200 window by newer arrivals, then back in.
        Coordinator.sweep([], live: [], now: t.advanced(by: .seconds(5)))
        Coordinator.sweep([s], live: [], now: t.advanced(by: .seconds(10)))

        XCTAssertEqual(Coordinator.retiredSessionsForTesting(), ["recycled-1"],
                       "leaving a truncated query is not evidence of anything")
        XCTAssertEqual(lines(containing: "skipping").count, announced,
                       "a session must not be announced gone twice for sliding in and out")
    }

    func testARecordExpiresOnItsOwnClockOnceNobodyHasSeenItForAnHour() {
        let s = session("stale-1")
        let t = poll([s], from: t0, seconds: 200)
        XCTAssertFalse(Coordinator.retiredSessionsForTesting().isEmpty)
        // Gone from the queue entirely for longer than the retention window.
        Coordinator.sweep([], live: [], now: t.advanced(by: .seconds(3_700)))
        XCTAssertTrue(Coordinator.retiredSessionsForTesting().isEmpty,
                      "bookkeeping must not accumulate forever either")
    }

    // MARK: - Rule 3: only OBSERVED absence ages a session

    func testAnOutageDoesNotAgeASessionIntoRetirement() {
        let s = [session("outage-1")]
        Coordinator.sweep(s, live: [], now: t0)                      // seen absent once
        // Probe down for five minutes: no sweeps at all. Wall-clock arithmetic would
        // retire on the next observation; two observations is not sustained absence.
        Coordinator.sweep(s, live: [], now: t0.advanced(by: .seconds(300)))
        XCTAssertTrue(Coordinator.retiredSessionsForTesting().isEmpty,
                      "a gap in watching is not evidence of absence")
    }

    // MARK: - Rule 4: what is said is symmetric

    func testASessionAnnouncedGoneIsAnnouncedBackEvenIfItNeverRetired() {
        let s = [session("blip-1")]
        Coordinator.sweep(s, live: [], now: t0)                      // "gone" said
        XCTAssertEqual(lines(containing: "skipping").count, 1)
        Coordinator.sweep(s, live: ["blip-1"], now: t0.advanced(by: .seconds(5)))
        XCTAssertEqual(lines(containing: "is live again").count, 1,
                       "the log must retract a death it reported, retired or not")
    }
}
