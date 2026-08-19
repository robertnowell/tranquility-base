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

    func testALongSilenceAsksForAHumanRatherThanGoingOut() {
        // RE-RULED 18 Aug. This used to assert the opposite — that a tool call
        // hung yesterday decays to idle — and that decay is what hid a live
        // session blocked on Robert for 41 minutes. A lamp is never turned off
        // by the passage of time; it is turned UP.
        let old = Date().addingTimeInterval(-SessionActivity.stalled - 60)
        guard case .blocked(let reason) = SessionActivity.classify(
            tail: [assistantToolUse()], modified: old)
        else { return XCTFail("an hour of silence from a live agent is amber, not off") }
        XCTAssertTrue(reason.contains("silent for"), reason)
        // No dated evidence at all is a different thing from silence: it is an
        // unreadable file, and inventing an age for it would be a guess.
        XCTAssertEqual(SessionActivity.classify(tail: [assistantToolUse()], modified: nil), .idle)
    }

    func testAToolCallInsideTheHourIsStillJustWorking() {
        let recent = Date().addingTimeInterval(-SessionActivity.stalled + 600)
        XCTAssertEqual(
            SessionActivity.classify(tail: [assistantToolUse()], modified: recent), .working)
    }

    func testBlockedDoesNotDecay() {
        // A session blocked an hour ago is still blocked: nothing has moved.
        let old = Date().addingTimeInterval(-SessionActivity.stalled - 60)
        guard case .blocked = SessionActivity.classify(tail: [apiError("limit")], modified: old) else {
            return XCTFail("amber is never retired by a clock")
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

    func testAnOpenPromptOnASilentSessionAsksForAHuman() {
        // A session that crashed mid-turn leaves a prompt with no Stop
        // forever. It used to decay to idle, which is how a crashed session
        // became invisible; it turns amber now, which is how it gets looked at.
        let cold = Date().addingTimeInterval(-SessionActivity.stalled - 60)
        guard case .blocked = SessionActivity.classify(
            tail: [assistant(text: "Done.")], modified: cold,
            boundary: boundary(.userPromptSubmit, agoSeconds: SessionActivity.stalled + 60))
        else { return XCTFail("an hour of silence under an open prompt is amber") }
    }

    // MARK: - The transcript says when a turn ended (18 Aug)
    //
    // Second report the same evening: one lamp still blue, and this time the
    // two clocks agreed — the session had written 13 minutes ago. It had
    // called ScheduleWakeup and parked itself for half an hour. The turn ended
    // on a TOOL RESULT, which the classifier reads as "mid-loop, therefore
    // working", and the only thing saying otherwise was the `turn_duration`
    // system line 130ms later, which the walk was skipping as bookkeeping.
    // Measured over the 25 most recently touched transcripts: 59 turn_duration
    // entries, every one immediately after the last message of a turn, never
    // once followed by that turn continuing.

    private func turnEnded() -> String {
        #"{"type":"system","subtype":"turn_duration","durationMs":17735}"#
    }

    func testATurnThatEndedOnAToolResultIsIdle() {
        // A session parked on ScheduleWakeup: the last words are a tool result,
        // and it is asleep until the wakeup fires.
        let tail = [assistantToolUse(), userPrompt(), turnEnded()]
        XCTAssertEqual(SessionActivity.classify(tail: tail, modified: warm), .idle)
    }

    func testAProseTurnDeclaredOverIgnoresAStalePromptBoundary() {
        // The marker outranks a boundary that predates it — a submit from
        // before the turn ended cannot mean the turn is still running.
        let tail = [assistant(text: "Done."), turnEnded()]
        XCTAssertEqual(
            SessionActivity.classify(tail: tail, modified: warm,
                                     boundary: boundary(.userPromptSubmit, agoSeconds: 600)),
            .idle)
    }

    func testAPromptSubmittedAfterTheMarkerStillWins() {
        // The one overrule the hooks legitimately have: a new turn whose first
        // line has not been flushed to disk yet.
        let tail = [timestamped(assistant(text: "Done."), agoSeconds: 600),
                    timestamped(turnEnded(), agoSeconds: 600)]
        XCTAssertEqual(
            SessionActivity.classify(tail: tail, modified: warm,
                                     boundary: boundary(.userPromptSubmit, agoSeconds: 2)),
            .working)
    }

    func testANewPromptAfterTheMarkerIsWorking() {
        // The commonest shape of all: the marker, then the next prompt. The
        // walk meets the prompt first and never consults the marker.
        let tail = [assistant(text: "Done."), turnEnded(), userPrompt()]
        XCTAssertEqual(SessionActivity.classify(tail: tail, modified: warm), .working)
    }

    func testAnErrorStillOutranksTheEndOfTheTurn() {
        // A turn that died on a usage limit also ends, and the marker must not
        // paint over the one lamp that needs a human.
        let tail = [apiError("You've hit your session limit"), turnEnded()]
        guard case .blocked = SessionActivity.classify(tail: tail, modified: warm) else {
            return XCTFail("amber outranks a finished turn")
        }
    }

    // MARK: - The lamp dates its own evidence (18 Aug)
    //
    // Two of the three blue lamps on the grid at 17:19 belonged to sessions
    // that had finished 105 and 149 minutes earlier. Nothing was stuck: the
    // lamp was recomputed every five seconds and came back blue every time,
    // because the stale-verdict clock was reading the FILE's clock and Claude Code
    // keeps writing to a finished session's transcript long after the
    // conversation ends — snapshot updates, ai-title, bridge-session, pr-link.
    // 30 of the 40 sessions in a two-day window had a file clock past their
    // last conversational word by more than the stall window — median 23
    // hours, maximum five days (`tbase lamps`).

    private func timestamped(_ line: String, agoSeconds: TimeInterval) -> String {
        let at = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-agoSeconds))
        return line.replacingOccurrences(
            of: #"{"type":"#, with: #"{"timestamp":"\#(at)","type":"#)
    }

    func testBookkeepingWritesDoNotRearmAStaleWorkingVerdict() {
        // The exact shape on disk: an unanswered prompt from two hours ago,
        // and a file touched a minute ago by something that is not the
        // conversation. The prompt is what the verdict rests on, so the
        // prompt's age is the verdict's age.
        let tail = [timestamped(userPrompt(), agoSeconds: 7200)]
        // Amber since the 18 Aug re-ruling, idle before it. Either way the
        // point stands and is the point of this test: NOT blue, because the
        // file moving is not the conversation speaking.
        guard case .blocked = SessionActivity.classify(tail: tail, modified: warm)
        else { return XCTFail("a fresh mtime must not date a two-hour-old prompt") }
    }

    func testAToolCallIsDatedByItsOwnEntryNotTheFile() {
        let tail = [timestamped(assistantToolUse(), agoSeconds: 7200)]
        guard case .blocked = SessionActivity.classify(tail: tail, modified: warm)
        else { return XCTFail("the tool call's own timestamp dates the verdict") }
    }

    func testALiveTurnStaysBlueOnAFileThatHasNotBeenTouched() {
        // The other direction, and the reason this is not simply a stricter
        // gate: a warm entry wins over a cold file.
        let cold = Date().addingTimeInterval(-SessionActivity.stalled - 60)
        let tail = [timestamped(userPrompt(), agoSeconds: 5)]
        XCTAssertEqual(SessionActivity.classify(tail: tail, modified: cold), .working)
    }

    func testABoundaryCannotRearmOffTheFileEither() {
        // resolveIdle had the same disease: it took the newest of the hook row
        // and the mtime. A prompt submitted two hours ago whose turn ended in
        // prose two hours ago is finished, however recently the file moved.
        let tail = [timestamped(assistant(text: "Done."), agoSeconds: 7200)]
        guard case .blocked = SessionActivity.classify(
            tail: tail, modified: warm,
            boundary: boundary(.userPromptSubmit, agoSeconds: 7200))
        else { return XCTFail("a fresh mtime must not re-arm a two-hour-old boundary") }
    }

    func testUntimestampedEntriesStillFallBackToTheFile() {
        // Fixtures and the odd real line carry no timestamp; mtime remains the
        // stand-in there rather than a session going dark.
        XCTAssertEqual(SessionActivity.classify(tail: [userPrompt()], modified: warm), .working)
    }

    func testALongTurnStaysWorkingOnTranscriptWarmthAlone() {
        // The boundary row is written at submit and never touched again, so a
        // turn running longer than a poll interval must keep its lamp from
        // the transcript's own warmth.
        let oldPrompt: TimeInterval = 1800
        XCTAssertEqual(
            SessionActivity.classify(
                tail: [assistant(text: "Still going.")], modified: warm,
                boundary: boundary(.userPromptSubmit, agoSeconds: oldPrompt)),
            .working)
    }

    // MARK: - Characterization against the real archive
    //
    // The unit tests above use fixtures I wrote, which means they can only
    // confirm what I already believed. This one runs the real classifier over
    // every API error on this machine and asserts the split matches what was
    // measured (176 needing a human vs 110 self-healing, of 286). It skips
    // when the archive is absent so CI on another machine stays green.

    func testTransientSplitAgainstTheRealArchive() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        // Opt-in: the full corpus takes ~200s to scan, which is a tax on
        // every future run and exactly the kind of slow test that gets
        // deleted rather than fixed. Run it deliberately after touching the
        // classifier:  TB_ARCHIVE_EVAL=1 swift test --filter Archive
        guard ProcessInfo.processInfo.environment["TB_ARCHIVE_EVAL"] == "1" else {
            throw XCTSkip("set TB_ARCHIVE_EVAL=1 to scan the real transcript archive")
        }
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("no local transcript archive")
        }
        var blocking = 0, transient = 0, samples: [String] = []
        // Every transcript, not a prefix: the first version capped at 400
        // enumerated URLs and reached only 14 errors out of ~288, which made
        // its verdict noise. Huge files are skipped instead — a few sessions
        // run to hundreds of megabytes and would dominate the runtime without
        // changing the ratio.
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" } ?? []
        var skipped = 0
        for file in files {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size > 64 * 1024 * 1024 { skipped += 1; continue }
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.readToEnd(),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.contains("isApiErrorMessage") {
                guard let d = line.data(using: .utf8),
                      let entry = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      entry["isApiErrorMessage"] as? Bool == true,
                      let message = entry["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]],
                      let reason = content.first?["text"] as? String
                else { continue }
                if SessionActivity.isTransient(reason) { transient += 1 }
                else {
                    blocking += 1
                    if samples.count < 3 { samples.append(String(reason.prefix(50))) }
                }
            }
        }
        let total = blocking + transient
        try XCTSkipIf(total == 0, "archive holds no API errors")
        print("real archive: \(total) errors — \(blocking) blocking, \(transient) transient"
              + " (\(skipped) oversized files skipped)")
        print("blocking samples: \(samples)")
        XCTAssertGreaterThan(total, 100, "the archive scan is not reaching the corpus")
        // Both classes must be represented: a classifier that called
        // everything one thing would pass every fixture test above and still
        // be useless in the field.
        XCTAssertGreaterThan(blocking, 0, "nothing classified as needing a human")
        XCTAssertGreaterThan(transient, 0, "nothing classified as self-healing")
        // Measured over the whole corpus: ~40% genuinely need a human (session
        // and usage limits dominate), ~50% self-heal, and a ~10% tail that
        // matches nothing and therefore lights amber by design. The bounds are
        // wide because the ratio tracks how the day went — a limit-heavy
        // afternoon shifts it hard — and narrow enough to catch the two
        // failures that matter: a list that swallows real blocks, and one that
        // has drifted back to lighting amber for everything.
        let blockingShare = Double(blocking) / Double(total)
        XCTAssertGreaterThan(blockingShare, 0.25, "transient is swallowing real blocks")
        XCTAssertLessThan(blockingShare, 0.75, "everything is lighting amber again")
    }

    func testMissingFileIsNilNotAGuess() {
        XCTAssertNil(SessionActivity.read(transcriptPath: "/nope/does-not-exist.jsonl"))
    }
}
