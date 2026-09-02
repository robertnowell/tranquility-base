import XCTest
@testable import TranquilityCore

/// The duplicate-footer check, which was counting the wrong thing.
final class StampedFooterCountTests: XCTestCase {

    private let stamp = #"<footer data-tb-agent="0d04e845" style="x">made by</footer>"#

    func testOneFooterIsOne() {
        XCTAssertEqual(HubIntegrity.stampedFooters(in: "<body>\(stamp)</body>"), 1)
    }

    /// The real defect: a page that inherited an exemplar's footer and added
    /// its own, naming two different sessions.
    func testTwoStampsAreCaught() {
        let two = stamp + #"<footer data-tb-agent="8373bb2c" style="x">and me</footer>"#
        XCTAssertEqual(HubIntegrity.stampedFooters(in: two), 2)
    }

    /// A page ABOUT the footer quotes the marker in its prose. Four pages were
    /// flagged this way on 02 Sep and every one of them was clean.
    func testProseThatMentionsTheMarkerIsNotAFooter() {
        let page = "<p>The stamp carries <code>data-tb-agent</code>, by design.</p>" + stamp
        XCTAssertEqual(HubIntegrity.stampedFooters(in: page), 1)
    }

    /// The hub-replay prototype renders twenty sample hubs, each with a discuss
    /// link and no stamp. One agent owns that page, not twenty.
    func testDiscussLinksWithoutAStampAreNotOwnership() {
        let mock = #"<footer style="x"><a href="tranquilitybase://discuss?session=x">Discuss</a></footer>"#
        XCTAssertEqual(HubIntegrity.stampedFooters(in: String(repeating: mock, count: 20)), 0)
    }
}
