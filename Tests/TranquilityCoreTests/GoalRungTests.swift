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
        XCTAssertTrue(system.contains("Twelve words at most"))
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
