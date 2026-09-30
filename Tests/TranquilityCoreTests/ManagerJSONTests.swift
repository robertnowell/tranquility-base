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
        let status = try ManagerJSON.status(store: store, live: ["sess-1"])
        XCTAssertEqual(status.waiting.count, 1)
        XCTAssertEqual(status.waiting.first?.goal, "ship the outreach CRM")
        XCTAssertEqual(status.unannounced, 1)
        XCTAssertFalse(status.waiting.first?.heard ?? true)
    }

    /// The 28 Sep fault, in one assertion: the store keeps a waiting row long
    /// after its session has gone, and this door used to ship every one of
    /// them. 186 of 200 rows were history, the answer came to 29,160 bytes,
    /// and the data channel refuses anything over 16,384 -- so the manager
    /// received nothing and said nobody was waiting while the grid showed a
    /// column of green.
    func testAWaitingRowWhoseSessionIsGoneIsNotShipped() throws {
        _ = try seed()
        let status = try ManagerJSON.status(store: store, live: [])
        XCTAssertTrue(status.waiting.isEmpty,
                      "a row nobody can speak to is history, not a queue")
        XCTAssertEqual(status.unannounced, 0,
                       "and it must not be counted as something owed to the user")
    }

    /// The count and the rows have to agree. `unannounced` was read off the
    /// unfiltered list once and would have gone on reporting 179 things owed
    /// against a queue of 14.
    func testTheUnannouncedCountCountsOnlyWhatIsShipped() throws {
        _ = try seed()
        let live = try ManagerJSON.status(store: store, live: ["sess-1"])
        let dead = try ManagerJSON.status(store: store, live: ["someone-else"])
        XCTAssertEqual(live.unannounced, live.waiting.filter { !$0.heard }.count)
        XCTAssertEqual(dead.unannounced, 0)
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
        XCTAssertFalse(targets.first?.name?.isEmpty ?? true)
    }

    /// `tbase targets` lists in the panel's folder order and names the folder
    /// (ruling-project-folders, rules 1 and 3): the user's order, sticky.
    func testTargetsListFoldersFirstInTheUsersOrder() throws {
        _ = try seed(session: "asks")
        let live = ["loose", "quiet", "asks"].map {
            LiveSession(pid: 1, sessionId: $0, cwd: "/tmp/\($0)", status: "busy")
        }
        var book = ProjectBook()
        book.create(name: "Quiet", with: ["quiet"], id: "q")
        book.create(name: "Asking", with: ["asks"], id: "a")
        let targets = ManagerJSON.targets(store: store, live: live, isEnrolled: { _, _ in true },
                                          book: book, origin: { $0 })
        XCTAssertEqual(targets.map(\.sessionId), ["quiet", "asks", "loose"])
        XCTAssertEqual(targets.map(\.folder), ["Quiet", "Asking", nil])
    }

    /// `tbase status` lists waiting rows in the panel's order and says where
    /// each sits, for the hands-free manager (GridOrder, ruled 29 Sep 2026).
    func testStatusCarriesTheGridOrder() throws {
        _ = try seed(session: "a")
        _ = try seed(session: "b")
        let status = try ManagerJSON.status(store: store, live: ["a", "b"], gridOrder: ["b", "a"])
        XCTAssertEqual(status.waiting.map(\.sessionId), ["b", "a"])
        XCTAssertEqual(status.waiting.map(\.gridIndex), [0, 1])
        let none = try ManagerJSON.status(store: store, live: ["a", "b"], gridOrder: [])
        XCTAssertEqual(none.waiting.map(\.gridIndex), [nil, nil])
    }

    func testEncodingIsStableAndSorted() throws {
        let rung = ManagerJSON.Rung(kind: "goal", spoken: "ship it")
        XCTAssertEqual(ManagerJSON.encode(rung), #"{"kind":"goal","spoken":"ship it"}"#)
    }

    func testRungByKindReadsTheStoredLadder() throws {
        _ = try seed()
        let rung = try XCTUnwrap(ManagerJSON.rung(store: store, sessionId: "sess-1", kind: "solution"))
        XCTAssertEqual(rung.kind, .solution)
        XCTAssertTrue(rung.spoken.text.contains("guard the empty case"))
        XCTAssertNil(try ManagerJSON.rung(store: store, sessionId: "sess-1", kind: "nope"))
    }
}
