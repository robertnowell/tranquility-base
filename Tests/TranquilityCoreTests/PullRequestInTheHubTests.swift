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

    // MARK: - Extraction is a copy, not a judgement

    /// The ordinary case, and the one the ruling was made for.
    func testATurnThatNamedAPRFilesIt() {
        let source = "Opened \(real) for the grid change. Ready to merge."
        XCTAssertEqual(AnthropicSummaryProvider.groundedPRs([real], in: source), [real])
    }

    /// The common case. An empty list is nil, not `[]` — a turn that opened no
    /// PR and a brief written before the field existed are the same fact.
    func testATurnThatNamedNoneFilesNone() {
        let source = "Rewrote the sanitizer's clamp and the tests are green."
        XCTAssertNil(AnthropicSummaryProvider.groundedPRs([], in: source))
        XCTAssertNil(AnthropicSummaryProvider.groundedPRs(nil, in: source))
    }

    /// One turn can open two, which is why the field is a list.
    func testATurnThatNamedTwoFilesTwo() {
        let source = "Split it: \(real) carries the core, \(other) the panel."
        XCTAssertEqual(AnthropicSummaryProvider.groundedPRs([real, other], in: source),
                       [real, other])
    }

    /// The failure this whole design is against. A URL the message never
    /// printed is not a wrong answer to "which PR is this" — it is not an
    /// answer to the question that was asked, so it does not survive.
    func testAURLTheMessageNeverPrintedIsDropped() {
        let source = "Opened \(real) for the grid change."
        XCTAssertEqual(
            AnthropicSummaryProvider.groundedPRs([real, other], in: source), [real])
    }

    /// "Do not turn a bare #117 into a URL." The prompt says it; the drill
    /// holds it when the prompt is edited by someone who did not read this.
    func testABarePRNumberIsNotPromotedToAURL() {
        let source = "PR #117 is up for review."
        XCTAssertNil(AnthropicSummaryProvider.groundedPRs(["#117"], in: source))
        XCTAssertNil(AnthropicSummaryProvider.groundedPRs(
            ["https://github.com/robertnowell/tranquility-base/pull/117"], in: source))
    }

    /// Trailing punctuation is the message's, not the URL's: a model copying
    /// out of prose brings the sentence's full stop with it.
    func testPunctuationCarriedOutOfProseIsTrimmed() {
        let source = "Landed it in \(real)."
        XCTAssertEqual(AnthropicSummaryProvider.groundedPRs(["\(real)."], in: source), [real])
    }

    /// The same PR named twice in one turn is one PR.
    func testTheSamePRTwiceIsFiledOnce() {
        let source = "Opened \(real). Then rebased \(real) onto main."
        XCTAssertEqual(AnthropicSummaryProvider.groundedPRs([real, real], in: source), [real])
    }

    /// A repository URL is not a pull request, however much of it appears in
    /// the message.
    func testANonPRGitHubURLIsNotAPullRequest() {
        let repo = "https://github.com/robertnowell/tranquility-base"
        XCTAssertNil(AnthropicSummaryProvider.groundedPRs([repo], in: "See \(repo) for context."))
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
}
