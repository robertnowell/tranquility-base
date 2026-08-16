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

    /// The written header wins when present, and the derived header is the
    /// floor: a turn without one renders exactly as before (v11).
    func testTheWrittenHeadlineOutranksTheTopic() {
        let written = HomeBase.Turn(at: Date(timeIntervalSince1970: 1_000_600),
                                    topic: "permission validation",
                                    happened: "Measured it.",
                                    headline: "Input Monitoring is required after all",
                                    deck: "Accessibility alone fails. Cleanup is irreversible.")
        let html = HomeBase.render(model(turns: [written, turn(1)]))
        XCTAssertTrue(html.contains("<h1>Input Monitoring is required after all</h1>"))
        XCTAssertTrue(html.contains("Accessibility alone fails. Cleanup is irreversible."))
        // The older, unwritten turn keeps its derived row header.
        XCTAssertTrue(html.contains("<h3>the poller</h3>"))
        let bare = HomeBase.render(model(turns: [turn(1)]))
        XCTAssertTrue(bare.contains("<h1>the poller</h1>"))
    }

    /// The deck joins two stored sentences; the join supplies the full stop
    /// the first field is missing, and keeps one it already has.
    func testTheDeckJoinTerminatesItsFirstSentence() {
        let jammed = HomeBase.Turn(at: Date(timeIntervalSince1970: 1_000_600),
                                   topic: "hub visibility",
                                   happened: "four bugs were fixed and merged to production",
                                   question: "Proceed with the page review?")
        let html = HomeBase.render(model(turns: [jammed]))
        XCTAssertTrue(html.contains("merged to production. Proceed with the page review?"))
        let punctuated = HomeBase.Turn(at: Date(timeIntervalSince1970: 1_000_600),
                                       topic: "hub visibility",
                                       happened: "It shipped!",
                                       question: "Review it?")
        let html2 = HomeBase.render(model(turns: [punctuated]))
        XCTAssertTrue(html2.contains("It shipped! Review it?"))
    }

    /// Site furniture is what repeats. One title cannot say which half is the
    /// brand; a list can.
    func testTheSharedAffixIsStrippedFromPageTitles() {
        let leading = HomeBase.strippingSharedAffix([
            "Tranquility Base — roadmap ahead",
            "Tranquility Base — Console palette experiments",
            "Kopi — the whole brief"])
        XCTAssertEqual(leading, ["roadmap ahead", "Console palette experiments",
                                 "Kopi — the whole brief"])

        let trailing = HomeBase.strippingSharedAffix([
            "The capture strip ruling — Tranquility Base",
            "Issue triage — Tranquility Base"])
        XCTAssertEqual(trailing, ["The capture strip ruling", "Issue triage"])

        // One page proves nothing about furniture, so nothing is stripped.
        XCTAssertEqual(HomeBase.strippingSharedAffix(["Tranquility Base — roadmap ahead"]),
                       ["Tranquility Base — roadmap ahead"])
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

    /// The open question is the reason to read the page, so it sits in the deck
    /// — in the sentence, not behind a label. The label it used to wear
    /// ("WAITING ON YOU") is the device this header was rebuilt to remove.
    func testTheHeaderCarriesTheOpenQuestion() {
        let html = HomeBase.render(model(turns: [turn(1)]))
        XCTAssertTrue(html.contains("Go?"))
        XCTAssertFalse(html.contains("WAITING ON YOU"))
        XCTAssertFalse(html.lowercased().contains("where this stands"))
    }

    /// The byline is the one place metadata belongs, and it is prose: the
    /// agent's name, where it works, when it last moved. Not a strip of counts.
    func testTheBylineIsPlainLanguage() {
        let html = HomeBase.render(model(turns: [turn(1)]))
        XCTAssertTrue(html.contains("Agent tranquility base discuss"))
        XCTAssertTrue(html.contains("working in tranquility-base"))
        XCTAssertTrue(html.contains("last moved"))
    }

    /// A count belongs over the thing it counts, where the list already proves
    /// it — never in a strip at the top restating what is visible below.
    func testTheCountSitsWithThePagesAndNotInTheHeader() {
        let pages = [ArtifactStore.Page(path: "/tmp/a/index.html", at: Date()),
                     ArtifactStore.Page(path: "/tmp/b/index.html", at: Date())]
        let html = HomeBase.render(model(turns: [turn(1)], pages: pages))
        let heading = html.range(of: "What it has made")!
        let count = html.range(of: "2 pages")!
        XCTAssertTrue(count.lowerBound > heading.lowerBound)
        // And nothing of the sort above the fold.
        let byline = html.range(of: "class=\"byline\"")!
        XCTAssertTrue(count.lowerBound > byline.lowerBound)
        XCTAssertTrue(HomeBase.render(model(turns: [turn(1)], pages: [pages[0]]))
            .contains("1 page."))
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
