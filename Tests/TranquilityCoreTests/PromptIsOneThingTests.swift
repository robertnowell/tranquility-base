import XCTest
@testable import TranquilityCore

/// The spoken summary's prompt, and the one place it lives.
///
/// This is the string the whole product is: it decides what you hear after a
/// turn. It used to be a Swift literal described in a comment as "ported
/// verbatim" from `tools/replay/prompts/vnext-a.txt`, and by 14 Sep 2026 the
/// literal had grown to 2,228 words against that file's 749. Nothing had gone
/// wrong exactly, the prompt improved where it ships, but the eval harness was
/// replaying a prompt that had not shipped for a long time and nobody could
/// see it.
///
/// So the prompt now lives in `contracts/gateway/v1/summary-prompt.txt`, beside
/// the schema, because the managed Gateway must produce identical summaries and
/// a second copy over there would repeat the same failure one service further
/// out. This test is what makes that real: change one and the other fails,
/// immediately, instead of quietly a month later.
final class PromptIsOneThingTests: XCTestCase {

    func testTheShippedPromptIsTheContractPrompt() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("contracts/gateway/v1/summary-prompt.txt")
        let onDisk = try String(contentsOf: url, encoding: .utf8)

        let label = "Kopi"
        let expected = onDisk
            .replacingOccurrences(of: "{project_label}", with: label)
            .trimmingCharacters(in: CharacterSet.newlines)
        let shipped = AnthropicSummaryProvider.systemPrompt(projectLabel: label)
            .trimmingCharacters(in: CharacterSet.newlines)

        if shipped != expected {
            // Say WHERE, because a 2,000-word diff in a test failure is not a
            // signal anybody can act on.
            let a = Array(shipped), b = Array(expected)
            var i = min(a.count, b.count)
            for k in 0..<min(a.count, b.count) where a[k] != b[k] { i = k; break }
            let from = max(0, i - 60), to = min(min(a.count, b.count), i + 60)
            XCTFail("""
                The shipped prompt and contracts/gateway/v1/summary-prompt.txt have \
                diverged at character \(i) (shipped \(a.count) chars, contract \(b.count)).
                shipped:  …\(String(a[from..<min(to, a.count)]))…
                contract: …\(String(b[from..<min(to, b.count)]))…
                Edit the contract file; the Swift literal follows it, not the other way round.
                """)
        }
    }

    /// The slot is the one thing the file cannot carry resolved, so it has to
    /// still be there: a contract file with the label already baked in would
    /// silently give every project the same name.
    func testTheProjectSlotSurvivesInTheContractFile() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(
            contentsOf: root.appendingPathComponent("contracts/gateway/v1/summary-prompt.txt"),
            encoding: .utf8)
        XCTAssertTrue(text.contains("{project_label}"))
        XCTAssertFalse(AnthropicSummaryProvider.systemPrompt(projectLabel: "Kopi").contains("{project_label}"),
                       "every slot must be substituted before the prompt is sent")
    }
}
