import XCTest
@testable import TranquilityCore

/// The record behind "open page". It is written by a hook on every HTML write
/// and read while a card is on screen, so the two failures that matter are a
/// half-written path (a button that opens nothing) and a session id that walks
/// out of the directory it is supposed to name a file in.
final class ArtifactStoreTests: XCTestCase {

    private var root: String = ""
    private let session = "489b4804-8d64-4a91-a63c-5e493141c772"

    override func setUp() {
        super.setUp()
        root = NSTemporaryDirectory() + "tb-artifact-tests-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: root,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        super.tearDown()
    }

    func testTheLastPageWritten() {
        XCTAssertTrue(ArtifactStore.record("/Users/x/Documents/first.html", session: session, root: root))
        XCTAssertTrue(ArtifactStore.record("/Users/x/Documents/second.html", session: session, root: root))
        XCTAssertEqual(
            ArtifactStore.latest(for: session, root: root, exists: { _ in true }),
            "/Users/x/Documents/second.html")
    }

    /// Pages get regenerated, moved into HQ, and deleted. A door to a file that
    /// is gone is worse than no door: it spends a click to say nothing.
    func testAPageThatIsGoneOffersNothing() {
        ArtifactStore.record("/Users/x/Documents/gone.html", session: session, root: root)
        XCTAssertNil(ArtifactStore.latest(for: session, root: root, exists: { _ in false }))
    }

    func testASessionThatWroteNothingOffersNothing() {
        XCTAssertNil(ArtifactStore.latest(for: session, root: root, exists: { _ in true }))
    }

    /// The id arrives from a hook payload and becomes a filename.
    func testASessionIdCannotLeaveTheDirectory() {
        XCTAssertFalse(ArtifactStore.record("/Users/x/Documents/p.html", session: "../../etc/passwd", root: root))
        XCTAssertNil(ArtifactStore.latest(for: "../../etc/passwd", root: root,
                                          exists: { _ in true }))
        XCTAssertFalse(ArtifactStore.record("/Users/x/Documents/p.html", session: "", root: root))
    }

    /// Probes, temp trees, and the harness's own library never reach a hub,
    /// on write or on read: a scratchpad probe is wiped under its link, and a
    /// skill template on a hub reads as a broken page (both measured 15 Aug).
    func testExcludedPathsAreNeverArtifacts() {
        for path in ["/private/tmp/claude-501/x/scratchpad/probes/page.html",
                     "/tmp/anything.html",
                     "/Users/x/.claude/skills/share-as-page/templates/report.html"] {
            XCTAssertFalse(ArtifactStore.record(path, session: session, root: root), path)
        }
        // A legacy log line that already carries one heals on read.
        XCTAssertTrue(ArtifactStore.record("/Users/x/Documents/real.html",
                                           session: session, root: root))
        let target = (ArtifactStore.directory(root: root) as NSString)
            .appendingPathComponent(session)
        let smuggled = "1700000000000\t/private/tmp/claude-501/x/scratchpad/probes/page.html\n"
        try? smuggled.write(toFile: target + ".tmp", atomically: true, encoding: .utf8)
        if let handle = FileHandle(forWritingAtPath: target) {
            handle.seekToEndOfFile()
            handle.write(smuggled.data(using: .utf8)!)
            try? handle.close()
        }
        let pages = ArtifactStore.history(for: session, root: root, exists: { _ in true })
        XCTAssertEqual(pages.map(\.path), ["/Users/x/Documents/real.html"])
    }

    /// A hub is the index over artifacts, not one of them. Recording one made
    /// the card's OPEN REPORT open a stranger's hub (15 Aug).
    func testAHubIsNeverAnArtifact() {
        XCTAssertFalse(ArtifactStore.record(
            "/Users/x/Documents/agents/da5d6fff/index.html",
            session: session, root: root))
    }

    /// The hub is one file, not every file called index.html.
    ///
    /// A research report is a DIRECTORY holding report.md beside index.html, and
    /// when reports are filed under their agent that brief is
    /// agents/<slug>/<date-slug>/index.html. Excluding on the filename alone
    /// swallowed it along with the hub: the comment on the rule said "only
    /// index.html is the hub" while the rule said "any index.html under agents",
    /// and the difference is invisible until the day reports move.
    func testAReportBriefUnderAnAgentIsStillAnArtifact() {
        XCTAssertTrue(ArtifactStore.record(
            "/Users/x/Documents/agents/da5d6fff/2026-09-01-some-report/index.html",
            session: session, root: root))
        // And the hub one level up is still excluded, so the fix did not simply
        // let everything through.
        XCTAssertFalse(ArtifactStore.record(
            "/Users/x/Documents/agents/da5d6fff/index.html",
            session: session, root: root))
    }

    /// Reading a page is not writing one. The first Bash miner filed every
    /// path a grep mentioned, including other agents' work.
    func testOnlyWritingCommandsCount() {
        XCTAssertFalse(ArtifactStore.writesAFile(
            "grep -c foo /Users/x/Documents/deep-research/a/index.html"))
        XCTAssertFalse(ArtifactStore.writesAFile(
            "python3 -c \"print(open('/Users/x/a/index.html').read())\""))
        XCTAssertFalse(ArtifactStore.writesAFile("open /Users/x/a/index.html"))
        XCTAssertTrue(ArtifactStore.writesAFile(
            "cat <<PY > /Users/x/a/index.html"))
        XCTAssertTrue(ArtifactStore.writesAFile(
            "cp template.html /Users/x/a/index.html"))
    }

    /// Only the destination counts. A path inside a pattern, a flag, or a
    /// grep is not authorship — the prune command that mentioned a page in
    /// its own -v pattern re-recorded that page (16 Aug).
    func testOnlyTheDestinationOfACommandCounts() {
        let home = NSHomeDirectory()
        XCTAssertEqual(
            ArtifactStore.htmlPaths(in: "grep -v '/Users/x/Documents/a/index.html' log > log2"),
            [])
        XCTAssertEqual(
            ArtifactStore.htmlPaths(in: "cat body > /Users/x/Documents/a/index.html"),
            ["/Users/x/Documents/a/index.html"])
        XCTAssertEqual(
            ArtifactStore.htmlPaths(in: "cat body >/Users/x/Documents/a/index.html"),
            ["/Users/x/Documents/a/index.html"])
        XCTAssertEqual(
            ArtifactStore.htmlPaths(in: "cp ~/tpl/base.html ~/Documents/a/index.html"),
            [home + "/Documents/a/index.html"])
        // The source of a copy is read, not written.
        XCTAssertFalse(
            ArtifactStore.htmlPaths(in: "cp /Users/x/tpl/base.html /Users/x/a/out.html")
                .contains("/Users/x/tpl/base.html"))
        XCTAssertEqual(
            ArtifactStore.htmlPaths(in: "python3 -c \"re.sub(r'<[^>]+>','',open('/Users/x/a/index.html').read())\""),
            [])
    }

    /// A page worked on across several turns is dated by its LATEST write, so
    /// it appears beside the work that finished it rather than pinned to the
    /// turn that started it (measured 16 Aug).
    func testAPageIsDatedByItsLatestWrite() {
        let page = "/Users/x/Documents/deep-research/a/index.html"
        ArtifactStore.record(page, session: session, root: root,
                             at: Date(timeIntervalSince1970: 1_000))
        ArtifactStore.record(page, session: session, root: root,
                             at: Date(timeIntervalSince1970: 9_000))
        let pages = ArtifactStore.history(for: session, root: root, exists: { _ in true })
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages.first?.at, Date(timeIntervalSince1970: 9_000))
    }

    /// A regex is not a redirect. `re.sub(r'<[^>]+>', ...)` carries two
    /// greater-than signs and writes nothing; treating them as redirects put
    /// three read-only pages back on a hub minutes after they were pruned.
    func testARegexIsNotARedirect() {
        XCTAssertFalse(ArtifactStore.containsRedirect(
            "python3 -c \"re.sub(r'<[^>]+>', ' ', open('/Users/x/a/index.html').read())\""))
        XCTAssertFalse(ArtifactStore.containsRedirect("grep -o 'a->b' file.html"))
        XCTAssertFalse(ArtifactStore.containsRedirect("cmd 2>&1 | tail"))
        XCTAssertTrue(ArtifactStore.containsRedirect("cat x >/Users/x/a/index.html"))
        XCTAssertTrue(ArtifactStore.containsRedirect("cat x > /Users/x/a/index.html"))
        XCTAssertTrue(ArtifactStore.containsRedirect("cat x >> log.html"))
        XCTAssertTrue(ArtifactStore.containsRedirect("cmd 2> /Users/x/err.html"))
    }

    /// The site name sits on either end of a title, and keeping the wrong side
    /// listed three different documents as "Tranquility Base".
    func testTheSpecificHalfOfATitleSurvives() {
        let dir = NSTemporaryDirectory() + "tb-title-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let page = dir + "/index.html"
        try? """
        <html><head><title>Tranquility Base — The capture is a strip under the card</title></head>
        <body><h1>The capture is a strip under the card, not a screen instead of it</h1></body></html>
        """.write(toFile: page, atomically: true, encoding: .utf8)
        let summary = ArtifactStore.summarize(path: page)
        XCTAssertEqual(summary.title,
                       "The capture is a strip under the card, not a screen instead of it")
    }

    func testRelativePathsAreNotRecorded() {
        XCTAssertFalse(ArtifactStore.record("notes.html", session: session, root: root))
    }

    /// The read trims the newline the writer adds; a path with a trailing
    /// space would otherwise open nothing.
    func testTheStoredPathRoundTripsExactly() {
        let page = "/Users/x/Deep Research/2026-08-10-plan/index.html"
        ArtifactStore.record(page, session: session, root: root)
        XCTAssertEqual(
            ArtifactStore.latest(for: session, root: root, exists: { $0 == page }),
            page)
    }
}
