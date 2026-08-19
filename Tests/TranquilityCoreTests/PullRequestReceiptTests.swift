import XCTest
@testable import TranquilityCore

/// The fourth mechanism, and the first that does not guess.
///
/// Three before it worked a pull request out of something adjacent to the act:
/// prose the summariser copied, prose a regex read, and the branch the session
/// was on. The last is the one that finally made the failure legible — a
/// session whose turns touch the main checkout and three worktrees has no
/// single branch, and records whichever one its final shell command left it
/// in. The turn that opened `fix/the-cli-primes-the-hub` recorded `main`.
///
/// `gh pr create` prints the URL of the thing it just made. That is the record.
final class PullRequestReceiptTests: XCTestCase {

    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "vd-pr-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private let session = "489b4804-8d64-4a91-a63c-5e493141c772"
    private let url = "https://github.com/robertnowell/tranquility-base/pull/134"

    func testAReceiptIsRecordedAndReadBack() {
        XCTAssertTrue(PullRequestStore.record(url, session: session, root: root))
        let history = PullRequestStore.history(for: session, root: root)
        XCTAssertEqual(history.map(\.url), [url])
        XCTAssertEqual(history.first?.number, 134)
    }

    /// The same pull request recorded twice — a retried command, a re-run — is
    /// one pull request, and the first stamp is the moment it came to exist.
    func testTheSameURLTwiceIsOneReceipt() {
        let early = Date(timeIntervalSince1970: 1_000_000)
        PullRequestStore.record(url, session: session, root: root, at: early)
        PullRequestStore.record(url, session: session, root: root, at: early.addingTimeInterval(600))
        let history = PullRequestStore.history(for: session, root: root)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.at, early)
    }

    /// Order is the order they were opened, because that is the order they are
    /// filed under turns.
    func testReceiptsKeepTheirOrder() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        PullRequestStore.record(url, session: session, root: root, at: base)
        PullRequestStore.record("https://github.com/robertnowell/tranquility-base/pull/135",
                                session: session, root: root, at: base.addingTimeInterval(60))
        XCTAssertEqual(PullRequestStore.history(for: session, root: root).map(\.number), [134, 135])
    }

    /// The store takes a URL from a hook that parsed command output, so it
    /// checks rather than trusts. A receipt store that accepts anything is a
    /// text scraper with extra steps, which is what it replaces.
    func testOnlyRealPullRequestURLsAreAccepted() {
        for bad in ["", "not a url", "https://github.com/robertnowell/tranquility-base",
                    "https://github.com/o/r/pull/", "https://github.com/o/r/pull/12x",
                    "ftp://github.com/o/r/pull/1", "https://github.com/o/r/issues/12"] {
            XCTAssertFalse(PullRequestStore.isPullRequestURL(bad), "accepted \(bad)")
            XCTAssertFalse(PullRequestStore.record(bad, session: session, root: root))
        }
        XCTAssertTrue(PullRequestStore.isPullRequestURL(url))
    }

    /// A session id ends up in a path, so it is checked, exactly as
    /// ArtifactStore checks it.
    func testAnImplausibleSessionIsRefused() {
        XCTAssertFalse(PullRequestStore.record(url, session: "../../etc/passwd", root: root))
        XCTAssertFalse(PullRequestStore.record(url, session: "", root: root))
        XCTAssertTrue(PullRequestStore.history(for: "../../etc", root: root).isEmpty)
    }

    /// A session that opened none has none — no file, no error, no guess.
    func testNoReceiptsIsEmptyNotAnError() {
        XCTAssertTrue(PullRequestStore.history(for: session, root: root).isEmpty)
    }

    // MARK: - On the page

    /// The receipt is the FACT; the live state is an enrichment. A cold
    /// snapshot must never hide a pull request we know this turn opened —
    /// hiding it is precisely the failure this replaces.
    func testAReceiptShowsEvenBeforeItsStateIsKnown() {
        GitHubPullRequests.cache.reset()
        let at = Date(timeIntervalSince1970: 1_755_530_000)
        let model = HomeBase.Model(
            sessionId: session, title: nil, callsign: "tranquility grid", cwd: nil, goal: nil,
            turns: [HomeBase.Turn(at: at, topic: "the hub", happened: "Opened it.")],
            pages: [], receipts: [.init(url: url, at: at)])
        let html = HomeBase.render(model)
        XCTAssertTrue(html.contains("PR #134"))
        XCTAssertTrue(html.contains(url))
    }

    /// Filed under the turn that ran the command, like a page.
    func testAReceiptIsFiledUnderItsOwnTurn() {
        GitHubPullRequests.cache.reset()
        let newest = Date(timeIntervalSince1970: 1_755_530_000)
        let older = newest.addingTimeInterval(-3600)
        let model = HomeBase.Model(
            sessionId: session, title: nil, callsign: "tranquility grid", cwd: nil, goal: nil,
            turns: [HomeBase.Turn(at: newest, topic: "newest", happened: "Later work."),
                    HomeBase.Turn(at: older, topic: "older", happened: "Earlier work.")],
            // A minute BEFORE the older turn ended, so it belongs to that
            // turn. A receipt stamped after it would belong to the turn that
            // ran next, which is what the window means and what pages do.
            pages: [], receipts: [.init(url: url, at: older.addingTimeInterval(-60))])
        let html = HomeBase.render(model)
        guard let olderBlock = html.range(of: "Earlier work.") else { return XCTFail("no turn") }
        guard let row = html.range(of: "PR #134") else { return XCTFail("no PR row") }
        XCTAssertGreaterThan(row.lowerBound, olderBlock.lowerBound,
                             "the receipt filed under the wrong turn")
    }

    /// Two pull requests opened by one turn are two rows; the same one twice
    /// is one. This is the "why does this hub have six PRs" guard.
    func testOneRowPerPullRequest() {
        GitHubPullRequests.cache.reset()
        let at = Date(timeIntervalSince1970: 1_755_530_000)
        let model = HomeBase.Model(
            sessionId: session, title: nil, callsign: "c", cwd: nil, goal: nil,
            turns: [HomeBase.Turn(at: at, topic: "t", happened: "Opened two.")],
            pages: [],
            receipts: [.init(url: url, at: at),
                       .init(url: url, at: at),
                       .init(url: "https://github.com/robertnowell/tranquility-base/pull/135", at: at)])
        let html = HomeBase.render(model)
        XCTAssertEqual(html.components(separatedBy: "class=\"pr\"").count - 1, 2)
    }
}
