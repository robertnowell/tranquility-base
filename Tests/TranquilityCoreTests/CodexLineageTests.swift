import XCTest
@testable import TranquilityCore

/// A fork is the same conversation; a sub-agent is not.
final class CodexLineageTests: XCTestCase {
    private let parent = "01a07eba-fa51-79a2-ade7-d416cb916dd0"
    private let child = "01a09b8d-c39b-7111-815c-6a09d382b46a"

    func testAForkLinksToWhatItForkedFrom() {
        let link = CodexLineage.link(CodexRollout.SessionMeta(
            sessionId: child, threadSource: "user", forkedFromId: parent))
        XCTAssertEqual(link?.child, child)
        XCTAssertEqual(link?.parent, parent)
    }

    /// The field a fork uses is the field a sub-agent uses. Eleven sub-agents
    /// folded into their parent's hub would bury the conversation they were
    /// spawned to help with.
    func testASubagentIsNotTheSameConversation() {
        XCTAssertNil(CodexLineage.link(CodexRollout.SessionMeta(
            sessionId: "01a09b8e-9cdd-7d80-9788-0a4c6beb2f7c",
            threadSource: "subagent", forkedFromId: parent)))
    }

    func testAThreadNobodyForkedIsAFamilyOfOne() {
        XCTAssertNil(CodexLineage.link(CodexRollout.SessionMeta(
            sessionId: parent, threadSource: "user")))
    }

    /// A rollout that forked from itself is not a link; `origin` would spin.
    func testASelfForkIsRefused() {
        XCTAssertNil(CodexLineage.link(CodexRollout.SessionMeta(
            sessionId: child, threadSource: "user", forkedFromId: child)))
    }

    /// Older rollouts predate `thread_source` entirely, and a missing field
    /// is not a claim to be a sub-agent.
    func testAnOlderRolloutWithoutThreadSourceStillLinks() {
        XCTAssertEqual(CodexLineage.link(CodexRollout.SessionMeta(
            sessionId: child, forkedFromId: parent))?.parent, parent)
    }

    /// The whole point: history and pages from before the edit stay with the
    /// conversation, because every hub surface walks the family.
    func testTheFamilyReachesBackPastTheEdit() {
        let map: SessionLineage.Map = [child: parent]
        XCTAssertEqual(SessionLineage.origin(of: child, in: map), parent)
        XCTAssertEqual(SessionLineage.family(of: child, in: map), [parent, child])
    }

    /// Editing twice forks twice.
    func testForkOfAForkIsOneFamily() {
        let middle = "01a09b8e-2222-7000-8000-bbbbbbbbbbbb"
        let map: SessionLineage.Map = [child: middle, middle: parent]
        XCTAssertEqual(SessionLineage.family(of: child, in: map), [parent, middle, child])
    }

    /// Reading the real archive must answer without a fixture, and must find
    /// the fork this bug was reported from if it is still on disk.
    func testRealArchiveScanIsReadable() {
        let map = CodexLineage.scan()
        if FileManager.default.fileExists(atPath: CodexRollout.sessionsDirectory.path),
           CodexRollout.meta(sessionId: child) != nil {
            XCTAssertEqual(map[child], parent)
        }
    }
}
