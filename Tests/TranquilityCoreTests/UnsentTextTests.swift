import XCTest
@testable import TranquilityCore

/// Words the send path could not take are kept (29 Sep 2026).
///
/// Earned by a typed message that reached `submitTypedReply` in full and was
/// dropped by a guard, leaving nothing anywhere: the store's first record of a
/// reply is made after that guard, and the log line said "nothing typed and
/// nothing staged" — true of a different failure, misleading about this one.
final class UnsentTextTests: XCTestCase {

    override func setUp() {
        super.setUp()
        try? FileManager.default.removeItem(at: UnsentText.url)
    }

    /// The whole point: the words come back, verbatim.
    func testTheWordsComeBack() {
        UnsentText.keep("the hero backfill needs rerunning", for: "abc12345",
                        because: "the session is not one the store knows")
        let kept = UnsentText.all()
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.text, "the hero backfill needs rerunning")
        XCTAssertEqual(kept.first?.sessionId, "abc12345")
        XCTAssertEqual(kept.first?.reason, "the session is not one the store knows")
    }

    /// A multi-line message is ONE record, not several. Newlines are escaped on
    /// the way in and restored on the way out, or a paragraph would come back
    /// as unrelated fragments and the file would be unreadable.
    func testAMultiLineMessageSurvivesWhole() {
        let words = "first line\nsecond line\n\nfourth after a gap"
        UnsentText.keep(words, for: "abc12345", because: "gone")
        XCTAssertEqual(UnsentText.all().first?.text, words)
        XCTAssertEqual(UnsentText.all().count, 1, "one message, one record")
    }

    /// Appended, never rewritten: a second loss must not cost the first. That
    /// is the difference between a record and a most-recent-failure note.
    func testASecondLossDoesNotCostTheFirst() {
        UnsentText.keep("the first thing I said", for: "aaa", because: "gone")
        UnsentText.keep("the second thing I said", for: "bbb", because: "gone")
        let kept = UnsentText.all()
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(kept.first?.text, "the first thing I said", "oldest first")
        XCTAssertEqual(kept.last?.text, "the second thing I said")
    }

    /// An empty line is not a loss. Keeping it would fill the file with the
    /// ordinary case of pressing Return on nothing, and bury the real ones.
    func testNothingTypedIsNotKept() {
        UnsentText.keep("", for: "abc", because: "gone")
        UnsentText.keep("   \n  ", for: "abc", because: "gone")
        XCTAssertTrue(UnsentText.all().isEmpty)
    }

    /// A tab inside the message must not split the record, because the file is
    /// tab-separated and the text is the last field.
    func testATabInsideTheMessageDoesNotSplitTheRecord() {
        UnsentText.keep("before\tafter", for: "abc", because: "gone")
        let kept = UnsentText.all()
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.sessionId, "abc")
        XCTAssertTrue(kept.first?.text.contains("after") ?? false, kept.first?.text ?? "")
    }
}
