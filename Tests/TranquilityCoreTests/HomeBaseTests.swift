import XCTest
@testable import TranquilityCore

/// The page is a projection of the brief table, so the tests are about what it
/// must never do to that data: lose the cap, lose the escaping, or claim a
/// session is idle when it has simply never been summarized.
final class HomeBaseTests: XCTestCase {

    private func turn(_ n: Int, topic: String = "the poller") -> HomeBase.Turn {
        HomeBase.Turn(at: Date(timeIntervalSince1970: 1_000_000 + Double(n) * 600),
                      topic: topic, happened: "Finished turn \(n).",
                      nextStep: "Land it.", question: "Go?", risk: nil)
    }

    private func model(turns: [HomeBase.Turn], title: String? = "Add the discuss button",
                       callsign: String? = "tranquility base discuss",
                       artifact: String? = nil) -> HomeBase.Model {
        HomeBase.Model(sessionId: "489b4804-8d64-4a91-a63c-5e493141c772",
                       title: title, callsign: callsign,
                       cwd: "/Users/x/Projects/tranquility-base",
                       goal: "Make the button work.", turns: turns, artifact: artifact)
    }

    /// A briefing, not a log. Everything past the cap is in the transcript,
    /// which is what the deep link is for.
    func testTheTurnCapHolds() {
        let html = HomeBase.render(model(turns: (1...60).map { turn($0) }))
        XCTAssertEqual(html.components(separatedBy: "<li><div class=\"when\"").count - 1,
                       HomeBase.turnLimit)
        XCTAssertTrue(html.contains("Older turns (40) are in the transcript"))
    }

    /// Topics and goals are model-written and land in markup unescaped
    /// otherwise.
    func testModelWrittenTextIsEscaped() {
        let hostile = HomeBase.Turn(at: Date(timeIntervalSince1970: 1_000_000),
                                    topic: "<script>alert(1)</script>",
                                    happened: "a & b \"quoted\"")
        let html = HomeBase.render(model(turns: [hostile]))
        XCTAssertFalse(html.contains("<script>alert"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("a &amp; b"))
    }

    /// A session with no briefs still renders — the CLI declines to write it,
    /// but the renderer must not produce a broken page if anything else asks.
    func testTheEmptySessionSaysWhyItIsEmpty() {
        let html = HomeBase.render(model(turns: []))
        XCTAssertTrue(html.contains("Nothing summarized yet"))
        XCTAssertFalse(html.contains("Older turns"))
    }

    func testTheDoorCarriesTheSession() {
        let html = HomeBase.render(model(turns: [turn(1)]))
        XCTAssertTrue(html.contains(
            "tranquilitybase://discuss?session=489b4804-8d64-4a91-a63c-5e493141c772"))
    }

    /// Both names, always — they are different things and the page is where a
    /// reader reconciles them.
    func testBothNamesAppear() {
        let html = HomeBase.render(model(turns: [turn(1)]))
        XCTAssertTrue(html.contains("Add the discuss button"))
        XCTAssertTrue(html.contains("tranquility base discuss"))
    }

    /// The slug is a directory name; a callsign with punctuation must not
    /// invent path components.
    func testTheSlugIsOneSafeComponent() {
        let slug = HomeBase.slug(for: model(turns: [], callsign: "a/b: c's  d e f"))
        XCTAssertFalse(slug.contains("/"))
        XCTAssertFalse(slug.contains(":"))
        XCTAssertTrue(slug.hasSuffix("-489b4804"))
    }

    func testNoPageYetSaysSo() {
        XCTAssertTrue(HomeBase.render(model(turns: [turn(1)])).contains("no pages yet"))
        XCTAssertTrue(HomeBase.render(model(turns: [turn(1)], artifact: "/tmp/p.html"))
            .contains("p.html"))
    }
}
