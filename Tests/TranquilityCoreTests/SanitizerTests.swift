import XCTest
@testable import TranquilityCore

final class SanitizerTests: XCTestCase {
    let sanitizer = SpokenTextSanitizer()

    /// Things that must never reach the speech synthesizer. A prompt instruction
    /// alone erodes — eventually the model slips one through and the loop reads a
    /// commit hash aloud, which was the whole complaint that started this project.
    func testForbiddenTokensAreNeverSpoken() throws {
        let cases: [(String, String)] = [
            ("Fixed in commit a3f9c21b4e including tests", "hash"),
            ("Session 58c91a82-b640-47db-a969-b56bba09d4ab finished", "uuid"),
            ("Edited /Users/example/Projects/app/src/index.ts", "path"),
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
        let result = sanitizer.sanitize("Fixed in commit a3f9c21b4e and edited /Users/example/app/main.swift")
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

    /// The budget is honoured by dropping whole sentences.
    func testWordBudgetIsEnforcedAcrossSentences() throws {
        let sentence = Array(repeating: "word", count: 10).joined(separator: " ") + "."
        let long = Array(repeating: sentence, count: 20).joined(separator: " ")
        let result = sanitizer.sanitize(long)
        XCTAssertLessThanOrEqual(result.wordCount, SpokenTextSanitizer.maxWords)
        XCTAssertTrue(result.text.hasSuffix("."), "must end on a complete sentence")
    }

    /// Deliberate: text with no sentence structure is spoken whole rather than cut.
    /// Clipping mid-clause is the one outcome that is never acceptable in speech,
    /// because the listener cannot go back and read the rest.
    func testUnpunctuatedTextIsSpokenWholeRatherThanCut() throws {
        let blob = Array(repeating: "word", count: SpokenTextSanitizer.maxWords * 3).joined(separator: " ")
        let result = sanitizer.sanitize(blob)
        XCTAssertEqual(result.text, blob)
        XCTAssertFalse(result.text.contains("…"))
    }

    /// Pass an explicit budget so this tests the clamping behaviour rather than
    /// whatever `maxWords` currently happens to be — the budget has changed three
    /// times as the spoken format evolved, and each time it silently broke this.
    func testClampPrefersASentenceBoundary() throws {
        let text = (Array(repeating: "alpha", count: 20).joined(separator: " "))
            + ". " + (Array(repeating: "beta", count: 40).joined(separator: " "))
        let clamped = SpokenTextSanitizer.clamp(text, maxWords: 30)
        XCTAssertTrue(clamped.hasSuffix("."), "should stop at the sentence break, not mid-clause")
        XCTAssertFalse(clamped.contains("beta"))
    }

    /// A single over-long sentence is spoken in full rather than clipped. Half a
    /// warning is worse than a long one — the listener cannot re-read it.
    func testOverlongSingleSentenceIsKeptWholeNotCut() throws {
        let text = Array(repeating: "gamma", count: 80).joined(separator: " ") + "."
        let clamped = SpokenTextSanitizer.clamp(text, maxWords: 30)
        XCTAssertEqual(clamped, text)
        XCTAssertFalse(clamped.contains("…"))
    }

    func testClampNeverEmitsAnEllipsis() throws {
        for count in [31, 45, 60, 120] {
            let text = (0..<count).map { "w\($0)" }.joined(separator: " ")
            XCTAssertFalse(SpokenTextSanitizer.clamp(text, maxWords: 30).contains("…"))
        }
    }

    func testClampDropsWholeTrailingSentences() throws {
        let text = "First sentence here. Second sentence here. " + Array(repeating: "tail", count: 60).joined(separator: " ") + "."
        let clamped = SpokenTextSanitizer.clamp(text, maxWords: 12)
        XCTAssertEqual(clamped, "First sentence here. Second sentence here.")
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
        let brief = try await provider.brief(for: request)
        XCTAssertLessThanOrEqual(
            sanitizer.sanitize(brief.spokenText()).wordCount, SpokenTextSanitizer.maxWords)
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
            func brief(for request: SummaryRequest) async throws -> SessionBrief {
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

// MARK: - Brief assembly

extension SanitizerTests {
    /// The spoken line must always name the session first. Out of context,
    /// "the fix has never run in the deployed pipeline" is unusable.
    func testSpokenLineLeadsWithTopic() {
        let brief = SessionBrief(
            topic: "Merge tag validation",
            happened: "three-part fix outlined",
            nextStep: "start with the token family")
        XCTAssertTrue(brief.spokenText().hasPrefix("Merge tag validation."))
    }

    /// A question blocks progress, so it outranks a proposed next step.
    func testQuestionOutranksNextStep() {
        let brief = SessionBrief(
            topic: "Export refactor",
            happened: "tests pass",
            nextStep: "deploy to staging",
            question: "Should I run the migration first?")
        let spoken = brief.spokenText()
        XCTAssertTrue(spoken.contains("Should I run the migration first?"))
        XCTAssertFalse(spoken.contains("deploy to staging"))
    }

    /// A PR reaches the summary only by way of the session having talked about it.
    /// Nothing appends one from a lookup, so a merged-months-ago PR whose branch is
    /// still checked out can no longer be announced as though it were news.
    func testNothingAppendsAPullRequestTheSessionDidNotMention() {
        let quiet = SessionBrief(topic: "Footer flag", happened: "migration written",
                                 branch: "feat/canonical-footer")
        XCTAssertFalse(quiet.spokenText().lowercased().contains("pull request"))

        let spoke = SessionBrief(
            topic: "Footer flag", happened: "migration written",
            recap: "Footer flag is wired and PR 2258 is up.", proposal: "Merge it?")
        XCTAssertTrue(spoke.spokenText().contains("PR 2258"),
                      "what the session itself said still comes through verbatim")
    }

    func testCardCarriesEveryFieldThatExists() {
        let brief = SessionBrief(
            topic: "T", goal: "G", happened: "H", nextStep: "N", question: "Q?", risk: "R",
            branch: "feature/x")
        let keys = brief.cardLines().map(\.0)
        XCTAssertEqual(keys, ["topic", "goal", "happened", "question", "next", "risk", "branch"])
    }
}
