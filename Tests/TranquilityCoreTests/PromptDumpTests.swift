import XCTest
@testable import TranquilityCore

/// Writes the compiled prompts to disk so a person can read them.
///
/// Not an assertion: a dump. Equality is proved by the other tests; this exists
/// because "the prompt did not change" is a claim worth reading rather than
/// taking on trust, and because the same input has to be rendered by three
/// implementations across two languages.
final class PromptDumpTests: XCTestCase {
    func testWriteCompiledPromptsForReview() throws {
        guard let out = ProcessInfo.processInfo.environment["TB_PROMPT_DUMP_DIR"] else {
            throw XCTSkip("set TB_PROMPT_DUMP_DIR to dump the compiled prompts")
        }
        let request = SummaryRequest(
            lastAssistantMessage: """
                The export is ready. All tests passed, and I pushed the branch. \
                One thing to decide: the CSV writer drops the header row when the \
                result set is empty, which reads as a corrupt file rather than an \
                empty one.
                """,
            projectLabel: "Kopi",
            firstUserMessage: "Can you add an export button to the dashboard",
            previousGoal: "Ship the CSV export",
            gitBranch: "feature/export",
            hookEvent: .stop,
            notificationMatcher: nil,
            correctiveNote: nil)

        let dir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try AnthropicSummaryProvider.systemPrompt(projectLabel: request.projectLabel)
            .write(to: dir.appendingPathComponent("swift-system.txt"), atomically: true, encoding: .utf8)
        try AnthropicSummaryProvider.userPrompt(for: request)
            .write(to: dir.appendingPathComponent("swift-user-before.txt"), atomically: true, encoding: .utf8)
        try AnthropicSummaryProvider.userPromptFromTemplate(for: request)
            .write(to: dir.appendingPathComponent("swift-user-after.txt"), atomically: true, encoding: .utf8)
    }
}
