import XCTest
@testable import TranquilityCore

/// The ladder's first rung (19 Aug). The callsign was removed deliberately, so
/// nothing said WHICH work an announcement was about; `goal` was the obvious
/// candidate and could not be promoted as it stood.
///
/// Measured across the live store before changing anything: 59 sessions with
/// 5+ turns, averaging 17.1 turns, averaged 17.0 DISTINCT goals. Not one
/// session in 59 kept a single goal. The cause was structural — every other
/// field answers "what happened in THIS turn", which is in the model's input,
/// while `goal` asked "what is this session for", which was not. So it inferred
/// a fresh aim from each turn.
final class GoalRungTests: XCTestCase {

    /// The carried goal has to REACH the model, and be framed as state to keep
    /// rather than as background — the opening ask sits in the same prompt and
    /// is framed the opposite way ("stale, never describe as current work"),
    /// so a carried goal that landed in that register would be ignored.
    func testTheCarriedGoalIsInThePromptAndMarkedToKeep() {
        let request = SummaryRequest(
            lastAssistantMessage: "Rewrote the clamp.",
            projectLabel: "tranquility base",
            previousGoal: "fix the lamp so clicking it turns the session off")
        let prompt = AnthropicSummaryProvider.userPrompt(for: request)
        XCTAssertTrue(prompt.contains("fix the lamp so clicking it turns the session off"))
        XCTAssertTrue(prompt.contains("KEEP IT WORD FOR WORD"))
    }

    /// No carried goal, no carry block. A first turn has nothing to keep, and a
    /// dangling header with an empty value invites the model to fill it.
    func testAFirstTurnCarriesNothing() {
        let request = SummaryRequest(lastAssistantMessage: "Started.",
                                     projectLabel: "tranquility base")
        let prompt = AnthropicSummaryProvider.userPrompt(for: request)
        XCTAssertFalse(prompt.contains("KEEP IT WORD FOR WORD"))
        let empty = SummaryRequest(lastAssistantMessage: "Started.",
                                   projectLabel: "tranquility base", previousGoal: "")
        XCTAssertFalse(AnthropicSummaryProvider.userPrompt(for: empty)
            .contains("KEEP IT WORD FOR WORD"))
    }

    /// The instruction has to say what the rung is FOR, in the register the
    /// operator asked for. This pins the example, because the failure it
    /// replaces was fluent, plausible project-speak.
    func testTheInstructionAsksForTheOperatorsRegister() {
        let system = AnthropicSummaryProvider.systemPrompt(projectLabel: "tranquility base")
        XCTAssertTrue(system.contains("wouldn't turn it off"),
                      "the worked example is the whole instruction")
        // The length rule moved from a count to the examples (see
        // testTheInstructionGivesNoWordCount); what stays pinned is that the
        // worked example is in the operator's register, because the failure it
        // replaces was fluent, plausible project-speak.
        XCTAssertTrue(system.contains("says out loud"))
        XCTAssertTrue(system.contains("COPY IT VERBATIM"))
    }

    /// The carried goal is state, and the opening ask is stale background. Both
    /// are in the prompt; they must not be described the same way.
    func testTheCarriedGoalIsNotFramedLikeTheOpeningAsk() {
        let request = SummaryRequest(
            lastAssistantMessage: "Did the work.",
            projectLabel: "tranquility base",
            firstUserMessage: "it's time to think about the UI again",
            previousGoal: "fix the lamp so clicking it turns the session off")
        let prompt = AnthropicSummaryProvider.userPrompt(for: request)
        guard let ask = prompt.range(of: "HOURS AGO"),
              let carried = prompt.range(of: "KEEP IT WORD FOR WORD")
        else { return XCTFail("both blocks must be present") }
        XCTAssertNotEqual(ask.lowerBound, carried.lowerBound)
        XCTAssertTrue(prompt.contains("possibly abandoned since"))
    }
}

extension GoalRungTests {
    /// The extraction must not have changed the prompt for any existing path.
    /// Assembly moved out of `brief(for:)` into a static function, and a moved
    /// block is exactly where a silent edit hides — the model would keep
    /// answering, slightly differently, with nothing red.
    func testTheExistingPromptIsUnchangedWithoutACarriedGoal() {
        let request = SummaryRequest(
            lastAssistantMessage: "Rewrote the clamp and the tests are green.",
            projectLabel: "tranquility base",
            firstUserMessage: "it's time to think about the UI again",
            gitBranch: "ui/the-grid-lights-its-words",
            hookEvent: .notification,
            notificationMatcher: "permission_prompt")
        let prompt = AnthropicSummaryProvider.userPrompt(for: request)
        // Every block the old assembly produced, in order.
        let expected = [
            "Project: tranquility base",
            "THIS SESSION IS BLOCKED AND WAITING ON THE USER (permission_prompt)",
            "Branch: ui/the-grid-lights-its-words",
            "How this session opened, HOURS AGO and possibly abandoned since",
            "it's time to think about the UI again",
            "The agent's final message this turn:",
            "Rewrote the clamp and the tests are green.",
        ]
        var cursor = prompt.startIndex
        for fragment in expected {
            guard let found = prompt.range(of: fragment, range: cursor..<prompt.endIndex) else {
                return XCTFail("missing or out of order: \(fragment)")
            }
            cursor = found.upperBound
        }
        XCTAssertFalse(prompt.contains("KEEP IT WORD FOR WORD"))
    }

    /// The corrective note still lands last, after everything else. It is
    /// appended to `user` after assembly, which is the one thing the extraction
    /// could plausibly have dropped.
    func testTheCorrectiveNoteStillLandsLast() {
        let request = SummaryRequest(
            lastAssistantMessage: "Said 2,294.",
            projectLabel: "tranquility base",
            correctiveNote: "The number 2294 is not in the source. Remove it.")
        let prompt = AnthropicSummaryProvider.userPrompt(for: request)
        guard let message = prompt.range(of: "Said 2,294."),
              let note = prompt.range(of: "The number 2294 is not in the source.")
        else { return XCTFail("both must be present") }
        XCTAssertGreaterThan(note.lowerBound, message.lowerBound)
    }
}

extension GoalRungTests {
    /// A turn with no goal is a gap, not a change of subject.
    ///
    /// 20.6% of briefs write none — a plumbing turn has no aim to state and the
    /// summariser is told to use null rather than pad. Reading the newest brief
    /// therefore handed the next turn a nil about one turn in five, breaking
    /// the chain and restarting the drift the rung exists to remove. Caught on
    /// the first post-deploy sample, not in review.
    func testTheCarrySkipsTurnsThatWroteNoGoal() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-carry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try QueueStore(url: dir.appendingPathComponent("queue.sqlite"))
        let base = Date(timeIntervalSince1970: 1_787_160_000)
        let aim = "fix the lamp so clicking it turns the session off"

        try store.saveBrief(SessionBrief(topic: "the lamp", goal: aim, happened: "Found it."),
                            sessionId: "s", eventRowid: 1, provider: "p", callsign: nil, at: base)
        // Two plumbing turns in a row, neither with an aim to state.
        try store.saveBrief(SessionBrief(topic: "plumbing", happened: "Renamed a symbol."),
                            sessionId: "s", eventRowid: 2, provider: "p", callsign: nil,
                            at: base.addingTimeInterval(600))
        try store.saveBrief(SessionBrief(topic: "plumbing", happened: "Fixed a warning."),
                            sessionId: "s", eventRowid: 3, provider: "p", callsign: nil,
                            at: base.addingTimeInterval(1200))

        XCTAssertEqual(try store.carriedGoal(for: "s"), aim,
                       "the goal did not survive two turns that wrote none")
        XCTAssertNil(try store.carriedGoal(for: "other"))
    }

    /// A newer goal still wins. Skipping gaps must not mean pinning the oldest.
    func testTheNewestRealGoalWins() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-carry2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try QueueStore(url: dir.appendingPathComponent("queue.sqlite"))
        let base = Date(timeIntervalSince1970: 1_787_160_000)
        try store.saveBrief(SessionBrief(topic: "a", goal: "the old aim", happened: "x"),
                            sessionId: "s", eventRowid: 1, provider: "p", callsign: nil, at: base)
        try store.saveBrief(SessionBrief(topic: "b", goal: "the new aim", happened: "y"),
                            sessionId: "s", eventRowid: 2, provider: "p", callsign: nil,
                            at: base.addingTimeInterval(600))
        XCTAssertEqual(try store.carriedGoal(for: "s"), "the new aim")
    }
}

extension GoalRungTests {
    /// The template, pinned. "In project X, we are solving problem Y" — both
    /// halves, because a goal naming only the problem leaves the operator
    /// asking which of ten sessions is talking, and one naming only the project
    /// says nothing about the work.
    func testTheInstructionCarriesTheTemplateAndItsWorkedExamples() {
        let system = AnthropicSummaryProvider.systemPrompt(projectLabel: "tranquility base")
        XCTAssertTrue(system.contains("WE ARE [doing X] [to/for Y] IN [Z]"))
        XCTAssertTrue(system.contains("ALWAYS begin with \"We are\""))
        XCTAssertTrue(system.contains("subject line versus title split"))
        XCTAssertTrue(system.contains("Klaviyo flow health for U Vape"))
        XCTAssertTrue(system.contains("clicking a lamp"))
    }

    /// The project is not the directory, and not a symbol either. Both traps
    /// were real: a session in ~/Projects working on kopi dot ai, and one that
    /// answered "In StatusHUD" — a file inside tranquility base.
    func testTheInstructionRulesOutDirectoriesAndSymbols() {
        let system = AnthropicSummaryProvider.systemPrompt(projectLabel: "tranquility base")
        XCTAssertTrue(system.contains("not the directory the agent is running from"))
        XCTAssertTrue(system.contains("StatusHUD is a file inside tranquility base"))
    }

    /// An invented project is read as fact. Two real replay answers got this
    /// wrong — "in Klaviyo" about a MAILCHIMP audit, and "in robertnowell's
    /// Mac" bolted onto a goal whose subject was already Time Machine — so the
    /// trailing "in Z" is droppable and the ban is written into the prompt.
    func testTheProjectMustBeANameTheWorkUses() {
        let system = AnthropicSummaryProvider.systemPrompt(projectLabel: "tranquility base")
        XCTAssertTrue(system.contains("Z MUST BE A NAME THE WORK ITSELF USES"))
        XCTAssertTrue(system.contains("an invented Z is far worse than none"))
        XCTAssertTrue(system.contains("MAILCHIMP audit"))
    }

    /// No word count, deliberately, and the reason is recorded where the next
    /// person to "helpfully" add one will read it: every number tried made the
    /// answers longer.
    func testTheInstructionGivesNoWordCount() {
        let system = AnthropicSummaryProvider.systemPrompt(projectLabel: "tranquility base")
        XCTAssertTrue(system.contains("No number is given, deliberately"))
        XCTAssertFalse(system.contains("Twelve words at most"))
    }
}
