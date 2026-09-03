import XCTest
@testable import TranquilityCore

/// Reconciliation at turn end: the answer to "the hook had to guess".
final class HubReconcileTests: XCTestCase {

    private var home: URL!            // stands in for ~/Documents/agents/<slug>
    private var support: URL!         // stands in for Application Support
    private let session = "0d04e845-65ff-488f-983c-58f371d661ed"

    override func setUpWithError() throws {
        // NOT the system temp directory. ArtifactStore refuses to record a
        // path under /tmp or /var/folders — a scratchpad is not an archive —
        // so a fixture built there silently exercises the refusal instead of
        // the feature, and the first version of these tests did exactly that.
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tranquility-tests/reconcile-\(UUID().uuidString)")
        home = base.appendingPathComponent("0d04e845")
        support = base.appendingPathComponent("support")
        for d in [home!, support!] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    @discardableResult
    private func page(_ name: String, _ html: String = "<html><head></head><body>x</body></html>",
                      in dir: URL? = nil) throws -> URL {
        let target = (dir ?? home)!.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try html.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    private func reconcile(turns: [HomeBase.Turn] = []) -> HubReconcile.Result {
        HubReconcile.run(sessionId: session, title: "A session", dir: home,
                         turns: turns, root: support.path)
    }

    /// The whole point: a page written by a shell heredoc, which the hook may
    /// never have seen, is recorded and stamped anyway.
    func testAnUnseenPageIsRecordedAttributedAndFooted() throws {
        let p = try page("report.html")
        let out = reconcile()
        XCTAssertEqual(out.recorded, 1)
        XCTAssertEqual(out.footers, 1)
        XCTAssertEqual(out.sessions, 1)
        let html = try String(contentsOf: p, encoding: .utf8)
        XCTAssertTrue(html.contains(#"<meta name="intranet:session" content="0d04e845">"#))
        XCTAssertTrue(html.contains("data-tb-agent=\"0d04e845\""))
        XCTAssertTrue(html.contains("Open hub"))
    }

    /// The discuss link takes the FULL session id. A slug there is what left the
    /// button dead on 107 pages (issue #251).
    func testTheDiscussLinkCarriesTheFullSessionId() throws {
        let p = try page("report.html")
        reconcile()
        let html = try String(contentsOf: p, encoding: .utf8)
        XCTAssertTrue(html.contains("tranquilitybase://discuss?session=\(session)"),
                      "a slug here is a dead button")
    }

    /// It runs at every turn end, so it has to be free the second time.
    func testASecondPassChangesNothing() throws {
        let p = try page("report.html")
        reconcile()
        let first = try String(contentsOf: p, encoding: .utf8)
        let out = reconcile()
        XCTAssertEqual(try String(contentsOf: p, encoding: .utf8), first)
        XCTAssertEqual(out.footers, 0)
        XCTAssertEqual(out.sessions, 0)
        XCTAssertEqual(out.recorded, 0)
    }

    /// A refreshed mtime re-attributes the page to whichever session last ran a
    /// shell command (16 Aug). Load-bearing.
    func testTheModificationTimeSurvives() throws {
        let p = try page("report.html")
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: p.path)
        reconcile()
        let after = try XCTUnwrap(FileManager.default
            .attributesOfItem(atPath: p.path)[.modificationDate] as? Date)
        XCTAssertEqual(after.timeIntervalSince1970, old.timeIntervalSince1970, accuracy: 1)
    }

    /// A footer somebody else wrote is not ours to replace; only an absent one
    /// is added.
    func testAPageThatAlreadyHasOurFooterIsLeftAlone() throws {
        let existing = "<html><body>x<footer data-tb-agent=\"aaaaaaaa\">theirs</footer></body></html>"
        let p = try page("report.html", existing)
        let out = reconcile()
        XCTAssertEqual(out.footers, 0)
        XCTAssertEqual(try String(contentsOf: p, encoding: .utf8).components(
            separatedBy: "data-tb-agent").count - 1, 1)
    }

    /// The hub is the index over the pages and never one of them.
    func testTheHubItselfIsNotReconciled() throws {
        let hub = try page("index.html")
        let out = reconcile()
        XCTAssertEqual(out.scanned, 0)
        XCTAssertFalse(try String(contentsOf: hub, encoding: .utf8).contains("data-tb-agent"))
    }

    /// A research report lives one level down, beside its report.md.
    func testAReportInItsOwnDirectoryIsReconciled() throws {
        let p = try page("index.html", in: home.appendingPathComponent("2026-09-02-a-report"))
        let out = reconcile()
        XCTAssertEqual(out.scanned, 1)
        XCTAssertTrue(try String(contentsOf: p, encoding: .utf8).contains("data-tb-agent"))
    }

    /// A page that names a different agent was written into the wrong
    /// directory. Claiming it is what put two reports on two hubs (02 Sep).
    func testAPageThatNamesAnotherAgentIsLeftAlone() throws {
        let p = try page("theirs.html",
            "<html><head><meta name=\"intranet:session\" content=\"95d165f8\"></head><body>x</body></html>")
        let out = reconcile()
        XCTAssertEqual(out.foreign, 1)
        XCTAssertEqual(out.recorded, 0, "not ours to record")
        XCTAssertEqual(out.footers, 0, "not ours to sign")
        XCTAssertFalse(try String(contentsOf: p, encoding: .utf8).contains("data-tb-agent"))
    }

    /// And the reading that decides it.
    func testDeclaredSessionIsReadFromTheMeta() {
        XCTAssertEqual(HubReconcile.declaredSession(
            inHTML: "<meta name=\"intranet:session\" content=\"0d04e845\">"), "0d04e845")
        XCTAssertNil(HubReconcile.declaredSession(inHTML: "<p>no meta here</p>"))
    }

    /// The turn stamp rides along, through the one rule that decides ownership.
    func testTheTurnIsStampedToo() throws {
        let p = try page("report.html")
        let turn = HomeBase.Turn(at: Date().addingTimeInterval(60), topic: "t", happened: "h")
        reconcile(turns: [turn])
        XCTAssertTrue(try String(contentsOf: p, encoding: .utf8).contains("intranet:turn"))
    }
}

/// A record is a claim; the page is evidence. When they disagree the page wins.
final class ForeignPageIsNotYoursTests: XCTestCase {

    private var base: URL!
    override func setUpWithError() throws {
        base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tranquility-tests/foreign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    func testAHubDoesNotListAPageThatNamesAnotherAgent() throws {
        let session = "0d04e845-65ff-488f-983c-58f371d661ed"
        let mine = base.appendingPathComponent("mine.html")
        let theirs = base.appendingPathComponent("theirs.html")
        try "<html><head><meta name=\"intranet:session\" content=\"0d04e845\"></head><body>a</body></html>"
            .write(to: mine, atomically: true, encoding: .utf8)
        try "<html><head><meta name=\"intranet:session\" content=\"95d165f8\"></head><body>b</body></html>"
            .write(to: theirs, atomically: true, encoding: .utf8)
        let support = base.appendingPathComponent("support")
        XCTAssertTrue(ArtifactStore.record(mine.path, session: "0d04e845", root: support.path))
        XCTAssertTrue(ArtifactStore.record(theirs.path, session: "0d04e845", root: support.path))

        let listed = ArtifactStore.history(for: session, root: support.path).map(\.path)
        XCTAssertTrue(listed.contains(mine.path))
        XCTAssertFalse(listed.contains(theirs.path),
                       "the page says another agent wrote it, so this hub must not claim it")
    }

    /// A page with no stamp at all is still this agent's — most of the archive
    /// predates the stamp and must not vanish from its hub.
    func testAnUnstampedPageIsStillListed() throws {
        let session = "0d04e845-65ff-488f-983c-58f371d661ed"
        let plain = base.appendingPathComponent("plain.html")
        try "<html><body>no stamp</body></html>".write(to: plain, atomically: true, encoding: .utf8)
        let support = base.appendingPathComponent("support2")
        XCTAssertTrue(ArtifactStore.record(plain.path, session: "0d04e845", root: support.path))
        XCTAssertTrue(ArtifactStore.history(for: session, root: support.path)
            .map(\.path).contains(plain.path))
    }
}
