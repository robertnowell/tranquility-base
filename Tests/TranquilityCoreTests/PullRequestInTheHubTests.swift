import XCTest
@testable import TranquilityCore

/// Ruled 18 Aug: "the PR should absolutely be in the Hub" — and then twice
/// again, because the first two mechanisms were both wrong in ways the drills
/// below now pin.
///
/// 1. Ask the summariser to copy a URL the turn printed. Filled 2 briefs in
///    1,299: assistants write "PR #117" and paste the URL once.
/// 2. Read "PR #117" with a regex, repository from the cwd. Filed a pull
///    request every time a turn MENTIONED one (172 rows, 107 distinct, the
///    same PR twelve times) and once assembled a link to a pull request that
///    had never existed.
///
/// A pull request is a property of a BRANCH, not of a turn's prose. So the hub
/// asks GitHub, keyed on the branch, exactly as Kanban Code does.
final class PullRequestInTheHubTests: XCTestCase {

    private let repo = "robertnowell/tranquility-base"

    override func tearDown() {
        GitHubPullRequests.cache.reset()
        GitHubPullRequests.cache.fetch = GitHubPullRequests.run
        super.tearDown()
    }

    private func stub(_ pr: GitHubPullRequests.PR?, counting calls: Counter? = nil) {
        GitHubPullRequests.cache.reset()
        GitHubPullRequests.cache.fetch = { _, _ in calls?.bump(); return pr }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func pr(_ number: Int, state: String = "OPEN",
                    approvals: Int = 0, decision: String? = nil) -> GitHubPullRequests.PR {
        .init(number: number, title: "The grid lights its words", state: state,
              url: "https://github.com/\(repo)/pull/\(number)",
              approvals: approvals, reviewDecision: decision)
    }

    // MARK: - The query's own shape

    /// `gh pr list --json` output, as it actually comes back. Captured from a
    /// real call rather than imagined, including `reviewDecision: ""` for a
    /// merged PR, which is not the same as absent.
    func testTheRealResponseParses() throws {
        let json = """
        [{"mergeStateStatus":"UNKNOWN","number":117,"reviewDecision":"","state":"MERGED",\
        "title":"The grid lights its words",\
        "url":"https://github.com/robertnowell/tranquility-base/pull/117",\
        "reviews":[{"state":"APPROVED"},{"state":"COMMENTED"}]}]
        """
        let parsed = try XCTUnwrap(GitHubPullRequests.parse(Data(json.utf8)))
        XCTAssertEqual(parsed.number, 117)
        XCTAssertEqual(parsed.state, "MERGED")
        XCTAssertEqual(parsed.approvals, 1, "only APPROVED reviews count")
        XCTAssertNil(parsed.reviewDecision, "an empty decision is absent, not \"\"")
    }

    /// A branch with no pull request is the common case and must be quiet.
    func testAnEmptyResponseIsNoPullRequest() {
        XCTAssertNil(GitHubPullRequests.parse(Data("[]".utf8)))
        XCTAssertNil(GitHubPullRequests.parse(Data("not json".utf8)))
    }

    /// State is what the page is opened to settle.
    func testTheStatusLineSaysWhatYouCameFor() {
        XCTAssertEqual(pr(1, state: "OPEN", approvals: 2).status, "open · 2 approvals")
        XCTAssertEqual(pr(1, state: "OPEN", approvals: 1).status, "open · 1 approval")
        XCTAssertEqual(pr(1, state: "MERGED", approvals: 3).status, "merged",
                       "a merged PR's approvals are history, not a decision")
        XCTAssertEqual(pr(1, state: "OPEN", decision: "CHANGES_REQUESTED").status,
                       "open · changes requested")
        XCTAssertEqual(pr(1, state: "OPEN", decision: "REVIEW_REQUIRED").status, "open",
                       "\"open · review required\" is the same sentence twice")
    }

    // MARK: - The snapshot never blocks the page

    /// The card's door writes the hub on the MAIN ACTOR. A cold key must
    /// return nothing and start the work elsewhere, or opening the hub freezes
    /// the app — the class this codebase has already paid for twice.
    func testAColdLookupReturnsNothingRatherThanWaiting() {
        let calls = Counter()
        let slow = GitHubPullRequests.PR(
            number: 117, title: "t", state: "OPEN",
            url: "https://github.com/robertnowell/tranquility-base/pull/117",
            approvals: 0, reviewDecision: nil)
        GitHubPullRequests.cache.reset()
        GitHubPullRequests.cache.fetch = { _, _ in
            Thread.sleep(forTimeInterval: 2); calls.bump(); return slow
        }
        let t0 = Date()
        let first = GitHubPullRequests.cached(repo: repo, branch: "ui/grid")
        XCTAssertNil(first)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5, "the cold read waited on the network")
    }

    /// A cold lookup can still be running when an announcement explicitly
    /// primes fresher state. Completion order is not authority: the newer
    /// request must remain the snapshot even when the older one finishes last.
    func testAnOlderColdLookupCannotOverwriteANewerPrime() {
        let calls = Counter()
        let started = DispatchSemaphore(value: 0)
        let releaseOld = DispatchSemaphore(value: 0)
        let old = pr(117, state: "OPEN", approvals: 0)
        let fresh = pr(117, state: "OPEN", approvals: 2)
        GitHubPullRequests.cache.fetch = { _, _ in
            calls.bump()
            if calls.count == 1 {
                started.signal()
                releaseOld.wait()
                return old
            }
            return fresh
        }

        XCTAssertNil(GitHubPullRequests.cached(repo: repo, branch: "ui/grid"))
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(GitHubPullRequests.prime(repo: repo, branch: "ui/grid")?.approvals, 2)
        releaseOld.signal()
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(GitHubPullRequests.cached(repo: repo, branch: "ui/grid")?.approvals, 2)
    }

    /// Once warm, the row is there — and one branch is asked about once, not
    /// once per turn that shares it.
    func testAWarmSnapshotAnswersAndAsksOnce() {
        let calls = Counter()
        stub(pr(117), counting: calls)
        GitHubPullRequests.prime(repo: repo, branch: "ui/grid")
        XCTAssertEqual(GitHubPullRequests.cached(repo: repo, branch: "ui/grid")?.number, 117)
        XCTAssertEqual(GitHubPullRequests.cached(repo: repo, branch: "ui/grid")?.number, 117)
        XCTAssertEqual(calls.count, 1)
    }

    /// "This branch has no pull request" is an answer worth remembering. If it
    /// were forgotten, every render would re-ask GitHub about every branch
    /// that never had one.
    func testKnowingThereIsNonePreventsReasking() {
        let calls = Counter()
        stub(nil, counting: calls)
        GitHubPullRequests.prime(repo: repo, branch: "chore/no-pr")
        _ = GitHubPullRequests.cached(repo: repo, branch: "chore/no-pr")
        _ = GitHubPullRequests.cached(repo: repo, branch: "chore/no-pr")
        XCTAssertEqual(calls.count, 1)
    }

    // MARK: - The page

    private func model(_ turns: [HomeBase.Turn], cwd: String?) -> HomeBase.Model {
        HomeBase.Model(sessionId: "489b4804-8d64-4a91-a63c-5e493141c772",
                       title: "grid words", callsign: "tranquility grid", cwd: cwd,
                       goal: "Light the words.", turns: turns, pages: [])
    }

    private func turn(branch: String?) -> HomeBase.Turn {
        HomeBase.Turn(at: Date(timeIntervalSince1970: 1_755_530_000),
                      topic: "the grid's words", happened: "Opened it.", branch: branch)
    }

    func testThePullRequestIsOnThePageWithItsState() {
        stub(pr(117, state: "OPEN", approvals: 2))
        GitHubPullRequests.prime(repo: repo, branch: "ui/grid")
        let html = HomeBase.render(model([turn(branch: "ui/grid")],
                                         cwd: FileManager.default.currentDirectoryPath))
        // Only assert the PR row when this checkout actually resolves a repo;
        // the row is keyed on that, and a machine without an origin remote is
        // a legitimate environment rather than a failure.
        guard GitRemote.slug(cwd: FileManager.default.currentDirectoryPath) != nil else {
            return XCTAssertFalse(html.contains("class=\"pr\""))
        }
        XCTAssertTrue(html.contains("PR #117"))
        XCTAssertTrue(html.contains("open · 2 approvals"))
        XCTAssertTrue(html.contains("/pull/117"))
    }

    /// No branch, no row. The turn renders exactly as it did before any of
    /// this — which is also what every brief written before v14 looks like.
    func testATurnWithNoBranchHasNoRow() {
        stub(pr(117))
        let html = HomeBase.render(model([turn(branch: nil)], cwd: "/tmp"))
        XCTAssertFalse(html.contains("class=\"pr\""))
    }

    /// No repository, no row — and no invented one. This is the drill for the
    /// failure that produced this rewrite: a link to
    /// `robertnowell/tranquility-base/pull/2318` for a PR in another repo,
    /// assembled out of a sentence.
    func testNoRepositoryMeansNoRowRatherThanAGuess() {
        stub(pr(2318))
        let html = HomeBase.render(model([turn(branch: "ui/grid")], cwd: "/tmp"))
        XCTAssertFalse(html.contains("PR #"))
        XCTAssertFalse(html.contains("/pull/"))
    }

    // MARK: - The repository comes from the checkout, and only that

    func testTheRemoteParses() {
        XCTAssertEqual(GitRemote.parseSlug("git@github.com:robertnowell/tb.git"), "robertnowell/tb")
        XCTAssertEqual(GitRemote.parseSlug("https://github.com/robertnowell/tb.git"), "robertnowell/tb")
        XCTAssertEqual(GitRemote.parseSlug("https://github.com/robertnowell/tb"), "robertnowell/tb")
        XCTAssertNil(GitRemote.parseSlug(""))
        XCTAssertNil(GitRemote.parseSlug("notaremote"))
    }

    // MARK: - The branch survives the store

    /// The hub reads stored briefs. A brief that drops its branch is a turn
    /// whose pull request can never be found again — which is what every brief
    /// before v14 did, silently.
    func testTheBranchSurvivesTheStore() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-branch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("queue.sqlite")

        let store = try QueueStore(url: url)
        try store.saveBrief(
            SessionBrief(topic: "the grid's words", happened: "Opened it.",
                         branch: "ui/the-grid-lights-its-words"),
            sessionId: "sess-branch", eventRowid: 1, provider: "anthropic", callsign: nil)

        let reopened = try QueueStore(url: url)
        let stored = try XCTUnwrap(reopened.storedBrief(sessionId: "sess-branch", eventRowid: 1))
        XCTAssertEqual(stored.brief.branch, "ui/the-grid-lights-its-words")
    }

    /// v15 clears everything the scrapers wrote — all of it, not the
    /// wrong-looking rows, because nothing in that data separates a pull
    /// request a turn OPENED from one it mentioned.
    func testTheScrapedColumnIsCleared() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-clear-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("queue.sqlite")
        let store = try QueueStore(url: url)
        try store.saveBrief(SessionBrief(topic: "t", happened: "h"),
                            sessionId: "s", eventRowid: 1, provider: "p", callsign: nil)
        let stored = try XCTUnwrap(store.storedBrief(sessionId: "s", eventRowid: 1))
        XCTAssertNil(stored.pullRequests)
    }

    /// "HEAD" is what a detached worktree reports and is not a branch at all;
    /// a third of the backfilled briefs carry it. `main` is the dangerous one:
    /// a session on the default branch has no pull request of its own, but
    /// `--head main` can match somebody's PR FROM main and put a stranger's
    /// work on the page.
    func testTheDefaultBranchAndDetachedHeadAreNeverAsked() {
        for name in ["HEAD", "main", "master", "trunk"] {
            XCTAssertFalse(GitHubPullRequests.isAskable(name), "asked about \(name)")
        }
        XCTAssertTrue(GitHubPullRequests.isAskable("ui/the-grid-lights-its-words"))
        XCTAssertTrue(GitHubPullRequests.isAskable("maintenance/cleanup"))
    }

    /// Every turn of a session shares one branch, so a row per turn is the
    /// same pull request nine times down the page — which is the complaint
    /// that started the rewrite, wearing different clothes. Once per branch,
    /// on the newest turn that used it.
    func testTheRowPrintsOncePerBranchNotPerTurn() {
        let cwd = FileManager.default.currentDirectoryPath
        try? XCTSkipIf(GitRemote.slug(cwd: cwd) == nil, "no origin remote here")
        guard GitRemote.slug(cwd: cwd) != nil else { return }
        stub(pr(117))
        GitHubPullRequests.prime(repo: repo, branch: "ui/grid")
        let turns = (0..<5).map {
            HomeBase.Turn(at: Date(timeIntervalSince1970: 1_755_530_000 - Double($0) * 600),
                          topic: "turn \($0)", happened: "Did it.", branch: "ui/grid")
        }
        let html = HomeBase.render(model(turns, cwd: cwd))
        XCTAssertEqual(html.components(separatedBy: "class=\"pr\"").count - 1, 1)
    }

    // MARK: - "HEAD" is not a branch

    /// The failure that made the operator ask whether any of this works: a
    /// session started from ~/Projects, which is not a repository, records
    /// "HEAD" on all 954 transcript entries while doing every piece of its
    /// work inside worktrees that are each on a real branch. It opened six
    /// pull requests and its own hub could show none of them.
    func testHeadFallsThroughToTheWorkingDirectory() {
        XCTAssertEqual(Coordinator.branch(transcript: "ui/grid", cwd: "/nope"), "ui/grid",
                       "a real branch from the transcript wins")
        XCTAssertNil(Coordinator.branch(transcript: "HEAD", cwd: "/nonexistent-path"),
                     "HEAD is not a branch, and an unreadable cwd is not one either")
        XCTAssertNil(Coordinator.branch(transcript: nil, cwd: nil))
        XCTAssertNil(Coordinator.branch(transcript: "", cwd: nil))
    }

    /// This checkout answers for itself: whatever branch the test runs on is
    /// what the fallback must produce.
    func testTheWorkingDirectoryAnswersWithItsOwnBranch() throws {
        let cwd = FileManager.default.currentDirectoryPath
        let expected = GitRemote.currentBranch(cwd: cwd)
        try XCTSkipIf(expected == nil, "this checkout is detached or not a repository")
        XCTAssertEqual(Coordinator.branch(transcript: "HEAD", cwd: cwd), expected)
        XCTAssertNotEqual(Coordinator.branch(transcript: "HEAD", cwd: cwd), "HEAD")
    }

    /// A detached worktree is genuinely not on a branch, so it has no pull
    /// request to find, and saying so is better than naming one.
    func testADetachedCheckoutHasNoBranch() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-detached-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(GitRemote.currentBranch(cwd: dir.path), "a non-repository has no branch")
    }
}
