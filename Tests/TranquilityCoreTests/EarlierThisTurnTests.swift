import XCTest
@testable import TranquilityCore

/// The turn, not the last line. One rule for every adapter, and the seams
/// each adapter already has for the blocks it feeds in.
final class EarlierThisTurnTests: XCTestCase {

    func testTheFinalBlockIsDroppedAndTheRestJoinedOldestFirst() {
        XCTAssertEqual(EarlierThisTurn.earlier(blocks: ["Still running, 11 minutes in.", "Writing the report now.", "Watching quietly for the finish."]),
                       "Still running, 11 minutes in.\n\nWriting the report now.")
        XCTAssertNil(EarlierThisTurn.earlier(blocks: ["Only one thing said."]), "a one-message turn has nothing earlier")
        XCTAssertNil(EarlierThisTurn.earlier(blocks: []))
        XCTAssertNil(EarlierThisTurn.earlier(blocks: ["  ", "\n", "final"]), "blank blocks are not messages")
    }

    func testALongTurnKeepsItsOpeningAndItsEndUnderTheCap() {
        let text = String(repeating: "a", count: 4_000) + String(repeating: "b", count: 4_000)
        let capped = EarlierThisTurn.capped(text)
        XCTAssertLessThanOrEqual(capped.count, EarlierThisTurn.cap, "the contract's maxLength holds including the marker")
        XCTAssertTrue(capped.hasPrefix(String(repeating: "a", count: 1_500)))
        XCTAssertTrue(capped.hasSuffix(String(repeating: "b", count: 4_000)))
        XCTAssertTrue(capped.contains("characters omitted"))
        XCTAssertEqual(EarlierThisTurn.capped("short"), "short")
    }

    // MARK: - The seams

    /// Claude Code: the turn reader the hub already uses yields the blocks;
    /// a tool result is `type:"user"` too and must not end the turn.
    func testClaudeCodeBlocksComeFromTheTurnReader() {
        let jsonl = [
            #"{"type":"user","message":{"content":"earlier prompt"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"old turn"}]}}"#,
            #"{"type":"user","message":{"content":"watch the run"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Still running, 11 minutes in."}]}}"#,
            #"{"type":"user","toolUseResult":{"ok":1},"message":{"content":[{"type":"tool_result","content":"poll output"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"secret"}}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Writing the report now."}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Watching quietly for the finish."}]}}"#,
        ].joined(separator: "\n")
        let turn = TurnText.claudeCode(jsonl: jsonl, limit: 1).last!
        XCTAssertEqual(turn.blocks, ["Still running, 11 minutes in.", "Writing the report now.", "Watching quietly for the finish."])
        let earlier = EarlierThisTurn.earlier(blocks: turn.blocks)!
        XCTAssertEqual(earlier, "Still running, 11 minutes in.\n\nWriting the report now.")
        XCTAssertFalse(earlier.contains("poll output")); XCTAssertFalse(earlier.contains("secret")); XCTAssertFalse(earlier.contains("hmm"))
        XCTAssertFalse(earlier.contains("old turn"), "only since the person's last message")
    }

    /// Codex: the rollout parser's message list, same rule.
    func testCodexBlocksComeFromTheRolloutMessages() {
        let messages = [
            CodexRollout.Message(role: "user", text: "audit delivery"),
            CodexRollout.Message(role: "assistant", text: "Checking the workflow runs."),
            CodexRollout.Message(role: "assistant", text: "Two runs in progress, one report written."),
            CodexRollout.Message(role: "assistant", text: "https://hq.tranquilitybase.dev/open?session=x&slug=fast-delivery-audit"),
        ]
        let turn = TurnText.codex(messages: messages, limit: 1).last!
        XCTAssertEqual(EarlierThisTurn.earlier(blocks: turn.blocks),
                       "Checking the workflow runs.\n\nTwo runs in progress, one report written.")
    }

    /// A polled provider: the transcript is a role/text list; the poller
    /// slices since the last user turn and the spool line carries the result.
    func testAPolledTurnCarriesItsEarlierWordsOnTheSpoolLine() {
        let at = Date()
        var last = Turn(id: "t3", at: at, role: .agent, text: "Done; PR opened.")
        last.earlier = EarlierThisTurn.earlier(blocks: ["Reading the repo.", "Found the bug.", "Done; PR opened."])
        let event = AgentEvent(provider: "crobot", session: "s", at: at, kind: .said(last))
        let lines = RemoteSpool.lines(for: event, agent: nil)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].lastAssistantMessage, "Done; PR opened.")
        XCTAssertEqual(lines[0].earlierThisTurn, "Reading the repo.\n\nFound the bug.")
        XCTAssertEqual(lines[0].json()["earlierThisTurn"] as? String, "Reading the repo.\n\nFound the bug.")
    }

    // MARK: - Readers that had to widen

    func testANumberStatedEarlierInTheTurnIsGrounded() {
        let r = SummaryRequest(lastAssistantMessage: "Watching quietly.", projectLabel: "Probot",
                               earlierThisTurn: "It has read 8 million tokens, cost about $1.34.")
        let pool = DigitGrounding.sourcePool(for: r)
        XCTAssertTrue(pool.contains("8")); XCTAssertTrue(pool.contains("1.34"))
    }

    func testTheContractInputCarriesTheField() throws {
        let r = SummaryRequest(lastAssistantMessage: "final", projectLabel: "P", earlierThisTurn: "before")
        let data = try GatewayContract.encode(GatewaySummaryInput(r))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["earlierThisTurn"] as? String, "before")
        let none = try GatewayContract.encode(GatewaySummaryInput(SummaryRequest(lastAssistantMessage: "final", projectLabel: "P")))
        XCTAssertFalse(String(data: none, encoding: .utf8)!.contains("earlierThisTurn"), "absent, never null: the schema has no nulls")
    }
}
