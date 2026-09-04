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
        // The h1 names the AGENT; the newest headline sits directly under it.
        // Titling a hub after its last event meant you learned what happened
        // before you learned whose page you were on (03 Sep).
        XCTAssertTrue(html.contains("<p class=\"latest\">Input Monitoring is required after all</p>"))
        XCTAssertFalse(html.contains("<h1>Input Monitoring is required after all</h1>"))
        XCTAssertTrue(html.contains("Accessibility alone fails. Cleanup is irreversible."))
        // The older, unwritten turn keeps its derived row header.
        XCTAssertTrue(html.contains("<h3>the poller</h3>"))
        let bare = HomeBase.render(model(turns: [turn(1)]))
        XCTAssertTrue(bare.contains("<p class=\"latest\">the poller</p>"))
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

    /// The project decides the palette, and only brands with recorded tokens
    /// have one. Everything else is the house editorial default, never a
    /// guess at an identity.
    func testTheProjectChoosesTheTheme() {
        XCTAssertEqual(HomeBase.Theme.forProject(cwd: "/Users/x/Projects/kopi").id, "kopi")
        XCTAssertEqual(HomeBase.Theme.forProject(cwd: "/Users/x/Projects/kopi-promotions").id, "kopi")
        XCTAssertEqual(HomeBase.Theme.forProject(cwd: "/Users/x/Projects/mirai-pitch").id, "mirai")
        XCTAssertEqual(HomeBase.Theme.forProject(cwd: "/Users/x/Projects/tranquility-base").id,
                       "editorial")
        XCTAssertEqual(HomeBase.Theme.forProject(cwd: nil).id, "editorial")
        // A brand designed for paper does not get a machine-darkened variant.
        XCTAssertFalse(HomeBase.Theme.kopi.hasDark)
        XCTAssertTrue(HomeBase.Theme.editorial.hasDark)
    }

    /// A nameplate that says the same thing twice reads as an unfilled
    /// template.
    func testTheNameplateDoesNotRepeatItself() {
        XCTAssertEqual(HomeBase.nameplate(brand: "Tranquility Base",
                                          project: "tranquility-base"),
                       "Tranquility Base")
        XCTAssertEqual(HomeBase.nameplate(brand: "Kopi", project: "promotions"),
                       "Kopi · promotions")
        XCTAssertEqual(HomeBase.nameplate(brand: "Kopi", project: "kopi-promotions"),
                       "Kopi · promotions")
        XCTAssertEqual(HomeBase.nameplate(brand: "Mirai", project: "kopi-mirai-pitch"),
                       "Mirai · kopi-mirai-pitch")
        XCTAssertEqual(HomeBase.nameplate(brand: "Kopi", project: nil), "Kopi")
    }

    /// The theme reaches the page: tokens, and the masthead the App Store
    /// brief established as the house shape (adopted 16 Aug).
    /// The favicon is a data URI in <head> and carries its own media query. Tests
    /// about the PAGE's styling have to look past it.
    static func strippingFavicon(_ html: String) -> String {
        guard let start = html.range(of: "<link rel=\"icon\""),
              let end = html.range(of: ">", range: start.upperBound..<html.endIndex)
        else { return html }
        return html.replacingCharacters(in: start.lowerBound..<end.upperBound, with: "")
    }

    func testTheThemeAndMastheadReachThePage() {
        let kopi = HomeBase.render(HomeBase.Model(
            sessionId: "489b4804-x", title: "A send", callsign: "promotions rebuild",
            cwd: "/Users/x/Projects/kopi-promotions", goal: nil,
            turns: [turn(1)], pages: []))
        XCTAssertTrue(kopi.contains("#ff6b4a"))        // Ink 1 punctuates
        XCTAssertTrue(kopi.contains("#1e3a52"))        // navy carries structure
        XCTAssertTrue(kopi.contains("Kopi · promotions"))
        // Scoped to the PAGE's own CSS. A light-only brand theme must not emit a
        // dark page variant -- which is what this asserts and still does -- but
        // the favicon carries its own `prefers-color-scheme` inside its data URI
        // to follow the TAB BAR, which is a different surface and not this
        // theme's business. A document-wide substring search conflated the two.
        XCTAssertFalse(HomeBaseTests.strippingFavicon(kopi).contains("prefers-color-scheme:dark"),
                       "a light-only theme must not style the page for dark mode")
        XCTAssertTrue(kopi.contains("class=\"plate\""))
        XCTAssertTrue(kopi.contains("class=\"kicker\""))

        let house = HomeBase.render(model(turns: [turn(1)]))
        // The accent is the agent's own ink now, so assert it is one of them
        // rather than restating which; the house structure ink is unchanged.
        XCTAssertTrue(HomeBase.Theme.agentInks.contains { house.contains("--accent:\($0)") })
        XCTAssertTrue(house.contains("--brand:#1a1a1a"))
        XCTAssertTrue(house.contains("prefers-color-scheme:dark"))
    }

    /// A page is filed under the turn that made it, and the newest turn
    /// prints the whole ladder — "what just happened" is the question a hub is
    /// opened to answer (ruled 16 Aug).
    func testEachTurnShowsTheWorkItMade() {
        let older = HomeBase.Turn(at: Date(timeIntervalSince1970: 1_000_000),
                                  topic: "the poller", happened: "Landed it.")
        let newest = HomeBase.Turn(at: Date(timeIntervalSince1970: 1_002_000),
                                   topic: "the report", happened: "Wrote it up.",
                                   nextStep: "Ship it.", question: "Go?",
                                   findings: "Twelve defects across four seams.",
                                   solution: "An alias index closes the family.",
                                   rationale: "Because collisions are undetectable today.")
        let duringNewest = ArtifactStore.Page(
            path: "/Users/x/Documents/deep-research/a/index.html",
            at: Date(timeIntervalSince1970: 1_001_500))
        let html = HomeBase.render(model(turns: [newest, older], pages: [duringNewest]))

        // The ladder, on the newest turn only.
        XCTAssertTrue(html.contains("Twelve defects across four seams."))
        XCTAssertTrue(html.contains("An alias index closes the family."))
        XCTAssertTrue(html.contains("Because collisions are undetectable today."))

        // The page sits inline, and no shelf is needed.
        XCTAssertTrue(html.contains("ul class=\"made\""))
        XCTAssertFalse(html.contains("Earlier pages"))

        // The work comes before any list of pages, always.
        let done = html.range(of: "What it has done")!
        let made = html.range(of: "ul class=\"made\"")!
        XCTAssertTrue(made.lowerBound > done.lowerBound)
    }

    /// A page whose turn has been compacted past the cap falls to the shelf,
    /// and the shelf sits BELOW the stack — older work never outranks the work
    /// you just did.
    func testCompactedPagesFallToTheShelfBelow() {
        // 20 turns: everything past the 3+6 cap is digest, so a page made
        // during turn 15 has no block to sit under.
        let turns = (1...20).reversed().map { turn($0) }   // newest first
        let ancient = ArtifactStore.Page(path: "/Users/x/Documents/old/index.html",
                                         at: turns[15].at)
        let html = HomeBase.render(model(turns: turns, pages: [ancient]))
        let done = html.range(of: "What it has done")!
        // "Earlier work", not "Earlier pages": the shelf holds pull requests
        // too since 18 Aug.
        let shelf = html.range(of: "Earlier work")!
        XCTAssertTrue(shelf.lowerBound > done.lowerBound)
    }

    /// The page declares its brand; the directory only guesses. A session
    /// fixing Tranquility Base from a promotions checkout was themed Kopi and
    /// titled "KOPI · PROMOTIONS" while every page it wrote said otherwise.
    func testTheDeclaredBrandBeatsTheDirectory() throws {
        let dir = NSTemporaryDirectory() + "tb-brand-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let page = dir + "/index.html"
        try """
        <html><head><meta name="intranet:brand" content="Tranquility Base"></head></html>
        """.write(toFile: page, atomically: true, encoding: .utf8)

        XCTAssertEqual(HomeBase.declaredBrand(
            pages: [ArtifactStore.Page(path: page, at: Date())]), "Tranquility Base")
        XCTAssertEqual(HomeBase.Theme.forBrand("Tranquility Base")?.id, "editorial")
        XCTAssertEqual(HomeBase.Theme.forBrand("Kopi")?.id, "kopi")
        XCTAssertNil(HomeBase.Theme.forBrand("U Vape"))
        // The directory still answers when nothing has been written yet.
        XCTAssertEqual(HomeBase.Theme.forProject(cwd: "/Users/x/Projects/promotions").id, "kopi")
    }

    /// A brand that sets in its own faces loads them from one shared local
    /// sheet: taking only the palette is the brand's colours on somebody
    /// else's type.
    func testABrandBringsItsOwnFaces() {
        XCTAssertEqual(HomeBase.Theme.kopi.fontSheet, "kopi.css")
        XCTAssertTrue(HomeBase.Theme.kopi.serif.contains("Bricolage Grotesque"))
        XCTAssertTrue(HomeBase.Theme.kopi.sans.contains("Plus Jakarta Sans"))
        // The house style names no face it cannot render.
        XCTAssertNil(HomeBase.Theme.editorial.fontSheet)

        // And the sheet is actually LOADED — naming the family without the
        // file renders system sans and claims the identity anyway, which is
        // what shipped for one deploy (16 Aug).
        let kopi = HomeBase.render(HomeBase.Model(
            sessionId: "25f7945a-x", title: "A send", callsign: nil,
            cwd: "/Users/x/Projects/kopi-promotions", goal: nil,
            turns: [turn(1)], pages: []))
        XCTAssertTrue(kopi.contains("hq-fonts/kopi.css"))
        XCTAssertTrue(kopi.contains("rel=\"stylesheet\""))
        XCTAssertFalse(HomeBase.render(model(turns: [turn(1)])).contains("hq-fonts"))
    }

    /// Every agent gets its own ink, derived from its id so it never changes
    /// and never needs storing. A brand keeps its own accent: Kopi's orange is
    /// the identity, and an agent is not one.
    func testEachAgentGetsItsOwnInk() {
        let a = HomeBase.Theme.editorial.forAgent(sessionId: "489b4804-8d64-4a91")
        let b = HomeBase.Theme.editorial.forAgent(sessionId: "45525e92-d6a1-4a68")
        XCTAssertNotEqual(a.accent, b.accent)
        // Stable across calls, and across processes: no hashValue anywhere.
        XCTAssertEqual(a.accent,
                       HomeBase.Theme.editorial.forAgent(sessionId: "489b4804-8d64-4a91").accent)
        XCTAssertTrue(HomeBase.Theme.agentInks.contains(a.accent))
        // Only the accent moves; the house style is still the house style.
        XCTAssertEqual(a.bg, HomeBase.Theme.editorial.bg)
        XCTAssertEqual(a.brand, HomeBase.Theme.editorial.brand)
        // A brand theme is untouched.
        XCTAssertEqual(HomeBase.Theme.kopi.forAgent(sessionId: "489b4804").accent,
                       HomeBase.Theme.kopi.accent)
    }

    /// A published page says so and links the copy other people can open; the
    /// local file stays the primary link.
    func testAPublishedPageLinksItsPublicCopy() {
        let page = ArtifactStore.Page(
            path: "/Users/x/Documents/deep-research/2026-08-16-governance/index.html",
            at: Date(timeIntervalSince1970: 1_000_000))
        let html = HomeBase.pageItems(
            [page], e: HomeBase.escape,
            published: ["2026-08-16-governance": "https://example.test/2026-08-16-governance/"])
        XCTAssertTrue(html.contains("https://example.test/2026-08-16-governance/"))
        XCTAssertTrue(html.contains(">published</a>"))
        XCTAssertTrue(html.contains("file:///Users/x/Documents/deep-research"))
        // An unpublished page says nothing at all.
        XCTAssertFalse(HomeBase.pageItems([page], e: HomeBase.escape, published: [:])
            .contains("published"))
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

    /// The byline says WHO WROTE THIS in the two names a reader can act on:
    /// the session title the grid shows, and the id every log and link uses.
    /// The callsign is gone from it (ruled 16 Aug) — a spoken name, minted to
    /// be said once, named nothing the reader had ever seen.
    func testTheBylineNamesTheSession() {
        let html = HomeBase.render(model(turns: [turn(1)]))
        XCTAssertTrue(html.contains("Add the discuss button"))
        XCTAssertTrue(html.contains("session 489b4804"))
        XCTAssertTrue(html.contains("in tranquility-base"))
        XCTAssertTrue(html.contains("last moved"))
        XCTAssertFalse(html.contains("tranquility base discuss"))
    }

    /// The list speaks for itself (ruled 16 Aug, superseding "a count belongs
    /// over the thing it counts"). The subline counted what was visible one
    /// line below and explained what clicking a link does; the heading and the
    /// list are the whole section now.
    func testThePageListCarriesNoSubline() {
        let pages = [ArtifactStore.Page(path: "/tmp/a/index.html", at: Date()),
                     ArtifactStore.Page(path: "/tmp/b/index.html", at: Date())]
        let html = HomeBase.render(model(turns: [turn(1)], pages: pages))
        XCTAssertFalse(html.contains("This page summarises"))
        XCTAssertFalse(html.contains("2 pages"))
        XCTAssertFalse(HomeBase.render(model(turns: [turn(1)], pages: [pages[0]]))
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

    /// A session with no title still says which session it is: the id is the
    /// identity that always exists.
    func testAnUntitledSessionStillNamesItself() {
        let html = HomeBase.render(model(turns: [turn(1)], title: nil))
        XCTAssertTrue(html.contains("session 489b4804"))
        // The nameplate falls back to the id rather than to the word
        // "Untitled": a hub with no name should still say whose it is.
        XCTAssertTrue(html.contains("<h1>Agent 489b4804</h1>"))
    }

    /// The seam check catches what unit tests structurally cannot: a page
    /// recorded for a session that never reached that session's hub.
    func testTheDoctorNoticesAPageMissingFromItsHub() throws {
        let root = NSTemporaryDirectory() + "tb-doctor-" + UUID().uuidString
        let hubs = URL(fileURLWithPath: root + "/hubs")
        try FileManager.default.createDirectory(at: hubs, withIntermediateDirectories: true)
        let session = "489b4804-8d64-4a91-a63c-5e493141c772"
        let page = "/Users/x/Documents/deep-research/2026-08-16-made/index.html"
        ArtifactStore.record(page, session: session, root: root)

        // A hub that names its session but omits the page it made.
        let slug = HomeBase.slug(forSessionId: session)
        let dir = hubs.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "<html>session \(slug)</html>".write(
            to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let problems = HubIntegrity.check(artifactRoot: root, hubRoot: hubs,
                                          pageExists: { _ in true })
        XCTAssertTrue(problems.contains { $0.detail.contains("does not list it") })

        // And the healthy case is silent.
        try "<html>session \(slug) \(page)</html>".write(
            to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        XCTAssertTrue(HubIntegrity.check(artifactRoot: root, hubRoot: hubs,
                                         pageExists: { _ in true })
            .filter { $0.detail.contains("does not list it") }.isEmpty)
        try? FileManager.default.removeItem(atPath: root)
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

/// The tab strip is where you actually choose between fifteen hubs, and it showed
/// fifteen identical blanks because a hub emitted no icon at all.
///
/// The colour took three wrong answers, all the same mistake: reaching outside
/// this app for an accent it has not got. The editorial red reads as an error;
/// `#27926a` and the rest of Darwin's eight are COFRAME's per-client deck inks
/// (Figma, Netflix, Shopify, Stripe), so wearing one says "this is a Coframe
/// deck". `Palette.accent` is documented as advisory and receding, and
/// ready/working/fault are the lamp's reserved status vocabulary. What is left
/// is the app's real look -- putty ink on a dark console -- so the mark is
/// monochrome and follows the ground, exactly as the menu bar's template does.
extension HomeBaseTests {

    func testTheMarkUsesThisAppsOwnInkAndNobodyElses() {
        let icon = HomeBase.favicon()
        XCTAssertTrue(icon.contains("%232A2C28"), "the console ground, for light tab bars")
        XCTAssertTrue(icon.contains("%23C9C8BF"), "the panel's own ink, for dark ones")
        for foreign in ["27926a", "30b487", "a32c28", "db2777", "4f46e5", "0d9488"] {
            XCTAssertFalse(icon.lowercased().contains(foreign),
                           "\(foreign) belongs to Coframe or to an error state, not to this app")
        }
    }

    /// The fallback is the whole reason a light/dark pair is safe here: a browser
    /// that ignores the media query must still paint something. The DEFAULT fill
    /// has to be the dark ink, or the icon vanishes on the common light bar.
    func testTheFallbackFillIsVisibleOnALightTabBar() {
        let icon = HomeBase.favicon()
        let firstFill = icon.range(of: "%232A2C28")!.lowerBound
        let mediaQuery = icon.range(of: "prefers-color-scheme")!.lowerBound
        XCTAssertLessThan(firstFill, mediaQuery,
                          "the unconditional fill must come first, so an ignored query degrades")
    }

    /// One mark for the whole app. An earlier version tinted it per agent, which
    /// made a favicon answer "which agent" -- a question it was never asked. The
    /// question a favicon answers is "is this ours".
    func testEveryHubCarriesTheSameMark() {
        XCTAssertEqual(HomeBase.favicon(), HomeBase.favicon())
    }

    /// A raw '#' terminates a data URI and yields no icon at all, which looks
    /// exactly like emitting none.
    func testTheDataURIIsEscaped() {
        XCTAssertFalse(HomeBase.favicon().contains("fill:#"),
                       "an unescaped # silently produces no icon")
    }
}
