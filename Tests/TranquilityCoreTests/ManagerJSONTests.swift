import Foundation
import XCTest
@testable import TranquilityCore

/// The manager's read contract. A change in shape here is a change the Python
/// side must see, so the shape is pinned by test rather than by reading output.
final class ManagerJSONTests: XCTestCase {
    private var tmpDir: URL!
    private var store: QueueStore!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("manager-json-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = try QueueStore(url: tmpDir.appendingPathComponent("queue.sqlite"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func seed(session: String = "sess-1", goal: String? = "ship the outreach CRM") throws -> Int64 {
        let brief = SessionBrief(
            topic: "outreach CRM", goal: goal, happened: "Tests pass on the reducer.",
            nextStep: "merge", question: "merge?", rationale: "the reducer was the bug",
            findings: "reducer dropped the last row", solution: "guard the empty case",
            recap: "Reducer fixed, tests green.", proposal: "Merge it?")
        let rowid = try XCTUnwrap(store.insert(
            event: QueuedEvent(
                createdAtMs: Int64(Date().timeIntervalSince1970 * 1000), hookEvent: .stop,
                sessionId: session, promptId: UUID().uuidString, cwd: "/tmp/kopi-outreach",
                lastAssistantMessage: "Tests pass. Merge?", tty: "ttys001"),
            brief: brief, provider: "test"))
        return rowid
    }

    func testBriefCarriesTheLadderInOrderWithEmptiesSkipped() throws {
        _ = try seed()
        let brief = try XCTUnwrap(ManagerJSON.brief(store: store, sessionId: "sess-1"))
        XCTAssertEqual(brief.project, "kopi-outreach")
        XCTAssertEqual(brief.goal, "ship the outreach CRM")
        XCTAssertEqual(brief.why, "the reducer was the bug")
        XCTAssertEqual(brief.rungs.map(\.kind), ["goal", "findings", "solution", "why", "message"])
        XCTAssertFalse(brief.rungs.contains { $0.spoken.isEmpty })
    }

    func testBriefWithoutAGoalHasNoGoalRung() throws {
        _ = try seed(session: "sess-2", goal: nil)
        let brief = try XCTUnwrap(ManagerJSON.brief(store: store, sessionId: "sess-2"))
        XCTAssertNil(brief.goal)
        XCTAssertEqual(brief.rungs.first?.kind, "findings")
    }

    func testBriefIsNilForAnUnknownSession() throws {
        XCTAssertNil(try ManagerJSON.brief(store: store, sessionId: "nope"))
    }

    func testStatusListsWaitingSessionsWithGoal() throws {
        _ = try seed()
        let status = try ManagerJSON.status(store: store)
        XCTAssertEqual(status.waiting.count, 1)
        XCTAssertEqual(status.waiting.first?.goal, "ship the outreach CRM")
        XCTAssertEqual(status.unannounced, 1)
        XCTAssertFalse(status.waiting.first?.heard ?? true)
    }

    func testTargetsJoinGoalAndWaitingOntoLiveSessions() throws {
        _ = try seed()
        let live = LiveSession(pid: 4242, sessionId: "sess-1", cwd: "/tmp/kopi-outreach",
                               status: "waiting", name: "outreach", waitingFor: nil)
        let targets = ManagerJSON.targets(store: store, live: [live], isEnrolled: { _, _ in true })
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets.first?.project, "kopi-outreach")
        XCTAssertEqual(targets.first?.goal, "ship the outreach CRM")
        XCTAssertEqual(targets.first?.waiting, true)
        XCTAssertEqual(targets.first?.enrolled, true)
    }

    func testEncodingIsStableAndSorted() throws {
        let rung = ManagerJSON.Rung(kind: "goal", spoken: "ship it")
        XCTAssertEqual(ManagerJSON.encode(rung), #"{"kind":"goal","spoken":"ship it"}"#)
    }
}
