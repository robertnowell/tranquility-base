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
        XCTAssertTrue(note.hasSuffix(HeardContext.closer))
    }

    /// A turn with nothing spoken has nothing to quote: the reply goes bare,
    /// byte-identical to before the note existed.
    func testNothingSpokenMeansNoNote() {
        XCTAssertNil(HeardContext.note(recap: nil, proposal: nil))
        XCTAssertNil(HeardContext.note(recap: "", proposal: "  \n"))
        XCTAssertEqual(HeardContext.compose(note: nil, message: "go ahead"), "go ahead")
    }

    /// Either half alone is still what was heard.
    func testOneHalfIsEnough() throws {
        let recapOnly = try XCTUnwrap(HeardContext.note(recap: "Shipped and tests green.", proposal: nil))
        XCTAssertTrue(recapOnly.contains("\u{201C}Shipped and tests green.\u{201D}"))
        let proposalOnly = try XCTUnwrap(HeardContext.note(recap: nil, proposal: "Proceed?"))
        XCTAssertTrue(proposalOnly.contains("\u{201C}Proceed?\u{201D}"))
    }

    /// What they heard, then what they said (ruled 13 Sep): the note leads as
    /// its own paragraph and the tray's message follows whole. The undo
    /// window shows exactly this string, in this order.
    func testTheNoteLeadsTheMessage() throws {
        let note = try XCTUnwrap(HeardContext.note(recap: "r", proposal: "p"))
        let composed = HeardContext.compose(note: note, message: "\"/a/shot.png\"\n\ngo ahead")
        XCTAssertTrue(composed.hasPrefix(note + "\n\n\"/a/shot.png\""))
        XCTAssertTrue(composed.hasSuffix("\n\ngo ahead"))
        XCTAssertEqual(HeardContext.compose(note: note, message: ""), note)
    }
}
