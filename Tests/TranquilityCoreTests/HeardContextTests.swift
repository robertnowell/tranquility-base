import XCTest
@testable import TranquilityCore

/// The note that tells an agent what its user was answering (`HeardContext`).
/// Pure functions; the Coordinator round trip is in CoordinatorTests.
final class HeardContextTests: XCTestCase {

    func testANoteQuotesRecapThenProposal() throws {
        let note = try XCTUnwrap(HeardContext.note(
            recap: "Kopi: the footer bug is fixed.",
            proposal: "Ship it to production. Go?"))
        XCTAssertEqual(note, "[assistant]: Kopi: the footer bug is fixed. Ship it to production. Go?")
    }

    /// A turn with nothing spoken has nothing to quote: the reply goes bare,
    /// byte-identical to before the note existed.
    func testNothingSpokenMeansNoNote() {
        XCTAssertNil(HeardContext.note(recap: nil, proposal: nil))
        XCTAssertNil(HeardContext.note(recap: "", proposal: "  \n"))
        XCTAssertEqual(HeardContext.compose(note: nil, message: "go ahead"), "go ahead")
    }

    /// The rungs the user pulled join the paragraph after the announcement,
    /// in the order given, as one line (ruled 13 Sep).
    func testPulledRungsJoinTheParagraph() throws {
        let note = try XCTUnwrap(HeardContext.note(
            recap: "Kopi: fixed.", proposal: "Ship? Go?",
            rungs: ["We are shipping the footer fix for Kopi.", "Two blockers, both closed."]))
        XCTAssertEqual(note,
            "[assistant]: Kopi: fixed. Ship? Go? We are shipping the footer fix for Kopi. "
            + "Two blockers, both closed.")
        XCTAssertFalse(note.contains("\n"))
    }

    /// Either half alone is still what was heard.
    func testOneHalfIsEnough() throws {
        let recapOnly = try XCTUnwrap(HeardContext.note(recap: "Shipped and tests green.", proposal: nil))
        XCTAssertEqual(recapOnly, "[assistant]: Shipped and tests green.")
        let proposalOnly = try XCTUnwrap(HeardContext.note(recap: nil, proposal: "Proceed?"))
        XCTAssertEqual(proposalOnly, "[assistant]: Proceed?")
    }

    /// What they heard, then what they said (ruled 13 Sep), two labels and
    /// nothing else. The tray's message follows whole under its label. The
    /// undo window shows exactly this string, in this order.
    func testTheNoteLeadsTheLabelledMessage() throws {
        let note = try XCTUnwrap(HeardContext.note(recap: "r", proposal: "p"))
        let composed = HeardContext.compose(note: note, message: "\"/a/shot.png\"\n\ngo ahead")
        XCTAssertEqual(composed, "[assistant]: r p\n\n[user]: \"/a/shot.png\"\n\ngo ahead")
        XCTAssertEqual(HeardContext.compose(note: note, message: ""), note)
    }
}
