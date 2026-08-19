import XCTest
@testable import TranquilityCore

/// Ruled 18 Aug: "the PR should absolutely be in the Hub". A pull request is a
/// thing the agent made, so it is filed under the turn that made it, beside the
/// pages — and nothing about it is looked up.
///
/// The drills split along that seam. The extraction ones assert that the field
/// is a COPY: what the message printed survives, and everything else, however
/// plausible, does not. The render ones assert the page shows a link and never
/// a status.
final class PullRequestInTheHubTests: XCTestCase {

    private let real = "https://github.com/robertnowell/tranquility-base/pull/117"
    private let other = "https://github.com/robertnowell/tranquility-base/pull/118"

    // MARK: - Reading the turn's own text (18 Aug, second pass)

    private let cwd = "/Users/x/Projects/tranquility-base"
    private func slug(_: String) -> String? { "robertnowell/tranquility-base" }

    /// The shape that actually occurs. The first design demanded a URL copied
    /// verbatim and filled 2 briefs in 1,299, because assistants write this.
    func testPRHashNumberIsRead() {
        let found = PullRequestMentions.found(
            in: "So PR #121 lands the instrument, not a fix.", cwd: cwd, slug: slug)
        XCTAssertEqual(found, ["https://github.com/robertnowell/tranquility-base/pull/121"])
    }

    /// The long form, and case does not matter.
    func testPullRequestNumberIsRead() {
        XCTAssertEqual(
            PullRequestMentions.found(in: "Merged pull request #9 just now.", cwd: cwd, slug: slug),
            ["https://github.com/robertnowell/tranquility-base/pull/9"])
    }

    /// A pasted URL still wins, and needs no repository to resolve.
    func testAPastedURLIsTakenVerbatim() {
        let url = "https://github.com/robertnowell/kopi/pull/2318"
        XCTAssertEqual(PullRequestMentions.found(in: "Opened \(url) for review.",
                                                 cwd: nil, slug: slug), [url])
    }

    /// A bare "#3" is an issue, a ticket, or a ranking as often as a PR. The
    /// cue word is the evidence that the session meant a pull request, and
    /// without it the hub would link "the #3 candidate".
    func testABareHashNumberIsNotAPullRequest() {
        XCTAssertTrue(PullRequestMentions.found(
            in: "Went with the #3 candidate and closed #88.", cwd: cwd, slug: slug).isEmpty)
    }

    /// No repository, no derived link — the number alone is not an address.
    func testNoRepositoryMeansNoDerivedLink() {
        XCTAssertTrue(PullRequestMentions.found(
            in: "PR #121 is up.", cwd: cwd, slug: { _ in nil }).isEmpty)
    }

    /// One turn can open two, which is why the field is a list.
    func testTwoMentionsBecomeTwoLinks() {
        let found = PullRequestMentions.found(
            in: "Split it: PR #121 carries the core, PR #124 the panel.", cwd: cwd, slug: slug)
        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(found[0].hasSuffix("/pull/121"))
        XCTAssertTrue(found[1].hasSuffix("/pull/124"))
    }

    /// The same PR named twice in one turn is one PR, whichever way it is
    /// written — a sentence that pastes the URL and then says "PR #121" about
    /// it is one link, not two.
    func testTheSamePRTwiceIsOneLink() {
        let text = "Opened https://github.com/robertnowell/tranquility-base/pull/121. "
            + "Then rebased PR #121 onto main."
        XCTAssertEqual(PullRequestMentions.found(in: text, cwd: cwd, slug: slug).count, 1)
    }

    /// A turn that opened nothing files nothing.
    func testATurnThatNamedNoneFilesNone() {
        XCTAssertTrue(PullRequestMentions.found(
            in: "Rewrote the sanitizer's clamp and the tests are green.",
            cwd: cwd, slug: slug).isEmpty)
    }

    /// Nothing is ever looked up: the number is the session's, and only the
    /// repository comes from the checkout.
    func testTheRepositoryComesFromTheRemote() {
        XCTAssertEqual(PullRequestMentions.parseSlug("git@github.com:robertnowell/tb.git"),
                       "robertnowell/tb")
        XCTAssertEqual(PullRequestMentions.parseSlug("https://github.com/robertnowell/tb.git"),
                       "robertnowell/tb")
        XCTAssertEqual(PullRequestMentions.parseSlug("https://github.com/robertnowell/tb"),
                       "robertnowell/tb")
        XCTAssertNil(PullRequestMentions.parseSlug(""))
        XCTAssertNil(PullRequestMentions.parseSlug("notaremote"))
    }

    // MARK: - The page

    private func turn(prs: [String]) -> HomeBase.Turn {
        HomeBase.Turn(at: Date(timeIntervalSince1970: 1_755_500_000),
                      topic: "the grid's words", happened: "Opened the PR.",
                      pullRequests: prs)
    }

    private func model(_ turns: [HomeBase.Turn]) -> HomeBase.Model {
        HomeBase.Model(sessionId: "489b4804-8d64-4a91-a63c-5e493141c772",
                       title: "grid words", callsign: "tranquility grid",
                       cwd: "/Users/x/Projects/tranquility-base",
                       goal: "Light the words.", turns: turns, pages: [])
    }

    /// The ruling, as a page: you can get to the PR from the hub.
    func testThePRIsOnThePageAndLinksOut() {
        let html = HomeBase.render(model([turn(prs: [real])]))
        XCTAssertTrue(html.contains("href=\"\(real)\""))
        XCTAssertTrue(html.contains("PR #117"))
        XCTAssertTrue(html.contains("robertnowell/tranquility-base"))
    }

    /// Filed under its turn, in the made-list, not in a section of its own.
    func testThePRIsFiledUnderItsTurn() {
        let html = HomeBase.render(model([turn(prs: [real])]))
        let made = try? XCTUnwrap(html.range(of: "<ul class=\"made\">"))
        XCTAssertNotNil(made)
        guard let openList = html.range(of: "<ul class=\"made\">"),
              let closeList = html.range(of: "</ul>", range: openList.upperBound..<html.endIndex)
        else { return XCTFail("no made-list") }
        XCTAssertTrue(html[openList.upperBound..<closeList.lowerBound].contains(real))
    }

    /// No state, ever. "Open"/"merged" is a fact about a moment, and this page
    /// is rewritten at every visit from data that never carried one.
    func testThePageNeverClaimsAPRState() {
        let html = HomeBase.render(model([turn(prs: [real])])).lowercased()
        for claim in ["merged", "closed", "draft", "approved", "awaiting review"] {
            XCTAssertFalse(html.contains(claim), "the hub asserted PR state: \(claim)")
        }
    }

    /// A turn with no PR renders exactly as it did before this change.
    func testATurnWithNoPRIsUnchanged() {
        let html = HomeBase.render(model([turn(prs: [])]))
        XCTAssertFalse(html.contains("class=\"pr\""))
    }

    /// The shelf holds work, not only pages, so it stopped saying "pages".
    func testTheShelfIsCalledEarlierWork() {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let pages = [ArtifactStore.Page(path: "/Users/x/Documents/deep-research/a/index.html",
                                        at: old)]
        let turns = (1...12).map {
            HomeBase.Turn(at: Date(timeIntervalSince1970: 1_755_500_000 + Double($0) * 600),
                          topic: "turn \($0)", happened: "Did \($0).")
        }
        let html = HomeBase.render(
            HomeBase.Model(sessionId: "489b4804-8d64-4a91-a63c-5e493141c772",
                           title: nil, callsign: "tranquility grid", cwd: nil,
                           goal: nil, turns: turns.reversed(), pages: pages))
        XCTAssertTrue(html.contains("Earlier work"))
        XCTAssertFalse(html.contains("Earlier pages"))
    }

    // MARK: - It survives the store

    /// The hub reads stored briefs, so a PR that does not round-trip is a PR
    /// that is on the card and never on the page.
    func testThePRSurvivesTheStore() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-pr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("queue.sqlite")

        let store = try QueueStore(url: url)
        try store.saveBrief(
            SessionBrief(topic: "the grid's words", happened: "Opened the PR.",
                         pullRequests: [real, other]),
            sessionId: "sess-pr", eventRowid: 1, provider: "anthropic", callsign: nil)
        try store.saveBrief(
            SessionBrief(topic: "the sanitizer", happened: "Clamped it."),
            sessionId: "sess-pr", eventRowid: 2, provider: "anthropic", callsign: nil)

        let reopened = try QueueStore(url: url)
        let withPRs = try XCTUnwrap(reopened.storedBrief(sessionId: "sess-pr", eventRowid: 1))
        XCTAssertEqual(withPRs.brief.pullRequests, [real, other])
        let without = try XCTUnwrap(reopened.storedBrief(sessionId: "sess-pr", eventRowid: 2))
        XCTAssertNil(without.brief.pullRequests)
        XCTAssertNil(without.pullRequests)
    }

    // MARK: - The backfill (v13)

    /// The migration must actually join. `events.id` is a UUID TEXT column and
    /// `brief.eventRowid` is the SQLite rowid; joining the wrong one returns
    /// zero rows and ships a green backfill that changes nothing. This drill
    /// exists because that is exactly what the first draft did.
    func testTheBackfillFillsAnOldBrief() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("queue.sqlite")

        let store = try QueueStore(url: url)
        let message = "Opened https://github.com/robertnowell/tranquility-base/pull/119 "
            + "for the hub change."
        let event = QueuedEvent(hookEvent: .stop, sessionId: "sess-back",
                                cwd: "/Users/x/Projects/tranquility-base",
                                lastAssistantMessage: message)
        _ = try store.insert(event: event)
        let rowid = try XCTUnwrap(store.eventRowid(forEventId: event.id))
        try store.saveBrief(
            SessionBrief(topic: "pr hub", happened: "Opened it."),
            sessionId: "sess-back", eventRowid: rowid, provider: "anthropic", callsign: nil)

        // Before: the brief predates the reader, exactly like the 1,299 rows
        // already on disk.
        XCTAssertNil(try XCTUnwrap(
            store.storedBrief(sessionId: "sess-back", eventRowid: rowid)).brief.pullRequests)

        try store.runPullRequestBackfill()

        let after = try XCTUnwrap(store.storedBrief(sessionId: "sess-back", eventRowid: rowid))
        XCTAssertEqual(after.brief.pullRequests,
                       ["https://github.com/robertnowell/tranquility-base/pull/119"])
    }
}
