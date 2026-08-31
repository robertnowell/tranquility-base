import XCTest
@testable import TranquilityCore

/// The lamp/reason/name rules extracted to Core (App-lane P8, 24 Aug) —
/// previously untestable, living in the app layer with no unit coverage
/// (CLAUDE.md rule 7). Not exhaustive; pins the precedence order each
/// doc comment states, which is exactly the kind of rule that silently
/// inverts in a refactor without a test to catch it.
final class GridAssemblerTests: XCTestCase {

    private func live(pid: Int = 1, status: String = "idle",
                      waitingFor: String? = nil) -> LiveSession {
        LiveSession(pid: pid, sessionId: "s", cwd: "/tmp", status: status,
                   name: nil, waitingFor: waitingFor)
    }

    // MARK: - blockedOnYou

    func testBlockedOnYouFiresOnAKnownWaitingForValue() {
        let blocked = GridAssembler.blockedOnYou(
            live(status: "waiting", waitingFor: "permission prompt"), resumed: false)
        XCTAssertNotNil(blocked)
        XCTAssertEqual(blocked?.lamp, .fault)
    }

    func testBlockedOnYouIsNilForAnOrdinaryIdleSession() {
        XCTAssertNil(GridAssembler.blockedOnYou(live(status: "idle"), resumed: false))
    }

    // MARK: - lampAndReason precedence

    func testBlockedOutranksEverythingElse() {
        // Even a "working" process is blocked-first if it's reporting a
        // waiting-for value — the process is the plainest signal there is.
        let result = GridAssembler.lampAndReason(
            for: nil, sessionId: "s",
            live: live(status: "waiting", waitingFor: "permission prompt"))
        XCTAssertEqual(result.lamp, .fault)
    }

    func testWorkingFileWithIdleProcessReadsAsRunningNotWorking() {
        // "The process is right and it costs nothing to believe it."
        let evidence = SessionActivity.Evidence(activity: .working, observedAt: nil, modifiedAt: nil)
        let result = GridAssembler.lampAndReason(for: evidence, sessionId: "s",
                                                  live: live(status: "idle"))
        XCTAssertEqual(result.lamp, .running)
    }

    func testWorkingFileWithBusyProcessReadsAsWorking() {
        let evidence = SessionActivity.Evidence(activity: .working, observedAt: nil, modifiedAt: nil)
        let result = GridAssembler.lampAndReason(for: evidence, sessionId: "s",
                                                  live: live(status: "busy"))
        XCTAssertEqual(result.lamp, .working)
    }

    func testBlockedActivityIsAlwaysFaultRegardlessOfProcessStatus() {
        let evidence = SessionActivity.Evidence(
            activity: .blocked(reason: "usage limit"), observedAt: nil, modifiedAt: nil)
        let result = GridAssembler.lampAndReason(for: evidence, sessionId: "s",
                                                  live: live(status: "idle"))
        XCTAssertEqual(result.lamp, .fault)
    }

    func testStalledWithIdleProcessIsRunningNotFault() {
        // "In both of these cases, the agent did return" — a stall the file
        // infers from silence is overridden by the process actually being idle.
        let evidence = SessionActivity.Evidence(
            activity: .stalled(reason: "silent"), observedAt: nil, modifiedAt: nil)
        let result = GridAssembler.lampAndReason(for: evidence, sessionId: "s",
                                                  live: live(status: "idle"))
        XCTAssertEqual(result.lamp, .running)
    }

    func testStalledWithNoProcessAtAllStaysFault() {
        let evidence = SessionActivity.Evidence(
            activity: .stalled(reason: "silent"), observedAt: nil, modifiedAt: nil)
        let result = GridAssembler.lampAndReason(for: evidence, sessionId: "s", live: nil)
        XCTAssertEqual(result.lamp, .fault)
    }

    func testIdleFileWithBusyProcessIsWorkingNotQuiet() {
        let evidence = SessionActivity.Evidence(activity: .idle, observedAt: nil, modifiedAt: nil)
        let result = GridAssembler.lampAndReason(for: evidence, sessionId: "s",
                                                  live: live(status: "busy"))
        XCTAssertEqual(result.lamp, .working)
    }

    func testInFlightDeliveryUpgradesQuietToWorking() {
        let evidence = SessionActivity.Evidence(activity: .idle, observedAt: nil, modifiedAt: nil)
        let quiet = GridAssembler.lampAndReason(for: evidence, sessionId: "s",
                                                live: live(status: "idle"))
        XCTAssertEqual(quiet.lamp, .running, "sanity: quiet without a delivery in flight")
        let inFlight = GridAssembler.lampAndReason(for: evidence, sessionId: "s",
                                                    live: live(status: "idle"), isInFlight: true)
        XCTAssertEqual(inFlight.lamp, .working)
    }

    /// The property the whole delivery overlay rests on, and the reason the
    /// window may safely stay open past a successful dispatch (29 Aug): a
    /// delivery in flight is consulted ONLY over a lamp that was going out
    /// anyway. The moment the transcript or the process has anything to say,
    /// the observation wins — so the hand-off from "we sent it" to "the agent
    /// is working" needs no event, and a stale entry cannot paint over a real
    /// state.
    func testInFlightNeverOutranksALampThatHasSomethingToSay() {
        func lamp(_ activity: SessionActivity, _ status: String) -> Lamp {
            GridAssembler.lampAndReason(
                for: SessionActivity.Evidence(activity: activity, observedAt: nil,
                                              modifiedAt: nil),
                sessionId: "s", live: live(status: status), isInFlight: true).lamp
        }
        // The agent started talking: blue, but on the transcript's authority.
        XCTAssertEqual(lamp(SessionActivity.working, "busy"), Lamp.working)
        // The process says it is chewing and the file has not caught up.
        XCTAssertEqual(lamp(SessionActivity.idle, "busy"), Lamp.working)
        // A real error outranks it outright — the overlay must not hide amber.
        XCTAssertEqual(lamp(SessionActivity.blocked(reason: "usage limit"), "idle"), Lamp.fault)
    }

    func testPickedUpOnlyAppliesToARowThatWasGoingToBeQuiet() {
        let evidence = SessionActivity.Evidence(activity: .idle, observedAt: nil, modifiedAt: nil)
        let pickedUp = GridAssembler.lampAndReason(for: evidence, sessionId: "s",
                                                    live: live(status: "idle"), pickedUp: true)
        XCTAssertEqual(pickedUp.lamp, .fault)
        XCTAssertEqual(pickedUp.reason, "standing by")

        // A row with something of its own to say is never overridden by pickedUp.
        let working = SessionActivity.Evidence(activity: .working, observedAt: nil, modifiedAt: nil)
        let stillWorking = GridAssembler.lampAndReason(for: working, sessionId: "s",
                                                        live: live(status: "busy"), pickedUp: true)
        XCTAssertEqual(stillWorking.lamp, .working)
    }

    // MARK: - tabTitle / tabDisplayName

    func testTabTitleFallsBackToTheLiveSessionNameWithNoTranscript() {
        let session = LiveSession(pid: 1, sessionId: "s", cwd: "/tmp", status: "idle",
                                  name: "my-session", waitingFor: nil)
        XCTAssertEqual(GridAssembler.tabTitle(transcriptPath: nil, live: session), "my-session")
    }

    func testTabTitleIsNilWithNothingToGoOn() {
        XCTAssertNil(GridAssembler.tabTitle(transcriptPath: nil, live: nil))
    }
}

/// One name, whichever band builds the row.
///
/// A Codex session with a perfectly good name showed as "Projects" on 31 Aug,
/// twice, hours apart, with a fix in between. `tabTitle` reads a CLAUDE CODE
/// title out of `transcriptPath`, and for a Codex session that path is a
/// rollout with no such record, so it falls through to `live?.name` — which
/// only exists if the row came from the live map.
///
/// The first fix passed the harness's name in as a parameter and taught ONE
/// of the four bands that build a row. These cases cover all four, and the
/// parameter is gone: the lookup lives inside `tabDisplayName`, so there is
/// nothing left for a fifth band to forget.
final class HarnessNameOnEveryBandTests: XCTestCase {

    private static let known = ["01a05885": "Analyze Mirai's September calendar"]

    override func setUp() {
        super.setUp()
        GridAssembler.harnessNames = { Self.known }
    }

    override func tearDown() {
        GridAssembler.harnessNames = { CodexThreadNames.all() }
        super.tearDown()
    }

    private func event(_ id: String) -> WaitingSession {
        // `projectLabel` is derived from cwd, so "Projects" is what this row
        // falls back to, which is exactly the string that showed on the grid.
        var e = WaitingSession(sessionId: id, latestId: 1, createdAtMs: 0,
                               hookEvent: .stop)
        e.cwd = "/Users/x/Projects"
        e.transcriptPath = "/Users/x/.codex/sessions/rollout-\(id).jsonl"
        return e
    }

    private func live(_ id: String) -> LiveSession {
        LiveSession(harness: CodexAdapter().id, pid: 1, sessionId: id,
                    cwd: "/Users/x/Projects", status: "idle", name: nil,
                    waitingFor: nil)
    }

    // MARK: - the waiting band

    func testTheHarnessNameBeatsTheDirectory() {
        XCTAssertEqual(GridAssembler.tabDisplayName(for: event("01a05885"), live: nil),
                       "Analyze Mirai's September calendar")
    }

    /// Without one, the directory is still the honest last answer.
    func testNoHarnessNameFallsBackToTheProject() {
        XCTAssertEqual(GridAssembler.tabDisplayName(for: event("01a05003"), live: nil),
                       "Projects")
    }

    /// The harness's own name outranks a callsign, and that is the EXISTING
    /// precedence rather than a new one: `displayName` checks `liveName`
    /// first, and for Claude Code `liveName` is already the harness's own tab
    /// title. Codex's thread name is the same kind of thing, so it sits in the
    /// same slot. I wrote this test the other way round first and the code was
    /// right.
    func testTheHarnessNameOutranksACallsign() {
        var e = event("01a05885")
        e.callsign = "promotions copy"
        XCTAssertEqual(GridAssembler.tabDisplayName(for: e, live: nil),
                       "Analyze Mirai's September calendar")
    }

    /// And a callsign still beats the directory when there is no name at all.
    func testACallsignBeatsTheDirectory() {
        var e = event("01a05003")
        e.callsign = "promotions copy"
        XCTAssertEqual(GridAssembler.tabDisplayName(for: e, live: nil),
                       "promotions copy")
    }

    // MARK: - the stored band (a stored event WITH a live process)

    /// The band that was still showing "Projects" after the first fix: it
    /// reached the name only through `live.name`, so a live session whose
    /// name had not been injected fell all the way to the directory.
    func testAStoredRowWithALiveProcessIsNamed() {
        XCTAssertEqual(
            GridAssembler.tabDisplayName(for: event("01a05885"), live: live("01a05885")),
            "Analyze Mirai's September calendar")
    }

    // MARK: - the live-only band

    /// This one used to answer the literal string "session".
    func testALiveRowWithNoStoredEventIsNamed() {
        XCTAssertEqual(GridAssembler.tabDisplayName(live: live("01a05885"), callsign: nil),
                       "Analyze Mirai's September calendar")
    }

    func testALiveRowWithNoNameAnywhereSaysSession() {
        XCTAssertEqual(GridAssembler.tabDisplayName(live: live("01a05003"), callsign: nil),
                       "session")
    }

    // MARK: - the disk band

    func testADiskRowFallsBackToTheHarnessName() {
        XCTAssertEqual(
            GridAssembler.tabDisplayName(discovered: nil, sessionId: "01a05885",
                                         callsign: nil, cwd: "/Users/x/Projects"),
            "Analyze Mirai's September calendar")
    }

    /// Discovery's own title still wins when it has one — it is the same
    /// name, read by the route that band already had.
    func testADiskRowPrefersDiscoverysTitle() {
        XCTAssertEqual(
            GridAssembler.tabDisplayName(discovered: "Audit Kopi fixes", sessionId: "01a05885",
                                         callsign: nil, cwd: "/Users/x/Projects"),
            "Audit Kopi fixes")
    }

    func testADiskRowWithNothingFallsBackToTheDirectory() {
        XCTAssertEqual(
            GridAssembler.tabDisplayName(discovered: nil, sessionId: "01a05003",
                                         callsign: nil, cwd: "/Users/x/Projects"),
            "Projects")
    }
}
