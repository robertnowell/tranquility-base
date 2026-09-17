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
        callsigns: [String: String] = [:],
        remote: GridAssembler.RowInputs.RemoteAgents = .init(),
        livenessKnown: Bool = true
    ) -> GridAssembler.RowInputs {
        GridAssembler.RowInputs(
            waiting: waiting, known: known, discovered: discovered, liveById: live,
            boundaries: [:], switchedOff: switchedOff, switchedOn: switchedOn,
            evidence: evidence, isHeadless: isHeadless, family: family,
            supersedesWaiting: supersedes, isInFlight: isInFlight,
            closedCallsigns: callsigns, remote: remote, livenessKnown: livenessKnown)
    }

    // MARK: - An empty machine is empty, not unknown

    /// The reboot case, 10 Sep and 16 Sep: every process is gone, the witness
    /// answered [] honestly, and the band used to read "known" off a
    /// non-empty map — so twenty dead sessions with owed turns drew green and
    /// no row anywhere offered to bring one back.
    func testAnAnsweredEmptyProbeGreysAWaitingRowAndOffersRevive() {
        let w = WaitingSession(sessionId: "dead-1", latestId: 1, createdAtMs: 0, hookEvent: .stop)
        let rows = GridAssembler.rows(inputs(waiting: [w], live: [:], livenessKnown: true)).rows
        let row = rows.first { $0.id == "dead-1" }
        XCTAssertEqual(row?.lamp, .unlit)
        XCTAssertEqual(row?.revivable, true)
        XCTAssertEqual(row.map { SessionRow.lampAction(for: $0, on: .grid) }, .revive)
    }

    /// The other answer: the registry could not be read at all. Nobody is
    /// retired and nobody is greyed on the strength of a witness that did not
    /// speak; the row keeps the lamp its turn earns.
    func testAnUnansweredProbeHoldsTheRow() {
        let w = WaitingSession(sessionId: "held-1", latestId: 1, createdAtMs: 0, hookEvent: .stop)
        let rows = GridAssembler.rows(inputs(waiting: [w], live: [:], livenessKnown: false)).rows
        let row = rows.first { $0.id == "held-1" }
        XCTAssertEqual(row?.lamp, .ready)
        XCTAssertEqual(row?.revivable, false)
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
        let rows = GridAssembler.rows(inputs(waiting: [waiting(A)], live: [A: live(A)])).rows
        XCTAssertEqual(rows.first?.lamp, .ready)
        XCTAssertEqual(rows.first?.read, .unread)

        let heard = GridAssembler.rows(
            inputs(waiting: [waiting(A, latestId: 5, heardThrough: 5)], live: [A: live(A)])).rows
        XCTAssertEqual(heard.first?.read, .opened, "heard, but still owed an answer")
        XCTAssertEqual(heard.first?.lamp, .ready)
    }

    /// Green says "you have not answered this". While a reply to this very turn
    /// is in flight that is the most misleading thing the grid can say: the
    /// cursor does not advance until the send confirms, so the row goes on
    /// asking for the user seconds after they spoke to it.
    func testAReplyInFlightTurnsAWaitingRowBlueRatherThanGreen() {
        let rows = GridAssembler.rows(
            inputs(waiting: [waiting(A)], live: [A: live(A)],
                   supersedes: { id, _ in id == self.A })).rows
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

    // MARK: - A row is dated by its conversation, never by its file (15 Sep)

    /// The screenshot that ruled it: "Calendar approved state UX", last turn
    /// 22:01 the night before, second on the panel at 14:09 because Remote
    /// Control had appended a `bridge-session` line to its transcript five
    /// minutes earlier. The file's clock and the conversation's clock
    /// disagree here by sixteen hours, in the direction that lies, and the
    /// row must take the conversation's.
    func testARowIsDatedByItsLastTurnNotByTheFileMovingUnderneathIt() {
        let now = Date()
        let evidence: (String, SessionActivity.TurnBoundary?) -> SessionActivity.Evidence? = { path, _ in
            switch path {
            case "/stale.jsonl":
                // Turn last night; file touched just now by bookkeeping.
                return .init(activity: .idle, observedAt: now.addingTimeInterval(-16 * 3600),
                             modifiedAt: now.addingTimeInterval(-5 * 60))
            case "/fresh.jsonl":
                // Turn an hour ago; file untouched since.
                return .init(activity: .idle, observedAt: now.addingTimeInterval(-3600),
                             modifiedAt: now.addingTimeInterval(-3600))
            default: return nil
            }
        }
        let rows = GridAssembler.rows(inputs(
            waiting: [waiting(A, latestId: 20, path: "/stale.jsonl"),
                      waiting(B, latestId: 10, path: "/fresh.jsonl")],
            live: [A: live(A), B: live(B)], evidence: evidence)).rows
        XCTAssertEqual(rows.map(\.id), [B, A],
                       "the file moved under A; A's conversation did not, so A is older")
        XCTAssertEqual(rows.first { $0.id == A }?.lastActivity,
                       now.addingTimeInterval(-16 * 3600))
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
        let verdict = GridAssembler.rows(inputs(waiting: [waiting(A)], live: [A: live(A)],
                                                switchedOff: [A]))
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
        // A is given a live entry deliberately: since 14 Sep an unanswered turn
        // does not keep a DEAD process lit, so a waiting session with no live
        // entry now sorts with the dead and this fixture would be testing that
        // instead of the ordering it is named for.
        let verdict = GridAssembler.rows(inputs(
            waiting: [waiting(A)], known: [waiting(B)],
            discovered: [found(C)], live: [A: live(A), B: live(B)], switchedOff: [B]))
        XCTAssertEqual(verdict.rows.map { $0.id }, [A, B, C],
                       "waiting, then the filed one, then the dead")
    }

    // MARK: - An unanswered turn does not keep a dead process lit (14 Sep)

    /// Measured on the real panel before the fix: 201 of 223 green rows had no
    /// live process, and five of the twelve rows actually drawn were sessions
    /// that had ended days earlier. Band 1 read `liveById` three times and
    /// never asked whether the session was in it.
    func testAWaitingSessionWhoseProcessIsGoneLosesItsLamp() {
        let verdict = GridAssembler.rows(inputs(
            waiting: [waiting(A)], live: [B: live(B)]))
        let row = verdict.rows.first { $0.id == A }
        XCTAssertEqual(row?.lamp, .unlit,
                       "green means your turn, and there is nothing there to take one")
        XCTAssertTrue(row?.revivable == true,
                      "the answer is already owed; revive-and-answer is the tap")
    }

    /// The same session, still running, keeps the green lamp it always had.
    func testAWaitingSessionThatIsStillAliveKeepsItsGreenLamp() {
        let verdict = GridAssembler.rows(inputs(waiting: [waiting(A)], live: [A: live(A)]))
        XCTAssertEqual(verdict.rows.first?.lamp, .ready)
        XCTAssertFalse(verdict.rows.first?.revivable == true)
    }

    /// **The fail-safe, corrected 16 Sep.** "The probe could not answer" and
    /// "nothing is running" used to be the same value, so the band could only
    /// grey the panel on a non-empty map, and a machine with no sessions at
    /// all (every reboot) drew everything green. They are different inputs
    /// now: a witness that did not speak greys nothing; one that said "nobody"
    /// greys everybody.
    func testAFailedProbeGreysNothingAndAnEmptyOneGreysEverything() {
        let failed = GridAssembler.rows(inputs(waiting: [waiting(A), waiting(B)], live: [:],
                                               livenessKnown: false))
        XCTAssertEqual(failed.rows.map(\.lamp), [.ready, .ready],
                       "a failed probe must not read as a dead machine")
        let empty = GridAssembler.rows(inputs(waiting: [waiting(A), waiting(B)], live: [:],
                                              livenessKnown: true))
        XCTAssertEqual(empty.rows.map(\.lamp), [.unlit, .unlit],
                       "an empty machine must not read as a live one")
    }

    // MARK: - Hearing a row does not move it (14 Sep, reversing #428)

    /// For one afternoon unread green sorted above read green, so that a
    /// remote agent enumerated last could win a slot. Robert reversed it the
    /// same day: a row he had just heard dropped out of its place and was
    /// hard to find again. Green orders by recency, whether or not it is
    /// read, so the local band (already recency-ordered) stays ahead of the
    /// fifth band, unread or not.
    func testHearingARowDoesNotMoveItBelowAnUnreadOne() {
        var agent = AgentSession.of("remote-1", provider: "crobot", state: .completed)
        agent.title = "the cloud one"
        agent.updatedAt = Date(timeIntervalSinceNow: -600)
        // The local row needs a REAL time since #454. `waiting(_:)` stamps
        // `createdAtMs: 0`, so under recency ordering this fixture's local row
        // sat in 1970 and the remote one led on merit — which would have been
        // this test reporting a fixture's clock rather than its own claim.
        // Its claim is that HEARING a row does not move it, and that holds at
        // any timestamp; it just needs the two rows to be comparable.
        var local = waiting(A, heardThrough: 9)
        local.createdAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        let verdict = GridAssembler.rows(inputs(
            waiting: [local], live: [A: live(A)],
            remote: .init(agents: [agent], unread: [agent.id])))
        XCTAssertEqual(verdict.rows.map(\.read), [.opened, .unread],
                       "the local row is heard and the remote one is not")
        XCTAssertEqual(verdict.rows.first?.id, A,
                       "and the heard row keeps its place: read-state does not order the grid")
        XCTAssertEqual(verdict.rows.count, 2, "and the remote row is still there")
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

// MARK: - A provider owns its agents' rows (#459, 15 Sep 2026)

extension GridRowsTests {

    /// **Driving a remote agent must not make its row disappear.** Sending to
    /// it wrote a local `waiting` record under its addressable id; band 1 used
    /// to claim that id and draw a husk — no harness, a terminal door, an
    /// unlit lamp — while band 5 skipped the real remote row as already placed.
    /// Measured on Robert's panel: the crobot task drawn twice, the tap opening
    /// a tmux pane that exited on arrival.
    func testAProviderOwnsItsRowEvenWhenDrivingItWroteALocalRecord() {
        let id = AgentSession.id("ui-task", provider: "crobot")
        var agent = AgentSession.of("ui-task", provider: "crobot", state: .completed)
        agent.title = "the real one"
        agent.repository = "Coframe/crobot"
        agent.url = URL(string: "https://crobot.example/task/ui-task")

        // The husk the drive left behind: a waiting turn AND a known session,
        // both under the agent's addressable id.
        var husk = WaitingSession(sessionId: id, latestId: 1, createdAtMs: 0, hookEvent: .stop)
        husk.heardThrough = nil

        let rows = GridAssembler.rows(inputs(
            waiting: [husk], known: [husk], live: [id: live(id)],
            remote: .init(agents: [agent]))).rows

        let forID = rows.filter { $0.id == id }
        XCTAssertEqual(forID.count, 1, "the agent must have exactly one row, not a husk plus a real one")
        let row = forID.first
        XCTAssertEqual(row?.harness, "crobot", "the row is the provider's, so it names the provider")
        XCTAssertEqual(row?.name, "the real one", "with the provider's own title, not a short id")
        XCTAssertEqual(row?.door, .page(URL(string: "https://crobot.example/task/ui-task")!),
                       "and its door is the page, never a terminal onto a pane we do not own")
        XCTAssertNotEqual(row?.lamp, .unlit, "a finished cloud turn is green, not a dead husk")
    }

    /// The guard is narrow: a purely local session that a provider does NOT
    /// own is untouched, so this cannot swallow ordinary rows.
    func testALocalSessionAProviderDoesNotOwnIsUnaffected() {
        let verdict = GridAssembler.rows(inputs(
            waiting: [waiting(A)], live: [A: live(A)],
            remote: .init(agents: [AgentSession.of("elsewhere", provider: "crobot")])))
        XCTAssertTrue(verdict.rows.contains { $0.id == A }, "the local row is still drawn")
    }
}
