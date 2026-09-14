import XCTest
@testable import TranquilityCore

/// The summariser's system prompt is a contract, not a Swift detail.
///
/// Ruled 14 Sep 2026: whatever the app tells the model, the managed gateway
/// tells it too, or the two drift. The gateway has no prompt of its own in
/// source; it reads the contract directory this repo publishes
/// (`contracts/gateway/v1/`, next to `summary.schema.json`). So the prompt
/// lives there as `summary.prompt.txt`, and this test holds the Swift
/// literal to it byte for byte. Change one, change both, or this fails.
final class SummaryPromptContractTests: XCTestCase {

    private var contractURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TranquilityCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("contracts/gateway/v1/summary.prompt.txt")
    }

    func testTheSystemPromptIsTheContractFileByteForByte() throws {
        let file = try String(contentsOf: contractURL, encoding: .utf8)
        XCTAssertEqual(AnthropicSummaryProvider.systemPrompt(projectLabel: "any"), file,
                       "Sources/TranquilityCore/Summarizer.swift and contracts/gateway/v1/summary.prompt.txt disagree")
    }

    /// The label used to be interpolated into the prompt (the model was told
    /// to open with it, and code then stripped it). It is not any more, which
    /// is what lets the prompt be one file two systems can share.
    func testTheSystemPromptDoesNotDependOnTheLabel() {
        XCTAssertEqual(AnthropicSummaryProvider.systemPrompt(projectLabel: "kopi"),
                       AnthropicSummaryProvider.systemPrompt(projectLabel: "tranquility base"))
    }
}
