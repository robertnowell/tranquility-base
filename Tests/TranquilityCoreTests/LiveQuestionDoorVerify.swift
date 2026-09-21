import XCTest
@testable import TranquilityCore

/// The question-door path against a real pane stopped on a real dialog,
/// opt-in via `TB_LIVE_QUESTION=<session id>`, skipped in every ordinary
/// `swift test` run.
///
/// The unit tests pin the captured screen; this asks the shipped code the
/// same questions the revive door asks, against whatever pane currently
/// holds that session id: the guard finds the holder, the holder resolves
/// to a pane, the pane's screen is recognised as a named question, and the
/// ledger answers `unregisteredButAlive` with the same pid. Written 21 Sep
/// against pid 31293 on "Allow external CLAUDE.md file imports?".
final class LiveQuestionDoorVerify: XCTestCase {
    func testAStuckPaneIsAHolderWithAPaneAndANamedQuestion() throws {
        let sessionId = ProcessInfo.processInfo.environment["TB_LIVE_QUESTION"] ?? ""
        try XCTSkipUnless(sessionId.count >= 8, "live probe; set TB_LIVE_QUESTION=<session id>")
        let verdict = ResumeGuard.check(sessionId: sessionId)
        let holders = verdict.holders
        XCTAssertFalse(holders.isEmpty, "no live process holds \(sessionId.prefix(8))")
        guard let pane = ResumeGuard.routablePane(among: holders) else {
            return XCTFail("holders \(holders.map(\.pid)) resolve to no pane")
        }
        print("PANE: \(pane.sessionName) \(pane.paneId) \(pane.paneTty) socket=\(pane.socketName ?? "default")")
        let asked = SessionLauncher.paneQuestion(pane: pane, adapter: ClaudeCodeAdapter())
        print("SAYS: \(asked.says ?? "(unrecognised)")")
        print("TAIL: \(asked.tail)")
        XCTAssertNotNil(asked.says, "the shipped adapter does not recognise this screen")
        let live = FileSessionOwnershipStore.shared.unregisteredButAlive(sessionId: sessionId)
        print("LEDGER: \(live.map { "pid \($0.pid) cwd \($0.cwd ?? "?")" } ?? "nil")")
        XCTAssertEqual(live?.pid, holders.first?.pid,
                       "the door's liveness answer must be the guard's holder")
    }
}
