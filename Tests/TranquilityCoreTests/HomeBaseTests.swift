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
                       pages: [ArtifactStore.Page] = []) -> HomeBase.Model {
        HomeBase.Model(sessionId: "489b4804-8d64-4a91-a63c-5e493141c772",
                       title: title, callsign: callsign,
                       cwd: "/Users/x/Projects/tranquility-base",
                       goal: "Make the button work.", turns: turns, pages: pages)
    }

    /// A briefing, not a log. Everything past the cap is in the transcript,
    /// which is what the deep link is for.
    func testTheTurnCapHolds() {
        let html = HomeBase.render(model(turns: (1...60).map { turn($0) }))
        XCTAssertEqual(html.components(separatedBy: "<li class=").count - 1,
                       HomeBase.fullTurns + HomeBase.lineTurns)
        XCTAssertTrue(html.contains("Before that — 51 turns."))
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
        XCTAssertFalse(html.contains("Before that"))
    }

    /// A risk is the one field that survives every tier. An exception flattened
    /// into a summary reads as "nothing here" and gets skipped.
    func testARiskSurvivesDownsampling() {
        var turns = (1...9).map { turn($0) }
        turns[2] = HomeBase.Turn(at: Date(timeIntervalSince1970: 1_000_000),
                                 topic: "the migration", happened: "ran it",
                                 risk: "0066 has to run before deploy")
        let html = HomeBase.render(model(turns: turns))
        XCTAssertTrue(html.contains("0066 has to run before deploy"))
    }

    /// The header is the only block allowed to show judgment, and it must always
    /// name what the agent is waiting on when it is waiting on something.
    func testTheHeaderCarriesTheOpenQuestion() {
        let html = HomeBase.render(model(turns: [turn(1)]))
        XCTAssertTrue(html.contains("Waiting on you"))
        XCTAssertTrue(html.contains("Go?"))
    }

    /// A line continuation inside a Swift multiline string carries the next
    /// line's indentation with it, which is how "5   pages" reached the header.
    func testTheHeaderCountIsSingleSpaced() {
        let pages = [ArtifactStore.Page(path: "/tmp/a/index.html", at: Date()),
                     ArtifactStore.Page(path: "/tmp/b/index.html", at: Date())]
        XCTAssertTrue(HomeBase.render(model(turns: [turn(1)], pages: pages))
            .contains("2 pages &middot;"))
        XCTAssertTrue(HomeBase.render(model(turns: [turn(1)], pages: [pages[0]]))
            .contains("1 page &middot;"))
    }

    func testPagesAreListedNewestFirst() {
        let pages = [
            ArtifactStore.Page(path: "/tmp/old/index.html",
                               at: Date(timeIntervalSince1970: 1_000_000)),
            ArtifactStore.Page(path: "/tmp/new/index.html",
                               at: Date(timeIntervalSince1970: 2_000_000)),
        ]
        let html = HomeBase.render(model(turns: [turn(1)], pages: pages))
        XCTAssertTrue(html.range(of: "/tmp/new/")!.lowerBound
                      < html.range(of: "/tmp/old/")!.lowerBound)
        // The directory names the page; "index.html" names nothing.
        XCTAssertTrue(html.contains(">new<"))
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

    /// The URL is keyed on the id alone. A callsign is minted at the agent's
    /// first summary, so a name in the path means every hub written before that
    /// moment lives at a different URL — and every link into it rots.
    func testTheSlugIsTheIdAndNothingElse() {
        XCTAssertEqual(HomeBase.slug(for: model(turns: [], callsign: "a/b: c's  d")),
                       "489b4804")
        XCTAssertEqual(HomeBase.slug(for: model(turns: [], callsign: nil)), "489b4804")
    }

    /// An agent that has made nothing gets no section at all, rather than an
    /// empty one — most agents never write a page, and a heading over nothing
    /// is a promise the hub does not keep.
    func testAnAgentWithNoPagesGetsNoPagesSection() {
        XCTAssertFalse(HomeBase.render(model(turns: [turn(1)]))
            .contains("Pages this agent made"))
    }
}
