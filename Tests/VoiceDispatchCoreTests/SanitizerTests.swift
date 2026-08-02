import XCTest
@testable import VoiceDispatchCore

final class SanitizerTests: XCTestCase {
    let sanitizer = SpokenTextSanitizer()

    /// Things that must never reach the speech synthesizer. A prompt instruction
    /// alone erodes — eventually the model slips one through and the loop reads a
    /// commit hash aloud, which was the whole complaint that started this project.
    func testForbiddenTokensAreNeverSpoken() throws {
        let cases: [(String, String)] = [
            ("Fixed in commit a3f9c21b4e including tests", "hash"),
            ("Session 58c91a82-b640-47db-a969-b56bba09d4ab finished", "uuid"),
            ("Edited /Users/robertnowell/Projects/kopi/promotions/src/index.ts", "path"),
            ("Updated globals.css and tokens.swift", "filename"),
            ("Run `npm run migrate` before deploying", "code-span"),
            ("See https://github.com/foo/bar/pull/2261 for details", "url"),
            ("Token vk_fake_ABCDEFGHIJKLMNOPQRSTUVWXYZ01 was rotated", "opaque-token"),
        ]

        for (input, expectedLabel) in cases {
            let result = sanitizer.sanitize(input)
            XCTAssertTrue(
                result.redactions.contains(expectedLabel),
                "\(expectedLabel) not redacted in: \(input) -> \(result.text)")
        }
    }

    func testRedactedOutputKeepsReadableProse() throws {
        let result = sanitizer.sanitize("Fixed in commit a3f9c21b4e and edited /Users/rob/app/main.swift")
        XCTAssertEqual(result.text, "Fixed in commit a commit and edited a file path")
        XCTAssertFalse(result.text.contains("a3f9c21b4e"))
        XCTAssertFalse(result.text.contains("/Users"))
    }

    /// Regression: a naive `[0-9a-f]{7,40}` also matches ordinary English words that
    /// happen to be spelled from a-f. "defaced" and "accede" are real words.
    func testOrdinaryWordsMadeOfHexLettersSurvive() throws {
        let input = "The defaced facade in the cafe was decaffeinated and we accede"
        let result = sanitizer.sanitize(input)
        XCTAssertEqual(result.text, input, "hex rule must require a digit, or it eats real words")
        XCTAssertTrue(result.redactions.isEmpty)
    }

    func testWordBudgetIsEnforced() throws {
        let long = Array(repeating: "word", count: 120).joined(separator: " ")
        let result = sanitizer.sanitize(long)
        XCTAssertLessThanOrEqual(result.wordCount, SpokenTextSanitizer.maxWords)
    }

    func testClampPrefersASentenceBoundary() throws {
        let text = (Array(repeating: "alpha", count: 20).joined(separator: " "))
            + ". " + (Array(repeating: "beta", count: 40).joined(separator: " "))
        let clamped = SpokenTextSanitizer.clamp(text)
        XCTAssertTrue(clamped.hasSuffix("."), "should stop at the sentence break, not mid-clause")
        XCTAssertFalse(clamped.contains("beta"))
    }

    func testClampFallsBackToEllipsisWhenNoUsableBoundary() throws {
        let text = Array(repeating: "gamma", count: 80).joined(separator: " ")
        XCTAssertTrue(SpokenTextSanitizer.clamp(text).hasSuffix("…"))
    }

    func testShortCleanTextIsUntouched() throws {
        let input = "Export refactor is done and tests pass. The migration has not run yet."
        let result = sanitizer.sanitize(input)
        XCTAssertEqual(result.text, input)
        XCTAssertTrue(result.redactions.isEmpty)
    }

    // MARK: - Deterministic floor

    func testDeterministicSummarizerNeverThrowsAndStaysInBudget() async throws {
        let provider = DeterministicSummarizer()
        let request = SummaryRequest(
            lastAssistantMessage: Array(repeating: "sentence here", count: 200).joined(separator: ". "),
            projectLabel: "promotions")
        let raw = try await provider.summarize(request)
        XCTAssertLessThanOrEqual(sanitizer.sanitize(raw).wordCount, SpokenTextSanitizer.maxWords)
    }

    func testNotificationLinesAreSpecificToTheirMatcher() {
        let permission = DeterministicSummarizer.notificationLine(
            SummaryRequest(lastAssistantMessage: "", projectLabel: "syndit",
                           hookEvent: .notification, notificationMatcher: "permission_prompt"))
        XCTAssertTrue(permission.contains("permission"))

        let idle = DeterministicSummarizer.notificationLine(
            SummaryRequest(lastAssistantMessage: "", projectLabel: "syndit",
                           hookEvent: .notification, notificationMatcher: "idle_prompt"))
        XCTAssertTrue(idle.contains("idle"))
    }

    /// The chain must always produce something. A silent loop is a broken loop.
    func testChainAlwaysReturnsEvenWithNoConfiguredProviders() async {
        struct AlwaysFails: SummaryProvider {
            let name = "always-fails"
            let isConfigured = true
            func summarize(_ request: SummaryRequest) async throws -> String {
                throw SummaryError.emptyResponse
            }
        }
        let chain = SummarizerChain(providers: [AlwaysFails()])
        let summary = await chain.summarize(
            SummaryRequest(lastAssistantMessage: "Did the thing.", projectLabel: "kopi"))
        XCTAssertFalse(summary.spoken.text.isEmpty)
        XCTAssertEqual(summary.provider, "deterministic-fallback")
    }
}
