import XCTest
@testable import TranquilityCore

/// The chip text for one staged fragment: filename for paths, a cut first
/// line plus the hidden count for prose.
final class FragmentPreviewTests: XCTestCase {

    func testPathsKeepTheFilename() {
        XCTAssertEqual(FragmentPreview.preview("/tmp/shots/one file.png"), "one file.png")
        XCTAssertEqual(FragmentPreview.preview(AttachmentTray.quoted("/tmp/a \"b\".png")),
                       "a \"b\".png")
    }

    func testShortProseIsShownWhole() {
        XCTAssertEqual(FragmentPreview.preview("ship it on Tuesday"), "ship it on Tuesday")
        let exactly = String(repeating: "x", count: FragmentPreview.defaultLimit)
        XCTAssertEqual(FragmentPreview.preview(exactly), exactly)
    }

    func testALongFirstLineIsCutAndCounted() {
        let text = String(repeating: "word ", count: 40).trimmingCharacters(in: .whitespaces)
        let preview = FragmentPreview.preview(text)
        XCTAssertTrue(preview.hasPrefix(String(text.prefix(48)) + "\u{2026}"), preview)
        XCTAssertTrue(preview.hasSuffix("+\(text.count - 48) chars"), preview)
    }

    /// A short first line over more paragraphs: the count is of everything
    /// not shown, not of the first line's leftovers.
    func testHiddenCountCoversTheWholeFragment() {
        let text = "Please continue the work of \u{201C}search indexing\u{201D}.\n\nMore context"
        XCTAssertEqual(FragmentPreview.preview(text),
                       "Please continue the work of \u{201C}search indexing\u{201D}. +14 chars")
    }

    func testLeadingBlankLinesAreSkipped() {
        XCTAssertEqual(FragmentPreview.preview("\n\n  hello  \n"), "hello")
    }

    func testThousandsAreGrouped() {
        XCTAssertEqual(FragmentPreview.grouped(7), "7")
        XCTAssertEqual(FragmentPreview.grouped(1234), "1,234")
        XCTAssertEqual(FragmentPreview.grouped(1234567), "1,234,567")
        let big = String(repeating: "a", count: 2000)
        XCTAssertTrue(FragmentPreview.preview(big).hasSuffix("+1,952 chars"))
    }
}
