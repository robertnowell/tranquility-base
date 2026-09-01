import XCTest
@testable import TranquilityCore

/// What a Codex turn says about itself, read from its own rollout.
///
/// Robert, 01 Sep, with the pane beside the panel: a session whose turn died
/// overnight with `stream disconnected before completion` was still showing
/// blue — "it has shown Working since last night so it's basically never
/// updating to Amber which is the correct statement".
///
/// It could not. A rollout is JSONL of `event_msg`/`response_item`, and this
/// classifier only spoke Claude Code's vocabulary, so every line fell through
/// and the verdict came from the hook boundary alone — which is exactly what a
/// turn that dies cannot update, because no Stop fires. The precedence note on
/// `verdict` had already ruled this case, in the words it was written for the
/// other harness with: "a transcript error wins outright. The hooks are
/// measurably blind to it."
///
/// The lines below are copied from
/// `rollout-2026-08-31T15-05-10-01a059da-…jsonl`, trimmed but not reshaped.
final class CodexTurnErrorTests: XCTestCase {

    private let died = """
    {"timestamp":"2026-09-01T01:51:18.919Z","type":"event_msg","payload":{"type":"task_complete",\
    "turn_id":"01a05a61","last_agent_message":null,"error":{"message":"stream disconnected before \
    completion: error sending request for url (https://api.openai.com/v1/responses)",\
    "codex_error_info":"other"},"started_at":1788222712,"completed_at":1788227478}}
    """

    private let finished = """
    {"timestamp":"2026-09-01T01:51:18.919Z","type":"event_msg","payload":{"type":"task_complete",\
    "turn_id":"01a05a61","last_agent_message":"Done."}}
    """

    private let started = """
    {"timestamp":"2026-09-01T01:51:18.919Z","type":"event_msg","payload":{"type":"task_started"}}
    """

    private let wrote = """
    {"timestamp":"2026-09-01T01:51:18.919Z","type":"response_item","payload":{"type":"message"}}
    """

    private var errorAt: Date { ISO8601DateFormatter().date(from: "2026-09-01T01:51:18Z")! }

    /// The turn died, and a prompt that was submitted BEFORE it died must not
    /// keep the lamp blue. This is the whole photograph.
    func testADeadTurnIsBlockedEvenWithAPromptStillOpen() {
        let boundary = SessionActivity.TurnBoundary(
            kind: .userPromptSubmit, at: errorAt.addingTimeInterval(-4766))
        let verdict = SessionActivity.classify(
            tail: [died], modified: errorAt, boundary: boundary,
            now: errorAt.addingTimeInterval(14 * 3600))
        guard case .blocked(let reason) = verdict else {
            return XCTFail("expected blocked, got \(verdict)")
        }
        XCTAssertTrue(reason.hasPrefix("stream disconnected before completion"))
    }

    /// And it says so in words a one-line row can hold. Splitting on a bare
    /// "." cut this at the dot in `api.openai.com`.
    func testTheRowGetsAReadableClause() {
        guard case .blocked = SessionActivity.classify(tail: [died], modified: errorAt,
                                                       now: errorAt) else {
            return XCTFail("expected blocked")
        }
        let activity = SessionActivity.blocked(
            reason: "stream disconnected before completion: error sending request for url "
                + "(https://api.openai.com/v1/responses)")
        XCTAssertEqual(activity.shortReason, "stream disconnected before completion")
        // The whole sentence survives for the hover.
        XCTAssertTrue(activity.fullReason?.contains("api.openai.com") == true)
    }

    /// A short error keeps every word it has — the clause cut is for the ones
    /// that would be truncated anyway.
    func testAShortErrorIsNotCutAtItsColon() {
        let activity = SessionActivity.blocked(reason: "API Error: 429 rate limit exceeded")
        XCTAssertEqual(activity.shortReason, "429 rate limit exceeded")
    }

    /// A turn that ended CLEANLY is over too, and no missing Stop hook can
    /// make it look otherwise.
    func testACleanCompletionEndsTheTurn() {
        let boundary = SessionActivity.TurnBoundary(
            kind: .userPromptSubmit, at: errorAt.addingTimeInterval(-4766))
        XCTAssertEqual(
            SessionActivity.classify(tail: [finished], modified: errorAt, boundary: boundary,
                                     now: errorAt.addingTimeInterval(600)),
            .idle)
    }

    /// A prompt submitted AFTER the turn ended is a new turn whose first line
    /// may not be on disk yet — the exception `turnIsOver` already grants
    /// Claude Code, granted here by the same rule rather than a second one.
    func testAPromptNewerThanTheCompletionStillCounts() {
        let boundary = SessionActivity.TurnBoundary(
            kind: .userPromptSubmit, at: errorAt.addingTimeInterval(60))
        XCTAssertNotEqual(
            SessionActivity.classify(tail: [finished], modified: errorAt, boundary: boundary,
                                     now: errorAt.addingTimeInterval(120)),
            .idle)
    }

    /// A turn in flight is working, said by the harness rather than inferred.
    func testAStartedTurnIsWorking() {
        XCTAssertEqual(
            SessionActivity.classify(tail: [started], modified: errorAt,
                                     now: errorAt.addingTimeInterval(30)),
            .working)
    }

    /// And it stops being working when it goes quiet, by the same clock as
    /// everything else.
    func testAStartedTurnThatGoesSilentStalls() {
        guard case .stalled = SessionActivity.classify(
            tail: [started], modified: errorAt,
            now: errorAt.addingTimeInterval(SessionActivity.stalled + 60)) else {
            return XCTFail("expected stalled")
        }
    }

    /// Model and tool output counts as movement, the way assistant/user
    /// entries do for Claude Code.
    func testWrittenOutputIsMovement() {
        XCTAssertEqual(
            SessionActivity.classify(tail: [wrote], modified: errorAt,
                                     now: errorAt.addingTimeInterval(5)),
            .working)
    }

    /// The newest word wins: an error followed by a fresh start is a retry.
    func testAStartAfterTheErrorWins() {
        XCTAssertEqual(
            SessionActivity.classify(tail: [died, started], modified: errorAt,
                                     now: errorAt.addingTimeInterval(5)),
            .working)
    }
}
