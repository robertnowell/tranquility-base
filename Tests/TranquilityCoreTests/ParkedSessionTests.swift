import XCTest
@testable import TranquilityCore

/// A session sent to the background with the left arrow is still that
/// session. Fixtures are the real files read off this machine on 10 Sep at
/// 6:01 AM: `~/.claude/sessions/8805.json` (the session, parked) and
/// `39870.json` (the job standing where it was), plus the CLI row the job got.
final class ParkedSessionTests: XCTestCase {

    private let parentJSON = """
    {"pid":8805,"sessionId":"0d04e845-65ff-488f-983c-58f371d661ed",
     "cwd":"/Users/robertnowell/Projects/tranquility-base","startedAt":1788713739259,
     "version":"2.1.261","kind":"interactive","entrypoint":"cli",
     "tmux":"tb-79c13fdf:@0.%0","name":"tranquility-base-50","nameSource":"derived",
     "updatedAt":1789011276922,"status":"shell","parkedJobId":"54acd236"}
    """
    private let jobJSON = """
    {"pid":39870,"sessionId":"54acd236-0133-4866-bfee-905a9dc00e2c",
     "cwd":"/Users/robertnowell/Projects/tranquility-base","startedAt":1789011279271,
     "version":"2.1.267","kind":"bg","entrypoint":"cli",
     "name":"Hub design and organization","jobId":"54acd236","status":"shell",
     "updatedAt":1789011281331,"bridgeSessionId":"session_01Tps23qqdoujbZmSnnhC8bo"}
    """

    private var parent: SessionRegistry.Entry { SessionRegistry.decode(Data(parentJSON.utf8))! }
    private var job: SessionRegistry.Entry { SessionRegistry.decode(Data(jobJSON.utf8))! }

    private func jobRow() -> LiveSession {
        LiveSession(pid: 39870, sessionId: "54acd236-0133-4866-bfee-905a9dc00e2c",
                    cwd: "/Users/robertnowell/Projects/tranquility-base", status: "busy",
                    name: "Hub design and organization", waitingFor: nil,
                    kind: "background", startedAt: 1789011279271)
    }
    private func parentRow(status: String = "idle") -> LiveSession {
        LiveSession(pid: 8805, sessionId: "0d04e845-65ff-488f-983c-58f371d661ed",
                    cwd: "/Users/robertnowell/Projects/tranquility-base", status: status,
                    name: nil, waitingFor: nil, kind: "interactive", startedAt: 1788713739259)
    }
    private func other() -> LiveSession {
        LiveSession(pid: 1, sessionId: "aaaaaaaa-0000-0000-0000-000000000000",
                    cwd: nil, status: "idle", name: nil, waitingFor: nil,
                    kind: "interactive", startedAt: nil)
    }

    // MARK: - The registry file carries the link

    func testTheRegistryFileNamesTheParkedJobAndTheJobNamesItself() {
        XCTAssertEqual(parent.parkedJobId, "54acd236")
        XCTAssertEqual(parent.kind, "interactive")
        XCTAssertEqual(parent.paneId, "%0")
        XCTAssertEqual(job.jobId, "54acd236")
        XCTAssertEqual(job.kind, "bg")
        XCTAssertEqual(parent.startedAt, 1788713739259)
    }

    // MARK: - The incident

    /// The CLI listed the job and omitted the session. The session stands in,
    /// waiting at the agent view, with its own pid and id; the job is gone.
    func testTheParkedSessionStandsInForItsJob() {
        var traced: [String] = []
        let out = SessionRegistry.standingInForParkedJobs(
            [other(), jobRow()], entries: [parent, job], isAlive: { _ in true },
            trace: { traced.append($0) })
        XCTAssertEqual(out.map { String($0.sessionId.prefix(8)) }, ["aaaaaaaa", "0d04e845"])
        let standIn = out[1]
        XCTAssertEqual(standIn.pid, 8805)
        XCTAssertEqual(standIn.status, "waiting")
        XCTAssertEqual(standIn.waitingFor, Readiness.agentView)
        XCTAssertFalse(standIn.isBackground)
        XCTAssertEqual(standIn.startedAt, 1788713739259)
        XCTAssertEqual(traced.count, 1)
        XCTAssertTrue(traced[0].contains("standing in for job 54acd236"))
    }

    /// Tonight's second state: the job has already gone, the session is still
    /// parked and still hidden. It stands in all the same.
    func testAParkedSessionWhoseJobIsGoneStillStandsIn() {
        let out = SessionRegistry.standingInForParkedJobs(
            [other()], entries: [parent], isAlive: { _ in true })
        XCTAssertEqual(out.map { String($0.sessionId.prefix(8)) }, ["aaaaaaaa", "0d04e845"])
        XCTAssertEqual(out[1].waitingFor, Readiness.agentView)
    }

    // MARK: - The rule stops where the evidence stops

    /// The CLI lists both: the job is dropped, the session is left exactly as
    /// the CLI reported it, and nothing is duplicated.
    func testWhenTheCLIListsTheSessionOnlyTheJobIsDropped() {
        let out = SessionRegistry.standingInForParkedJobs(
            [parentRow(status: "busy"), jobRow()], entries: [parent, job],
            isAlive: { _ in true })
        XCTAssertEqual(out.map { String($0.sessionId.prefix(8)) }, ["0d04e845"])
        XCTAssertEqual(out[0].status, "busy")
        XCTAssertNil(out[0].waitingFor)
    }

    /// A parked session whose process has died is nobody's window. The job
    /// row is left as the CLI reported it.
    func testADeadParentChangesNothing() {
        let out = SessionRegistry.standingInForParkedJobs(
            [jobRow()], entries: [parent, job], isAlive: { $0 != 8805 })
        XCTAssertEqual(out.map { String($0.sessionId.prefix(8)) }, ["54acd236"])
        XCTAssertTrue(out[0].isBackground)
    }

    /// A background session nobody parked (a dispatched agent) is untouched.
    func testAJobWithNoParentIsUntouched() {
        let out = SessionRegistry.standingInForParkedJobs(
            [jobRow()], entries: [job], isAlive: { _ in true })
        XCTAssertEqual(out.map { String($0.sessionId.prefix(8)) }, ["54acd236"])
    }

    /// A job's registry file must never be mistaken for a parent: its kind is
    /// "bg" and it has no parkedJobId.
    func testAJobFileIsNeverAParent() {
        var bg = job
        bg.parkedJobId = "54acd236"
        let out = SessionRegistry.standingInForParkedJobs(
            [jobRow()], entries: [bg], isAlive: { _ in true })
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].isBackground)
    }

    // MARK: - What the row and the send path make of it

    func testTheAgentViewIsAmberAndRefusesTypedText() {
        let at = WaitingAt.read(status: "waiting", waitingFor: Readiness.agentView, resumed: false)
        XCTAssertEqual(at, .agentView)
        XCTAssertEqual(at?.short, "backgrounded in the agent view")
        XCTAssertFalse(at?.acceptsTypedReply ?? true)
        XCTAssertTrue(Readiness.waiting(Readiness.agentView).isDialog)
    }

    /// Same lamp the grid gives every other needs-you state: amber, with the
    /// reason in the column, so the tap is GO TO AGENT and lands on the tab.
    func testTheStandInLampIsAmberWithTheReason() {
        let standIn = SessionRegistry.standingInForParkedJobs(
            [], entries: [parent], isAlive: { _ in true })[0]
        let lamp = GridAssembler.lampAndReason(for: nil, sessionId: standIn.sessionId,
                                               live: standIn)
        XCTAssertEqual(lamp.lamp, .fault)
        XCTAssertEqual(lamp.reason, "backgrounded in the agent view")
        let row = SessionRow(id: standIn.sessionId, name: "Hub design and organization",
                             aux: lamp.reason ?? "", lamp: lamp.lamp)
        XCTAssertEqual(SessionRow.action(for: row), .goToAgent)
    }
}
