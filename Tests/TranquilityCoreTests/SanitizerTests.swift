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

    /// The sanitizer no longer shortens anything (ruled 08 Aug). Length belongs to
    /// the SUMMARIZER, which clamps the brief's own sections — so a short brief is
    /// short on the card and short in the ear, together. Clamping here shortened
    /// only the audio, which left the card long and the voice truncated.
    func testTheSanitizerNeverShortensWhatItIsGiven() throws {
        let sentence = Array(repeating: "word", count: 10).joined(separator: " ") + "."
        let long = Array(repeating: sentence, count: 20).joined(separator: " ")
        let result = sanitizer.sanitize(long)
        XCTAssertEqual(result.wordCount, 200, "200 words in, 200 words out")
        XCTAssertEqual(result.text, result.displayText,
                       "nothing redacted here, so the projections are identical")
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

// MARK: - Two projections of one sequence
//
// The display/speech split. These are the tests that would catch the failure
// this design exists to make impossible: the two forms drifting apart, and the
// highlight cursor landing in the wrong place because of it.

extension SanitizerTests {
    /// The name survives for the eye and is genericised only for the ear.
    func testDisplayKeepsTheNameThatSpeechGenericises() {
        let result = sanitizer.sanitize("The table carries dispatchAttempts today.")
        XCTAssertEqual(result.text, "The table carries a variable today.")
        XCTAssertEqual(result.displayText, "The table carries dispatchAttempts today.")
    }

    /// Verbatim stretches are character-identical in both forms, so the cursor
    /// maps exactly — no drift, no arithmetic.
    func testCursorIsExactBeforeAnyRedaction() {
        let result = sanitizer.sanitize("The table carries dispatchAttempts today.")
        for index in 0..."The table carries ".count {
            XCTAssertEqual(result.displayIndex(forSpoken: index), index)
        }
    }

    /// An entity is atomic to a reader: the whole name lights up as soon as its
    /// spoken stand-in begins, rather than a proportion of it.
    func testCursorLightsTheWholeNameOnceItsSpokenFormBegins() {
        let result = sanitizer.sanitize("The table carries dispatchAttempts today.")
        let nameStart = "The table carries ".count
        let nameEnd = nameStart + "dispatchAttempts".count
        // One character into "a variable" — the whole name is already lit.
        XCTAssertEqual(result.displayIndex(forSpoken: nameStart + 1), nameEnd)
        // And it does not overshoot into the text that follows.
        XCTAssertEqual(result.displayIndex(forSpoken: nameStart + "a variable".count), nameEnd)
    }

    /// The cursor never runs backwards or past either end, whatever the input —
    /// a monotone prefix is the whole contract the panel relies on.
    func testCursorIsMonotoneAndInBounds() {
        let result = sanitizer.sanitize(
            "Schema has no column on brand_products; it has syncedAt, priceCents "
            + "and compareAtPriceCents as fields, edited in /Users/x/app/main.swift.")
        var previous = 0
        for index in 0...(result.text.count + 5) {
            let mapped = result.displayIndex(forSpoken: index)
            XCTAssertGreaterThanOrEqual(mapped, previous, "cursor went backwards at \(index)")
            XCTAssertLessThanOrEqual(mapped, result.displayText.count)
            previous = mapped
        }
    }

    /// The reason the collapse is safe: the listener hears the phrase once, and
    /// the reader still gets every name that was collapsed.
    func testRepeatedRedactionsCollapseForSpeechButNotForReading() {
        let result = sanitizer.sanitize(
            "Table carries audioPath, audioBytes, transcriptText, dispatchAttempts today.")
        XCTAssertEqual(result.text, "Table carries a variable today.")
        for name in ["audioPath", "audioBytes", "transcriptText", "dispatchAttempts"] {
            XCTAssertTrue(result.displayText.contains(name), "\(name) missing from the card")
        }
    }

    /// Clean text has one projection, not two — nothing to get out of step.
    func testCleanTextHasIdenticalProjections() {
        let input = "Export refactor is done and tests pass."
        let result = sanitizer.sanitize(input)
        XCTAssertEqual(result.text, result.displayText)
        XCTAssertEqual(result.text, input)
    }

    /// The callsign is attribution: it is heard AND seen, and it moves every
    /// other index with it rather than being pasted on afterwards.
    func testCallsignJoinsBothProjections() {
        let base = sanitizer.sanitize("carries dispatchAttempts today.")
        let hailed = sanitizer.applyingCallsign("promotions", strippingLabels: [], to: base)
        XCTAssertTrue(hailed.text.hasPrefix("promotions: "))
        XCTAssertTrue(hailed.displayText.hasPrefix("promotions: "))
        XCTAssertTrue(hailed.displayText.contains("dispatchAttempts"))
        XCTAssertEqual(hailed.displayIndex(forSpoken: 0), 0)
    }

    /// The invariant that replaced the word clamp (ruled 08 Aug): the voice covers
    /// everything the card shows. They still differ in CONTENT — `read_products`
    /// shown, "a variable" said — but never in coverage.
    ///
    /// The clamp truncated the spoken projection and left the displayed one whole,
    /// so a brief over budget was deterministically half-spoken: 198 characters of
    /// audio against a 373-character card, ending at a sentence boundary so it
    /// sounded like a finished thought rather than a fault.
    func testTheVoiceReachesTheEndOfWhatTheCardShows() {
        let sentence = Array(repeating: "word", count: 12).joined(separator: " ") + "."
        let long = Array(repeating: sentence, count: 8).joined(separator: " ")
        for text in [long, Self.findingsThatUsedToBeCutInHalf] {
            let result = sanitizer.sanitize(text)
            XCTAssertEqual(result.displayIndex(forSpoken: result.text.count),
                           result.displayText.count,
                           "the voice must reach the end of the displayed text")
        }
    }

    /// The exact FINDINGS rung from the incident (app.log 08 Aug 23:30:04), where
    /// ElevenLabs was handed 198 characters for a 373-character card.
    static let findingsThatUsedToBeCutInHalf = """
        Hero brief fully formed and costed thirty-five thousand tokens across \
        plan, art-direction-brief, and hero-description stages — all discarded by \
        fixed-layout constraint. No image-generation step ran. Neighbor-color \
        guidance is starved: sibling sections author in parallel, each seeing only \
        one real color in context; the rest are colorless stubs, forcing the model \
        to guess.
        """

    func testTheIncidentTextIsNoLongerHalfSpoken() {
        let result = sanitizer.sanitize(Self.findingsThatUsedToBeCutInHalf)
        XCTAssertEqual(result.text.count, result.displayText.count,
                       "no redactions here, so the two projections must be identical")
        XCTAssertTrue(result.text.hasSuffix("forcing the model to guess."),
                      "the last sentence used to be dropped from the audio")
    }

    /// End to end: what the store and the card keep is what the session said;
    /// only the voice gets the generic version.
    func testBriefKeepsTheNamesWhileOnlySpeechGenericisesThem() async {
        struct Fixed: SummaryProvider {
            let name = "fixed"
            let isConfigured = true
            func brief(for request: SummaryRequest) async throws -> SessionBrief {
                SessionBrief(topic: "Utterances", happened: "columns checked",
                             recap: "Table carries dispatchAttempts.", proposal: "Merge it?")
            }
        }
        let summary = await SummarizerChain(providers: [Fixed()]).summarize(
            SummaryRequest(lastAssistantMessage: "table carries dispatchAttempts",
                           projectLabel: "tranquility-base"))
        XCTAssertEqual(summary.brief.recap, "Table carries dispatchAttempts.")
        XCTAssertTrue(summary.spoken.text.contains("a variable"), summary.spoken.text)
        XCTAssertFalse(summary.spoken.text.contains("dispatchAttempts"))
        XCTAssertTrue(summary.spoken.displayText.contains("dispatchAttempts"))
    }
}
