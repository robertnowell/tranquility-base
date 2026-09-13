import XCTest
@testable import TranquilityCore

/// The four bands, which had no tests at all while they lived in the app layer
/// (#381). Every case below is a rule somebody paid for once: two app crashes,
/// a blue lamp that held for a day, a row that reshuffled between refreshes,
/// two sessions that both showed as "Projects", and one conversation appearing
/// twice.
final class GridRowsTests: XCTestCase {

    // MARK: - Fixtures

    private let A = "8f14e45f-ceea-467a-9eef-2b9c1b2dc9f0"
    private let B = "c4ca4238-a0b9-4382-8dcc-509a6f75849b"
    private let C = "45c48cce-2e2d-4fa8-8aec-0eb4779d1ba9"

    private func waiting(_ id: String, latestId: Int64 = 5, heardThrough: Int64? = nil,
                         path: String? = "/t.jsonl", callsign: String? = nil) -> WaitingSession {
        var w = WaitingSession(sessionId: id, latestId: latestId, createdAtMs: 0,
                               cwd: "/Users/x/Projects/thing", transcriptPath: path,
                               hookEvent: .stop)
        w.heardThrough = heardThrough
        w.callsign = callsign
        return w
    }

    private func live(_ id: String, pid: Int = 100, status: String? = nil,
                      harness: String = ClaudeCodeAdapter().id,
                      cwd: String? = "/Users/x/Projects/thing") -> LiveSession {
        var s = LiveSession(pid: pid, sessionId: id)
        s.cwd = cwd
        s.status = status
        s.harness = harness
        return s
    }

    private func found(_ id: String, liveness: SessionDiscovery.Liveness = .gone,
                       harness: String = ClaudeCodeAdapter().id,
                       title: String? = "a closed one") -> SessionDiscovery.Session {
        SessionDiscovery.Session(
            sessionId: id, cwd: "/Users/x/Projects/thing", transcriptPath: "/t.jsonl",
            title: title, lastActivityAt: Date(timeIntervalSince1970: 1_757_000_000),
            answered: true, activity: nil, liveness: liveness, revivable: true,
            harness: harness)
    }

    private func inputs(
        waiting: [WaitingSession] = [], known: [WaitingSession] = [],
        discovered: [SessionDiscovery.Session] = [],
        live: [String: LiveSession] = [:],
        switchedOff: Set<String> = [], switchedOn: Set<String> = [],
        evidence: @escaping (String, SessionActivity.TurnBoundary?)
            -> SessionActivity.Evidence? = { _, _ in nil },
        isHeadless: @escaping (String?) -> Bool = { _ in false },
        family: @escaping (String) -> [String] = { [$0] },
        supersedes: @escaping (String, Int64) -> Bool = { _, _ in false },
        isInFlight: @escaping (String) -> Bool = { _ in false },
        callsigns: [String: String] = [:]
    ) -> GridAssembler.RowInputs {
        GridAssembler.RowInputs(
            waiting: waiting, known: known, discovered: discovered, liveById: live,
            boundaries: [:], switchedOff: switchedOff, switchedOn: switchedOn,
            evidence: evidence, isHeadless: isHeadless, family: family,
            supersedesWaiting: supersedes, isInFlight: isInFlight,
            closedCallsigns: callsigns)
    }

    // MARK: - The liveness probe, and the crash it caused twice

    /// `claude --resume <id>` leaves the original process running and adds a
    /// second live entry carrying the SAME sessionId. Built with
    /// `uniqueKeysWithValues` that TRAPS, and it killed the app twice: 06 Aug
    /// 14:35 and 07 Aug 17:39, the second crash eighteen seconds after a resume
    /// started. EXC_BREAKPOINT in a refresh timer, so it fires as soon as the
    /// duplicate appears and there is no recovery path.
    func testADuplicateSessionIdDoesNotTrapAndFirstSeenWins() {
        var notes: [String] = []
        let out = GridAssembler.smoothedLive(
            found: [live(A, pid: 100), live(A, pid: 200)], remembered: [:],
            now: Date(), grace: 30, log: { notes.append($0) })
        XCTAssertEqual(out.live.count, 1)
        XCTAssertEqual(out.live[A]?.pid, 100, "first seen wins, matching every other path")
        XCTAssertTrue(notes.contains { $0.contains("duplicate sessionId") },
                      "the collision is logged rather than silently settled")
    }

    /// A session seen live within the grace window but absent from THIS read
    /// keeps its last-known entry rather than dropping straight to closed.
    func testATransientProbeMissIsSmoothedWithinTheGraceWindow() {
        let now = Date()
        let remembered = [A: (session: live(A), at: now.addingTimeInterval(-5))]
        let out = GridAssembler.smoothedLive(found: [], remembered: remembered,
                                             now: now, grace: 30)
        XCTAssertNotNil(out.live[A], "a blink must not close a session")
    }

    /// And a session actually gone reads gone the moment the window lapses,
    /// which is the half that makes the smoothing honest rather than sticky.
    func testASessionGoneLongerThanTheGraceWindowIsDropped() {
        let now = Date()
        let remembered = [A: (session: live(A), at: now.addingTimeInterval(-60))]
        let out = GridAssembler.smoothedLive(found: [], remembered: remembered,
                                             now: now, grace: 30)
        XCTAssertNil(out.live[A])
        XCTAssertNil(out.remembered[A], "and it is pruned, not kept for ever")
    }

    // MARK: - Band 1: sessions with an unanswered turn

    func testAWaitingSessionIsGreenAndUnreadUntilItIsHeard() {
        let rows = GridAssembler.rows(inputs(waiting: [waiting(A)])).rows
        XCTAssertEqual(rows.first?.lamp, .ready)
        XCTAssertEqual(rows.first?.read, .unread)

        let heard = GridAssembler.rows(
            inputs(waiting: [waiting(A, latestId: 5, heardThrough: 5)])).rows
        XCTAssertEqual(heard.first?.read, .opened, "heard, but still owed an answer")
        XCTAssertEqual(heard.first?.lamp, .ready)
    }

    /// Green says "you have not answered this". While a reply to this very turn
    /// is in flight that is the most misleading thing the grid can say: the
    /// cursor does not advance until the send confirms, so the row goes on
    /// asking for the user seconds after they spoke to it.
    func testAReplyInFlightTurnsAWaitingRowBlueRatherThanGreen() {
        let rows = GridAssembler.rows(
            inputs(waiting: [waiting(A)], supersedes: { id, _ in id == self.A })).rows
        XCTAssertEqual(rows.first?.lamp, .working)
    }

    /// The process outranks the stored turn (19 Aug). A session locked at a
    /// dialog has not read your last reply and is not about to, so green would
    /// offer to read out something it said before it was killed while the only
    /// move that helps is in the terminal.
    func testABlockedProcessOutranksTheWaitingTurnAndSpendsTheColumnOnItsReason() {
        let rows = GridAssembler.rows(inputs(
            waiting: [waiting(A)],
            live: [A: live(A, status: "waiting")])).rows
        XCTAssertEqual(rows.first?.lamp, .fault)
        XCTAssertNotEqual(rows.first?.aux, SessionRow.shortId(A),
                          "an amber row spends its column on why, like every other one")
    }

    // MARK: - Band 2 and 3: live sessions

    /// Ruled 12 Aug: headless is headless whether it is running or not.
    /// Liveness used to hide these by accident, but a LONG cron job is live and
    /// got a row, then vanished on exit instead of joining the closed band.
    func testAHeadlessSessionGetsNoRowInEitherLiveBand() {
        let stored = GridAssembler.rows(inputs(
            known: [waiting(A)], live: [A: live(A)], isHeadless: { _ in true })).rows
        XCTAssertTrue(stored.isEmpty)

        let fresh = GridAssembler.rows(inputs(
            live: [A: live(A)], isHeadless: { _ in true })).rows
        XCTAssertTrue(fresh.isEmpty)
    }

    /// Walked via `known`, which is already latestId DESC, so the band is
    /// recency-ordered like the waiting band above it. Reading
    /// `Dictionary.values` instead reshuffled rows between refreshes.
    func testTheLiveBandKeepsTheStoresRecencyOrderRatherThanHashOrder() {
        let live = [A: live(A), B: live(B), C: live(C)]
        let known = [waiting(C, latestId: 30), waiting(B, latestId: 20),
                     waiting(A, latestId: 10)]
        let rows = GridAssembler.rows(inputs(known: known, live: live)).rows
        XCTAssertEqual(rows.map(\.id), [C, B, A])
    }

    /// A live session with no stored events has no recorded transcript path, so
    /// that band derives one, and it must still get a row rather than being
    /// skipped for having nothing to rank it by.
    func testALiveSessionWithNoStoredEventsStillGetsARow() {
        let rows = GridAssembler.rows(inputs(live: [A: live(A)])).rows
        XCTAssertEqual(rows.map(\.id), [A])
    }

    /// One row per session, whichever band saw it first.
    func testASessionPlacedByAnEarlierBandIsNotPlacedAgain() {
        let rows = GridAssembler.rows(inputs(
            waiting: [waiting(A)], known: [waiting(A)],
            discovered: [found(A)], live: [A: live(A)])).rows
        XCTAssertEqual(rows.filter { $0.id == A }.count, 1)
    }

    // MARK: - Band 4: the dead, from disk

    /// Everything above band 4 is enumerated from PROCESSES, which is why a
    /// machine restart used to empty the panel. Disk outlives the process, and
    /// enumerates only the population the process list cannot.
    func testTheClosedBandIsUnlitAndSurvivesAMachineWithNoLiveSessions() {
        let rows = GridAssembler.rows(inputs(discovered: [found(A)])).rows
        XCTAssertEqual(rows.map(\.id), [A])
        XCTAssertEqual(rows.first?.lamp, .unlit)
        XCTAssertTrue(rows.first?.revivable == true)
    }

    /// Disk enumerates only the dead. A live session reaching this band would
    /// be the same row by a second route, and two routes to one answer is how
    /// they start disagreeing.
    func testALiveTranscriptOnDiskIsNotAddedBySpiritualDuplication() {
        let rows = GridAssembler.rows(inputs(discovered: [found(A, liveness: .live)])).rows
        XCTAssertTrue(rows.isEmpty)
    }

    /// One conversation, one row (ruled 10 Sep). A session Claude Code
    /// continued under a new id (the left arrow does this) is the same agent.
    func testAContinuedConversationDoesNotGetASecondRow() {
        let rows = GridAssembler.rows(inputs(
            waiting: [waiting(A)],
            discovered: [found(B)],
            family: { _ in [self.A, self.B] })).rows
        XCTAssertEqual(rows.map(\.id), [A], "B is A's other half, not a second agent")
    }

    /// A minted callsign outlives the process that earned it, so a dead row
    /// keeps the name you have been calling it.
    func testAClosedRowKeepsItsMintedCallsignWhenTheTranscriptHasNoTitle() {
        let rows = GridAssembler.rows(inputs(
            discovered: [found(A, title: nil)], callsigns: [A: "promotions copy"])).rows
        XCTAssertEqual(rows.first?.name, "promotions copy")
    }

    /// The harness names itself in the hover when it is not the default one.
    /// Codex used to get a whole second band for this line.
    func testAClosedCodexRowSaysSoInTheHoverRatherThanInItsOwnBand() {
        let rows = GridAssembler.rows(inputs(
            discovered: [found(A, harness: CodexAdapter().id)])).rows
        XCTAssertEqual(rows.first?.detail, "Codex session")
    }

    // MARK: - The switch, applied last and to every band at once

    func testASwitchedOffRowGoesQuietRatherThanDisappearing() {
        let rows = GridAssembler.rows(inputs(
            known: [waiting(A)], live: [A: live(A)], switchedOff: [A])).rows
        XCTAssertEqual(rows.first?.lamp, .running)
        XCTAssertTrue(rows.first?.switchedOff == true)
    }

    /// The switch is CLEARED, not merely overridden, when a turn arrives, or
    /// the row would quietly drop off the grid again as soon as the user read
    /// it. Returned rather than written, so this function has no side effects.
    func testATurnArrivingClearsTheFiledLampRatherThanOverridingIt() {
        let verdict = GridAssembler.rows(inputs(waiting: [waiting(A)], switchedOff: [A]))
        XCTAssertEqual(verdict.clearSwitches, [A])
        XCTAssertFalse(verdict.rows.first?.switchedOff == true,
                       "a waiting session is not filed")
    }

    /// Filing a dead session would say the user switched off something that has
    /// no lamp to switch.
    func testADeadRowIsNotFiledBecauseItHasNoLampToSwitch() {
        let rows = GridAssembler.rows(inputs(
            discovered: [found(A)], switchedOff: [A])).rows
        XCTAssertEqual(rows.first?.lamp, .unlit)
        XCTAssertFalse(rows.first?.switchedOff == true)
    }

    // MARK: - Ordering, after every band

    /// A session that is merely alive drops below the ones doing something,
    /// without disturbing the recency order the bands spent the whole function
    /// establishing.
    func testQuietRowsSinkBelowTheOnesAskingForYou() {
        let verdict = GridAssembler.rows(inputs(
            waiting: [waiting(A)], known: [waiting(B)],
            discovered: [found(C)], live: [B: live(B)], switchedOff: [B]))
        XCTAssertEqual(verdict.rows.map { $0.id }, [A, B, C],
                       "waiting, then the filed one, then the dead")
    }

    /// Recorded so the card can ask the same question the rows answered and get
    /// the same answer.
    func testEveryLiveRowsHarnessIsReportedBack() {
        let verdict = GridAssembler.rows(inputs(
            live: [A: live(A), B: live(B, harness: CodexAdapter().id)]))
        XCTAssertEqual(verdict.harnessById[A], ClaudeCodeAdapter().id)
        XCTAssertEqual(verdict.harnessById[B], CodexAdapter().id)
    }
}
