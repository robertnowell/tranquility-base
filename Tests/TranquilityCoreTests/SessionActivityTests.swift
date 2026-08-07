import XCTest
@testable import TranquilityCore

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

    // MARK: - Transient vs blocking errors
    //
    // 110 of the 286 errors in this machine's archive are the self-healing
    // kind. Lighting amber for those would teach the eye to ignore amber.

    private func apiErrorAt(_ text: String, agoSeconds: TimeInterval) -> String {
        let stamp = ISO8601DateFormatter.string(
            from: Date().addingTimeInterval(-agoSeconds),
            timeZone: TimeZone(identifier: "UTC")!,
            formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        return #"{"type":"assistant","isApiErrorMessage":true,"timestamp":"\#(stamp)","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    func testFreshTransientErrorDoesNotLightTheLamp() {
        // A 529 that Claude Code is already retrying. If the retry works the
        // tail moves on and this never lights at all.
        let tail = [userPrompt(), apiErrorAt("API Error: 529 Overloaded", agoSeconds: 3)]
        XCTAssertEqual(SessionActivity.classify(tail: tail, modified: warm), .idle)
    }

    func testTransientErrorThatSurvivesTheGraceEarnsAmber() {
        let tail = [userPrompt(),
                    apiErrorAt("API Error: 529 Overloaded",
                               agoSeconds: SessionActivity.transientGrace + 10)]
        guard case .blocked = SessionActivity.classify(tail: tail, modified: warm) else {
            return XCTFail("an error that outlives the grace is a real block")
        }
    }

    func testUsageLimitLightsImmediately() {
        // Needs a human on the first poll — there is nothing to wait for.
        let tail = [userPrompt(),
                    apiErrorAt("You've reached your Fable 5 limit. Run /usage-credits to continue.",
                               agoSeconds: 1)]
        guard case .blocked = SessionActivity.classify(tail: tail, modified: warm) else {
            return XCTFail("a usage limit must not be graced")
        }
    }

    func testSessionLimitIsNeverTransientEvenWhenPhrasedLikeOne() {
        // "try again" appears in transient copy; a session limit that also
        // says it must still count as blocking. Blocking words are checked
        // first for exactly this reason.
        XCTAssertFalse(SessionActivity.isTransient(
            "You've hit your session limit · resets 8pm. Try again later."))
        XCTAssertTrue(SessionActivity.isTransient("API Error: Unable to connect to API (ENOTFOUND)"))
        XCTAssertTrue(SessionActivity.isTransient(
            "API Error: Server is temporarily limiting requests (not your fault)"))
    }

    func testUnrecognisedErrorFailsTowardTellingYou() {
        // The closed list is deliberate: anything we do not recognise gets
        // the lamp, because failing toward "tell him" is the safe direction.
        XCTAssertFalse(SessionActivity.isTransient("API Error: something nobody has seen before"))
        let tail = [userPrompt(), apiErrorAt("API Error: something new", agoSeconds: 1)]
        guard case .blocked = SessionActivity.classify(tail: tail, modified: warm) else {
            return XCTFail("unknown errors light immediately")
        }
    }

    func testUndatedTransientErrorStillLights() {
        // No timestamp means no way to run the clock; the lamp wins.
        let tail = [userPrompt(), apiError("API Error: 529 Overloaded")]
        guard case .blocked = SessionActivity.classify(tail: tail, modified: warm) else {
            return XCTFail("without a timestamp the grace cannot apply")
        }
    }

    // MARK: - Turn boundaries (the hook cross-check)
    //
    // Measured before building: across 238 real turns the transcript alone
    // reads "idle" for 9.8% of the time an agent is working — 69 windows of
    // 15s or more, which is the grid's poll interval. These pin the precedence
    // that fixes it without letting a second source of truth start lying.

    private func boundary(_ kind: HookEventKind, agoSeconds: TimeInterval = 5)
        -> SessionActivity.TurnBoundary {
        .init(kind: kind, at: Date().addingTimeInterval(-agoSeconds))
    }

    func testMidTurnProseReadsWorkingWhenTheTurnIsStillOpen() {
        // THE case this feature exists for: the model wrote prose and will
        // call a tool next. The tail is indistinguishable from a finished
        // turn; the unanswered prompt boundary settles it.
        let tail = [userPrompt(), assistant(text: "Let me look at that.")]
        XCTAssertEqual(
            SessionActivity.classify(tail: tail, modified: warm,
                                     boundary: boundary(.userPromptSubmit)),
            .working)
    }

    func testFinishedTurnStaysIdleWhenTheStopIsTheNewerEdge() {
        let tail = [userPrompt(), assistant(text: "Done.")]
        XCTAssertEqual(
            SessionActivity.classify(tail: tail, modified: warm, boundary: boundary(.stop)),
            .idle)
    }

    func testNoBoundaryFallsBackToTheTranscriptAlone() {
        let tail = [userPrompt(), assistant(text: "Done.")]
        XCTAssertEqual(
            SessionActivity.classify(tail: tail, modified: warm, boundary: nil), .idle)
    }

    func testErrorBeatsAnOpenPrompt() {
        // The hooks are blind to errors — no Stop fires in 9 of 10 cases — so
        // an open prompt must never paint over a blocked session.
        let tail = [userPrompt(), apiError("You've reached your Fable 5 limit")]
        guard case .blocked = SessionActivity.classify(
            tail: tail, modified: warm, boundary: boundary(.userPromptSubmit))
        else { return XCTFail("a transcript error outranks any boundary") }
    }

    func testPositiveTranscriptObservationBeatsAStaleStop() {
        // A tool call in flight is something the hooks cannot see inside a
        // turn; a Stop from the previous turn must not silence it.
        let tail = [userPrompt(), assistantToolUse()]
        XCTAssertEqual(
            SessionActivity.classify(tail: tail, modified: warm, boundary: boundary(.stop)),
            .working)
    }

    func testAnOpenPromptOnAColdSessionDecaysToIdle() {
        // A session that crashed mid-turn leaves a prompt with no Stop
        // forever. Without this the lamp would sit blue for all time.
        let cold = Date().addingTimeInterval(-SessionActivity.freshness - 60)
        XCTAssertEqual(
            SessionActivity.classify(
                tail: [assistant(text: "Done.")], modified: cold,
                boundary: boundary(.userPromptSubmit, agoSeconds: SessionActivity.freshness + 60)),
            .idle)
    }

    func testALongTurnStaysWorkingOnTranscriptWarmthAlone() {
        // The boundary row is written at submit and never touched again, so a
        // turn running longer than the freshness window must keep its lamp
        // from the transcript's own mtime.
        let oldPrompt = SessionActivity.freshness + 600
        XCTAssertEqual(
            SessionActivity.classify(
                tail: [assistant(text: "Still going.")], modified: warm,
                boundary: boundary(.userPromptSubmit, agoSeconds: oldPrompt)),
            .working)
    }

    func testMissingFileIsNilNotAGuess() {
        XCTAssertNil(SessionActivity.read(transcriptPath: "/nope/does-not-exist.jsonl"))
    }
}
