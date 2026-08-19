import XCTest
@testable import TranquilityCore

/// The 19 Aug ruling, drilled: a restarted agent is on the grid, not in Past
/// Agents. Fixtures are the real clocks off this machine at 22:32 — session
/// `04d50469`, killed between a tool call and its result and resumed seven
/// minutes later, is the row Robert was pointing at.
final class AgentRestartTests: XCTestCase {

    private let lastWord = Date(timeIntervalSince1970: 1_787_178_322)   // 22:25:22
    private let restart = Date(timeIntervalSince1970: 1_787_178_742.354) // 22:32:22

    // MARK: - The membership fact

    func testAProcessNewerThanTheConversationWasResumed() {
        XCTAssertTrue(AgentRestart.resumed(startedAt: restart, lastWord: lastWord))
    }

    func testALiveProcessThatWroteTheLastWordWasNot() {
        // The ordinary case, and the one this must never touch: an agent that
        // has been running since before it spoke is simply working.
        XCTAssertFalse(AgentRestart.resumed(startedAt: lastWord.addingTimeInterval(-600),
                                            lastWord: lastWord))
    }

    func testNoProcessClockMeansNoRule() {
        // A CLI that stops reporting `startedAt` costs this rule and nothing
        // else: the row falls back to exactly the lamp it had before.
        XCTAssertFalse(AgentRestart.resumed(startedAt: nil, lastWord: lastWord))
    }

    func testAnUnreadableTranscriptIsNotEvidenceOfARestart() {
        // Absence of a last word is absence of evidence, and an unreadable file
        // has never been allowed to light a lamp here.
        XCTAssertFalse(AgentRestart.resumed(startedAt: restart, lastWord: nil))
    }

    func testTypingIntoTheRestartedSessionRetiresTheRule() {
        // The moment the conversation is newer than the process, this is over —
        // no timer, no clearing gesture, no state to get stuck.
        XCTAssertFalse(AgentRestart.resumed(startedAt: restart,
                                            lastWord: restart.addingTimeInterval(30)))
    }

    func testTheHookCountsAsAWordBeforeTheFileHasIt() {
        // Race #118: a prompt is submitted before its line reaches disk. For
        // that second the file's newest entry is still the pre-restart one, and
        // the boundary is the only witness that the user has spoken.
        let boundary = SessionActivity.TurnBoundary(kind: .userPromptSubmit,
                                                    at: restart.addingTimeInterval(5))
        let word = AgentRestart.lastWord(observedAt: lastWord, boundary: boundary)
        XCTAssertEqual(word, boundary.at)
        XCTAssertFalse(AgentRestart.resumed(startedAt: restart, lastWord: word))
    }

    func testAnOldBoundaryDoesNotSpeakForTheNewProcess() {
        let boundary = SessionActivity.TurnBoundary(kind: .userPromptSubmit,
                                                    at: lastWord.addingTimeInterval(-60))
        let word = AgentRestart.lastWord(observedAt: lastWord, boundary: boundary)
        XCTAssertEqual(word, lastWord)
        XCTAssertTrue(AgentRestart.resumed(startedAt: restart, lastWord: word))
    }

    // MARK: - The words, which follow the state

    func testAnInterruptedTurnSaysSo() {
        // `04d50469`: killed on a tool result. Its work is stranded, and that
        // is different news from a conversation somebody reopened.
        XCTAssertEqual(AgentRestart.reason(for: .working)?.short, "restarted mid-turn")
        XCTAssertEqual(AgentRestart.reason(for: .stalled(reason: "silent for 2h"))?.short,
                       "restarted mid-turn")
    }

    func testAReopenedConversationSaysThatInstead() {
        // Ruled 19 Aug, widening the first cut: resurrecting an agent puts it
        // on the grid whatever the old turn was doing. Nothing is stranded
        // here, so the row says what is true — it is standing by for you.
        XCTAssertEqual(AgentRestart.reason(for: .idle)?.short, "restarted, waiting on you")
        XCTAssertEqual(AgentRestart.reason(for: nil)?.short, "restarted, waiting on you")
    }

    func testAnErrorKeepsItsOwnWords() {
        // Already amber, already on the grid, and the error it names tells the
        // reader more than the restart would.
        XCTAssertNil(AgentRestart.reason(for: .blocked(reason: "usage limit")))
    }

    func testTheTwoRestartsDoNotReadAlike() {
        XCTAssertNotEqual(AgentRestart.reason(for: .working)?.short,
                          AgentRestart.reason(for: .idle)?.short)
    }

    // MARK: - The field it all rests on

    /// The CLI's own field, decoded the way `claude agents --json` writes it.
    func testStartedAtDecodesFromTheAgentsPayload() throws {
        let json = """
            [{"pid":36980,"sessionId":"04d50469","cwd":"/Users/robertnowell/Projects",
              "kind":"interactive","startedAt":1787178742354,"name":"projects-19",
              "status":"idle"}]
            """.data(using: .utf8)!
        let sessions = try JSONDecoder().decode([LiveSession].self, from: json)
        XCTAssertEqual(sessions.first?.startedAtDate, restart)
    }

    /// And a payload without the field still decodes — the whole grid must not
    /// depend on one optional key.
    func testAPayloadWithoutStartedAtStillDecodes() throws {
        let json = #"[{"pid":1,"sessionId":"x","status":"idle"}]"#.data(using: .utf8)!
        let sessions = try JSONDecoder().decode([LiveSession].self, from: json)
        XCTAssertNil(sessions.first?.startedAtDate)
    }
}
