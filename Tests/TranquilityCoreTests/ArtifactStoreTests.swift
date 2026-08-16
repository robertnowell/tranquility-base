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
