import XCTest
@testable import TranquilityCore

/// The note that tells an agent what its user was answering (`HeardContext`).
/// Pure functions; the Coordinator round trip is in CoordinatorTests.
final class HeardContextTests: XCTestCase {

    func testANoteQuotesRecapThenProposal() throws {
        let note = try XCTUnwrap(HeardContext.note(
            recap: "Kopi: the footer bug is fixed.",
            proposal: "Ship it to production. Go?"))
        XCTAssertTrue(note.hasPrefix(HeardContext.opener))
        XCTAssertTrue(note.contains(
            "\u{201C}Kopi: the footer bug is fixed. Ship it to production. Go?\u{201D}"))
        XCTAssertTrue(note.hasSuffix("]"))
    }

    /// A turn with nothing spoken has nothing to quote: the reply goes bare,
    /// byte-identical to before the note existed.
    func testNothingSpokenMeansNoNote() {
        XCTAssertNil(HeardContext.note(recap: nil, proposal: nil))
        XCTAssertNil(HeardContext.note(recap: "", proposal: "  \n"))
        XCTAssertEqual(HeardContext.compose(message: "go ahead", note: nil), "go ahead")
    }

    /// Either half alone is still what was heard.
    func testOneHalfIsEnough() throws {
        let recapOnly = try XCTUnwrap(HeardContext.note(recap: "Shipped and tests green.", proposal: nil))
        XCTAssertTrue(recapOnly.contains("\u{201C}Shipped and tests green.\u{201D}"))
        let proposalOnly = try XCTUnwrap(HeardContext.note(recap: nil, proposal: "Proceed?"))
        XCTAssertTrue(proposalOnly.contains("\u{201C}Proceed?\u{201D}"))
    }

    /// The user's words lead; the note trails as its own paragraph. The undo
    /// window shows exactly this string, so the words being checked stay
    /// first on the card.
    func testTheNoteTrailsTheMessage() throws {
        let note = try XCTUnwrap(HeardContext.note(recap: "r", proposal: "p"))
        let composed = HeardContext.compose(message: "\"/a/shot.png\"\n\ngo ahead", note: note)
        XCTAssertTrue(composed.hasPrefix("\"/a/shot.png\"\n\ngo ahead\n\n["))
        XCTAssertTrue(composed.hasSuffix(note))
        XCTAssertEqual(HeardContext.compose(message: "", note: note), note)
    }
}
