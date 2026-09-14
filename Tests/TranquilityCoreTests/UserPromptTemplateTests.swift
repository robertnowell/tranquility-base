import XCTest
@testable import TranquilityCore

/// The user half of the summary prompt, rendered from the shared template.
///
/// The system half moved to the contract directory so the managed Gateway
/// cannot drift from the app. The user half is harder: it is not a string but
/// fifty lines of conditionals, and a second implementation in TypeScript
/// would agree on the day it was written and diverge quietly afterwards. That
/// is the same failure as the deleted vnext prompts, one service further out.
///
/// So it is a list of ordered segments with a closed vocabulary of conditions,
/// deliberately not a template language: a mini-language is itself a thing two
/// implementations disagree about. This test holds the rendered output equal to
/// the Swift that ships, across every shape of request the conditions allow.
final class UserPromptTemplateTests: XCTestCase {

    private func request(
        notification: Bool = false, branch: String? = nil, goal: String? = nil,
        opening: String? = nil, note: String? = nil, matcher: String? = nil
    ) -> SummaryRequest {
        SummaryRequest(
            lastAssistantMessage: "The export is ready. All tests passed.",
            projectLabel: "Kopi",
            firstUserMessage: opening, previousGoal: goal, gitBranch: branch,
            hookEvent: notification ? .notification : .stop,
            notificationMatcher: matcher, correctiveNote: note)
    }

    /// Every combination of the optional blocks, because the bug this guards
    /// against is a condition evaluated differently, and conditions only show
    /// themselves at their boundaries.
    func testTemplateRendersWhatTheShippedCodeRenders() throws {
        var checked = 0
        for notification in [false, true] {
          for branch in [nil, "feature/export"] as [String?] {
            for goal in [nil, "", "Ship the export"] as [String?] {
              for opening in [nil, "Can you add an export button"] as [String?] {
                for note in [nil, "Say less about the branch."] as [String?] {
                  let r = request(notification: notification, branch: branch,
                                  goal: goal, opening: opening, note: note)
                  XCTAssertEqual(
                    AnthropicSummaryProvider.userPromptFromTemplate(for: r),
                    AnthropicSummaryProvider.userPrompt(for: r),
                    "diverged for notification=\(notification) branch=\(branch ?? "nil") "
                    + "goal=\(goal ?? "nil") opening=\(opening ?? "nil") note=\(note ?? "nil")")
                  checked += 1
                }
              }
            }
          }
        }
        XCTAssertEqual(checked, 48, "every combination of the optional blocks")
    }

    /// The matcher has a default, and a default that only one side knows is a
    /// default that produces two different prompts.
    func testTheNotificationMatcherFallsBackIdentically() {
        let withMatcher = request(notification: true, matcher: "permission_prompt")
        let without = request(notification: true)
        XCTAssertEqual(AnthropicSummaryProvider.userPromptFromTemplate(for: withMatcher),
                       AnthropicSummaryProvider.userPrompt(for: withMatcher))
        XCTAssertEqual(AnthropicSummaryProvider.userPromptFromTemplate(for: without),
                       AnthropicSummaryProvider.userPrompt(for: without))
        XCTAssertTrue(AnthropicSummaryProvider.userPromptFromTemplate(for: without)
                        .contains("needs input"))
    }

    /// An empty carried goal is not a carried goal. The shipped code checks
    /// `!carried.isEmpty`, and a presence-only check in another language would
    /// emit the block with nothing in it.
    func testAnEmptyGoalIsAbsentRatherThanBlank() {
        let rendered = AnthropicSummaryProvider.userPromptFromTemplate(for: request(goal: ""))
        XCTAssertFalse(rendered.contains("KEEP IT WORD FOR WORD"))
    }
}
