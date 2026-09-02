import XCTest
@testable import TranquilityCore

/// A hub's brief is a summary with no way down to the source. This is the way
/// down. The failure that matters is not "no text": it is text that is really
/// tool traffic, because a hub full of file listings looks like it is working.
final class TurnTextTests: XCTestCase {

    // MARK: - Claude Code

    private func line(_ json: String) -> String { json }

    /// A tool's output arrives as `type: "user"` too. Role alone cannot tell a
    /// person from a harness; the record can.
    func testAToolResultIsNotATurn() {
        let jsonl = [
            #"{"type":"user","message":{"content":"do the thing"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"on it"}]}}"#,
            #"{"type":"user","toolUseResult":{"ok":1},"message":{"content":[{"type":"tool_result","content":"file listing"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}"#,
        ].joined(separator: "\n")

        let turns = TurnText.claudeCode(jsonl: jsonl, limit: 10)
        XCTAssertEqual(turns.count, 1, "one person spoke once")
        XCTAssertEqual(turns[0].prompt, "do the thing")
        XCTAssertEqual(turns[0].prose, "on it\n\ndone")
        XCTAssertFalse(turns[0].prose.contains("file listing"))
    }

    /// Even without `toolUseResult`, a content array carrying a tool_result is
    /// the harness talking.
    func testAToolResultBlockAloneIsEnoughToSkip() {
        let jsonl = #"{"type":"user","message":{"content":[{"type":"tool_result","content":"x"}]}}"#
        XCTAssertTrue(TurnText.claudeCode(jsonl: jsonl, limit: 10).isEmpty)
    }

    /// tool_use and thinking are how the work happened, not what was said.
    func testOnlyTextBlocksBecomeProse() {
        let jsonl = [
            #"{"type":"user","message":{"content":"go"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"said"},{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#,
        ].joined(separator: "\n")
        let turns = TurnText.claudeCode(jsonl: jsonl, limit: 10)
        XCTAssertEqual(turns.first?.prose, "said")
    }

    func testTurnsSplitOnEveryHumanMessage() {
        let jsonl = [
            #"{"type":"user","message":{"content":"one"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"a"}]}}"#,
            #"{"type":"user","message":{"content":"two"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"b"}]}}"#,
        ].joined(separator: "\n")
        let turns = TurnText.claudeCode(jsonl: jsonl, limit: 10)
        XCTAssertEqual(turns.map(\.prompt), ["one", "two"])
        XCTAssertEqual(turns.map(\.prose), ["a", "b"])
    }

    /// A hub shows the end of a session, so the limit keeps the END.
    func testTheLimitKeepsTheNewestTurns() {
        let jsonl = (1...5).map {
            #"{"type":"user","message":{"content":"p\#($0)"}}"# + "\n"
                + #"{"type":"assistant","message":{"content":[{"type":"text","text":"a\#($0)"}]}}"#
        }.joined(separator: "\n")
        XCTAssertEqual(TurnText.claudeCode(jsonl: jsonl, limit: 2).map(\.prompt), ["p4", "p5"])
    }

    /// A bounded read starts mid-line by construction. A half-decoded object
    /// must not become a turn, and a line that is not JSON at all must not stop
    /// the parse.
    func testUndecodableLinesAreSkippedNotFatal() {
        let jsonl = [
            "{ this is not json",
            #"{"type":"user","message":{"content":"still here"}}"#,
            "",
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"yes"}]}}"#,
        ].joined(separator: "\n")
        let turns = TurnText.claudeCode(jsonl: jsonl, limit: 10)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].prompt, "still here")
    }

    /// Prose with no prompt before it belongs to no turn. A transcript read from
    /// the middle starts that way.
    func testProseBeforeAnyPromptIsDropped() {
        let jsonl = #"{"type":"assistant","message":{"content":[{"type":"text","text":"orphan"}]}}"#
        XCTAssertTrue(TurnText.claudeCode(jsonl: jsonl, limit: 10).isEmpty)
    }

    // MARK: - Codex

    func testCodexGroupsOnTheHumanTurn() {
        let msgs = [
            CodexRollout.Message(role: "developer", text: "system preamble"),
            CodexRollout.Message(role: "user", text: "one"),
            CodexRollout.Message(role: "assistant", text: "a"),
            CodexRollout.Message(role: "user", text: "two"),
            CodexRollout.Message(role: "assistant", text: "b"),
        ]
        let turns = TurnText.codex(messages: msgs, limit: 10)
        XCTAssertEqual(turns.map(\.prompt), ["one", "two"])
        XCTAssertEqual(turns.map(\.prose), ["a", "b"])
        XCTAssertFalse(turns.contains { $0.prose.contains("system preamble") },
                       "the harness's own preamble is not something anybody said")
    }

    // MARK: - The bounded read

    func testTheTailStartsAtALineBoundary() throws {
        let dir = NSTemporaryDirectory() + "tb-turntext-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let f = URL(fileURLWithPath: dir + "/t.jsonl")

        // Bigger than the cap, so the read starts inside a line.
        let filler = String(repeating: "x", count: 4096)
        var text = ""
        while text.utf8.count < TurnText.byteCap + 8192 {
            text += #"{"pad":"\#(filler)"}"# + "\n"
        }
        text += #"{"type":"user","message":{"content":"the last thing"}}"# + "\n"
        try text.write(to: f, atomically: true, encoding: .utf8)

        let tail = try XCTUnwrap(TurnText.tail(of: f))
        XCTAssertLessThanOrEqual(tail.utf8.count, TurnText.byteCap)
        XCTAssertFalse(tail.hasPrefix("x"), "a partial line was dropped, not repaired")
        XCTAssertEqual(TurnText.claudeCode(jsonl: tail, limit: 1).first?.prompt,
                       "the last thing")
    }

    func testASmallFileIsReadWhole() throws {
        let dir = NSTemporaryDirectory() + "tb-turntext-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let f = URL(fileURLWithPath: dir + "/t.jsonl")
        try #"{"type":"user","message":{"content":"only"}}"#
            .write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(TurnText.claudeCode(jsonl: try XCTUnwrap(TurnText.tail(of: f)),
                                           limit: 5).first?.prompt, "only")
    }

    func testAMissingTranscriptIsEmptyNotACrash() {
        let nowhere = URL(fileURLWithPath: NSTemporaryDirectory() + "/tb-nope-" + UUID().uuidString)
        XCTAssertTrue(TurnText.forSession("no-such-session", limit: 3, home: nowhere).isEmpty)
    }
}

/// The hub end of it. A model with no transcript must render exactly as it did
/// before, and one with a transcript must not smuggle tool traffic onto a page.
final class HubTranscriptTests: XCTestCase {

    private func model(_ transcript: [TurnText.Turn]) -> HomeBase.Model {
        HomeBase.Model(
            sessionId: "0d04e845-65ff-488f-983c-58f371d661ed",
            title: "A session", callsign: nil, cwd: "/tmp", goal: "do a thing",
            turns: [HomeBase.Turn(at: Date(), topic: "t", happened: "it happened")],
            pages: [], transcript: transcript)
    }

    func testNoTranscriptRendersNoSection() {
        let html = HomeBase.render(model([]))
        XCTAssertFalse(html.contains("details class=\"transcript\""))
        XCTAssertFalse(html.contains("What was said"))
    }

    func testTheTranscriptRendersClosedAndNewestFirst() {
        let html = HomeBase.render(model([
            .init(prompt: "older ask", prose: "older prose"),
            .init(prompt: "newest ask", prose: "newest prose"),
        ]))
        XCTAssertTrue(html.contains("details class=\"transcript\""))
        XCTAssertFalse(html.contains("<details class=\"transcript\" open"),
                       "evidence sits closed under a summary")
        let newest = try? XCTUnwrap(html.range(of: "newest ask"))
        let older = try? XCTUnwrap(html.range(of: "older ask"))
        if let n = newest, let o = older {
            XCTAssertLessThan(n.lowerBound, o.lowerBound, "newest first, like the page above it")
        }
    }

    // MARK: - The join

    private func joined(briefs: [Date], turns: [(String, Date?)]) -> String {
        HomeBase.render(HomeBase.Model(
            sessionId: "0d04e845-65ff-488f-983c-58f371d661ed",
            title: "A session", callsign: nil, cwd: "/tmp", goal: "do a thing",
            turns: briefs.map { HomeBase.Turn(at: $0, topic: "t", happened: "it happened") },
            pages: [],
            transcript: turns.map { .init(prompt: $0.0, prose: "prose", at: $0.1) }))
    }

    /// The words print INSIDE the turn they belong to, not in a section under it.
    func testAStampedTurnIsFiledUnderTheBriefItPrecedes() {
        let brief = Date()
        let html = joined(briefs: [brief],
                          turns: [("the ask", brief.addingTimeInterval(-120))])
        XCTAssertTrue(html.contains("details class=\"transcript inline\""))
        XCTAssertFalse(html.contains("not filed above"),
                       "nothing is left over, so the remainder section is absent")
        XCTAssertEqual(html.components(separatedBy: "the ask").count - 1, 1,
                       "the words print once, under their turn")
    }

    /// The failure positional alignment would produce silently.
    func testTwoBriefsCannotClaimTheSameTurn() {
        let late = Date(), early = late.addingTimeInterval(-600)
        let html = joined(briefs: [late, early],
                          turns: [("only ask", early.addingTimeInterval(-60))])
        XCTAssertEqual(html.components(separatedBy: "only ask").count - 1, 1)
    }

    /// A turn AFTER the newest brief has no brief to sit under, and is not lost.
    func testATurnNoBriefAccountsForKeepsItsOwnSection() {
        let brief = Date()
        let html = joined(briefs: [brief],
                          turns: [("later ask", brief.addingTimeInterval(600))])
        XCTAssertTrue(html.contains("not filed above"))
        XCTAssertTrue(html.contains("later ask"))
    }

    /// Without the stamp there is no join, and the words still have to appear.
    func testAnUnstampedTurnStillPrints() {
        let html = joined(briefs: [Date()], turns: [("unstamped ask", nil)])
        XCTAssertTrue(html.contains("unstamped ask"))
        XCTAssertTrue(html.contains("not filed above"))
    }

    /// The stamp itself, read off a real transcript row.
    func testClaudeCodeCarriesTheTurnStamp() throws {
        let jsonl = """
        {"type":"user","timestamp":"2026-09-02T18:04:05.123Z","message":{"content":"hello"}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}
        """
        let turn = try XCTUnwrap(TurnText.claudeCode(jsonl: jsonl, limit: 3).first)
        let at = try XCTUnwrap(turn.at)
        XCTAssertEqual(at.timeIntervalSince1970, 1788372245.123, accuracy: 0.01)
    }

    /// A page is HTML and a prompt is whatever somebody typed.
    func testAPromptCannotInjectMarkup() {
        let html = HomeBase.render(model([
            .init(prompt: "<script>alert(1)</script>", prose: "ok"),
        ]))
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }
}

/// "Agent 019db12b" was on 300 of 452 hubs. Codex keeps thread names for 9 of
/// its own sessions, and a session with no briefs has no tab title either, so
/// the first thing a person typed is the best name available. It is also the
/// convention Codex itself uses for the names it does keep.
final class HubNameFallbackTests: XCTestCase {

    private func rendered(title: String?, transcript: [TurnText.Turn]) -> String {
        HomeBase.render(HomeBase.Model(
            sessionId: "019db12b-0000-0000-0000-000000000001",
            title: title, callsign: nil, cwd: nil, goal: nil,
            turns: [], pages: [], transcript: transcript))
    }

    func testARealNameAlwaysWins() {
        let html = rendered(title: "Codex agent not appearing in grid",
                            transcript: [.init(prompt: "some first prompt", prose: "")])
        XCTAssertTrue(html.contains("Codex agent not appearing in grid"))
    }

    /// The page still renders when there is nothing at all to name it with.
    func testNoNameAndNoTranscriptStillRenders() {
        let html = rendered(title: nil, transcript: [])
        XCTAssertTrue(html.contains("019db12b"))
    }

    /// The disclaimer under the transcript is gone: it read as an apology for
    /// the section, and the section is the evidence.
    func testTheTranscriptSectionSaysOnlyWhatItIs() {
        let html = rendered(title: "x", transcript: [.init(prompt: "p", prose: "s")])
        XCTAssertTrue(html.contains("Straight from the transcript. Newest first."))
        XCTAssertFalse(html.contains("no key that joins them"))
    }
}

extension TurnTextTests {
    /// Codex sends its own scaffolding with role `user`, so role alone cannot
    /// say a person typed it. Measured across 60 rollouts: scaffolding always
    /// opens with an XML-ish tag or the AGENTS.md heading; prompts are prose.
    func testCodexScaffoldingIsNotAPrompt() {
        let msgs = [
            CodexRollout.Message(role: "user", text: "# AGENTS.md instructions for /Users/x\n\n<INSTRUCTIONS>stuff</INSTRUCTIONS>"),
            CodexRollout.Message(role: "user", text: "<environment_context>\n<cwd>/Users/x</cwd>\n</environment_context>"),
            CodexRollout.Message(role: "user", text: "/login"),
            CodexRollout.Message(role: "assistant", text: "I cannot do that here."),
        ]
        let turns = TurnText.codex(messages: msgs, limit: 10)
        XCTAssertEqual(turns.map(\.prompt), ["/login"])
    }

    /// A person attaching an image sends the tag and their sentence together.
    /// Dropping the message would lose the sentence.
    func testAWrapperIsStrippedNotTheWholeMessage() {
        let msgs = [
            CodexRollout.Message(role: "user",
                text: "<image name=[Image #1] path=\"/tmp/a.png\"></image>\nwhat is wrong here?"),
            CodexRollout.Message(role: "assistant", text: "looking"),
        ]
        XCTAssertEqual(TurnText.codex(messages: msgs, limit: 5).first?.prompt,
                       "what is wrong here?")
    }

    func testProseIsUntouched() {
        XCTAssertEqual(TurnText.humanPart("just a normal question?"), "just a normal question?")
        XCTAssertEqual(TurnText.humanPart("a < b, surely"), "a < b, surely")
    }
}
