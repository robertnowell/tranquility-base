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
