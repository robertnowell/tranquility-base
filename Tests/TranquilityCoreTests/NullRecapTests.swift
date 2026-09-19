import XCTest
@testable import TranquilityCore

/// A null recap is what the prompt permits for a turn that concludes nothing,
/// and it used to send the turn to the floor (issue #509). The Gateway's
/// brief.ts applies the same order; this test and its TypeScript twin in the
/// gateway repo (`a null recap is not a failure`) must agree.
final class NullRecapTests: XCTestCase {

    private func request(_ message: String) -> SummaryRequest {
        SummaryRequest(lastAssistantMessage: message, projectLabel: "Kopi", hookEvent: .stop)
    }

    func testTheNextBestLineStandsInForANullRecap() throws {
        let nulls = #"{"spoken":{"recap":null,"proposal":"Pick one. Go?","goal":null},"written":{"headline":null,"deck":null}}"#
        let stood = try AnthropicSummaryProvider.parse(nulls, request: request("ignored"))
        XCTAssertEqual(stood.happened, "Pick one. Go?")
        // The stand-in is the recap too, so the spoken line is the authored
        // path and never "topic. happened." with both the same sentence.
        XCTAssertEqual(stood.recap, "Pick one. Go?")
        XCTAssertEqual(stood.spokenText(), "Pick one. Go?")
        let deckOnly = try AnthropicSummaryProvider.parse(#"{"spoken":{"recap":null},"written":{"deck":"Only a deck."}}"#, request: request("x"))
        XCTAssertEqual(deckOnly.spokenText(), "Only a deck.")

        let onlyHeadline = #"{"spoken":{"recap":null},"written":{"headline":"What OpenCode is","deck":"An open agent."}}"#
        let b = try AnthropicSummaryProvider.parse(onlyHeadline, request: request("ignored"))
        XCTAssertEqual(b.happened, "What OpenCode is"); XCTAssertEqual(b.topic, "What OpenCode is")

        let nothing = #"{"spoken":{"recap":null},"written":{}}"#
        XCTAssertEqual(try AnthropicSummaryProvider.parse(nothing, request: request("OpenCode is an open-source coding agent. It runs locally.")).happened,
                       "OpenCode is an open-source coding agent.")
        XCTAssertThrowsError(try AnthropicSummaryProvider.parse(nothing, request: request("   ")))
    }

    func testTheFirstSentenceIsOneSentenceOrOneLineAndNeverMoreThan200Characters() {
        XCTAssertEqual(AnthropicSummaryProvider.firstSentence("Done. Next?"), "Done.")
        XCTAssertEqual(AnthropicSummaryProvider.firstSentence("v1.2 shipped! Then more"), "v1.2 shipped!")
        XCTAssertEqual(AnthropicSummaryProvider.firstSentence("No punctuation here\nsecond line"), "No punctuation here")
        XCTAssertEqual(AnthropicSummaryProvider.firstSentence(String(repeating: "x", count: 300))?.count, 200)
        XCTAssertNil(AnthropicSummaryProvider.firstSentence("  \n "))
    }
}
