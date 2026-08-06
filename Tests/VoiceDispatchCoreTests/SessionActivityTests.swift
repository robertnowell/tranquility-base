import XCTest
@testable import VoiceDispatchCore

/// The lamp's evidence. Every rule here was derived from real entries in this
/// machine's transcript archive (286 error entries, measured 06 Aug), so the
/// fixtures are shaped like the real thing — including the bookkeeping lines
/// Claude Code writes AFTER an error, which is what makes "read the last line"
/// the wrong rule.
final class SessionActivityTests: XCTestCase {

    private func assistant(text: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
    }
    private func assistantToolUse() -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash"}]}}"#
    }
    private func userPrompt() -> String {
        #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"do the thing"}]}}"#
    }
    private func apiError(_ text: String) -> String {
        #"{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
    }
    private let systemLine = #"{"type":"system","content":"ai-title"}"#
    private var warm: Date { Date() }

    func testFinishedTurnIsIdle() {
        let tail = [userPrompt(), assistantToolUse(), assistant(text: "Done.")]
        XCTAssertEqual(SessionActivity.classify(tail: tail, modified: warm), .idle)
    }

    func testTurnEndingInAToolCallIsWorking() {
        let tail = [userPrompt(), assistant(text: "Let me check."), assistantToolUse()]
        XCTAssertEqual(SessionActivity.classify(tail: tail, modified: warm), .working)
    }

    func testUnansweredPromptIsWorking() {
        // The agent owes a reply — this is the state that had no lamp before.
        let tail = [assistant(text: "Done."), userPrompt()]
        XCTAssertEqual(SessionActivity.classify(tail: tail, modified: warm), .working)
    }

    func testErrorIsBlockedEvenWithBookkeepingAfterIt() {
        // The exact shape that made "read the last line" wrong: Claude Code
        // writes system entries after the failure.
        let tail = [userPrompt(),
                    apiError("You've reached your Fable 5 limit. Run /usage-credits to continue."),
                    systemLine, systemLine]
        guard case .blocked(let reason) = SessionActivity.classify(tail: tail, modified: warm) else {
            return XCTFail("expected blocked")
        }
        XCTAssertTrue(reason.contains("Fable 5 limit"))
    }

    func testBlockedShortReasonFitsARow() {
        let activity = SessionActivity.blocked(
            reason: "You've hit your session limit · resets 8pm (America/Los_Angeles). Try later.")
        XCTAssertEqual(activity.shortReason, "hit your session limit · resets 8pm (America/Los_Angeles)")
    }

    func testUserReplyAfterAnErrorClearsTheBlock() {
        // Answering the error means the human is already handling it; the lamp
        // must go back to working rather than staying amber forever.
        let tail = [apiError("You've hit your session limit"), userPrompt()]
        XCTAssertEqual(SessionActivity.classify(tail: tail, modified: warm), .working)
    }

    func testStaleWorkingDecaysToIdle() {
        // A tool call that hung yesterday is not "working" — a lamp stuck on
        // blue for a dead session is worse than no lamp.
        let old = Date().addingTimeInterval(-SessionActivity.freshness - 60)
        XCTAssertEqual(SessionActivity.classify(tail: [assistantToolUse()], modified: old), .idle)
        XCTAssertEqual(SessionActivity.classify(tail: [assistantToolUse()], modified: nil), .idle)
    }

    func testBlockedDoesNotDecay() {
        // A session blocked an hour ago is still blocked: nothing has moved.
        let old = Date().addingTimeInterval(-SessionActivity.freshness - 60)
        guard case .blocked = SessionActivity.classify(tail: [apiError("limit")], modified: old) else {
            return XCTFail("blocked must survive the freshness gate")
        }
    }

    func testGarbageAndBookkeepingOnlyIsIdle() {
        XCTAssertEqual(SessionActivity.classify(tail: [], modified: warm), .idle)
        XCTAssertEqual(SessionActivity.classify(tail: ["{not json", systemLine], modified: warm), .idle)
    }

    func testTailReadsOnlyTheEndOfAHugeFile() throws {
        // The perf floor: these files reach hundreds of MB, so the reader must
        // never depend on total size. Also proves the partial first line of the
        // window is dropped rather than parsed as a record.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let filler = String(repeating: systemLine + "\n", count: 4000)  // > 64KB
        try (filler + assistantToolUse() + "\n").write(to: url, atomically: true, encoding: .utf8)

        let lines = try XCTUnwrap(SessionActivity.tail(of: url.path))
        XCTAssertLessThan(lines.count, 4000, "must not read the whole file")
        XCTAssertEqual(SessionActivity.read(transcriptPath: url.path), .working)
        for line in lines {
            XCTAssertTrue(line.hasPrefix("{"), "a partial record leaked into the window")
        }
    }

    func testMissingFileIsNilNotAGuess() {
        XCTAssertNil(SessionActivity.read(transcriptPath: "/nope/does-not-exist.jsonl"))
    }
}
