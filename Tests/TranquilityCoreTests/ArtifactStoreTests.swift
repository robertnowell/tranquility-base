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
        XCTAssertTrue(ArtifactStore.record("/tmp/first.html", session: session, root: root))
        XCTAssertTrue(ArtifactStore.record("/tmp/second.html", session: session, root: root))
        XCTAssertEqual(
            ArtifactStore.latest(for: session, root: root, exists: { _ in true }),
            "/tmp/second.html")
    }

    /// Pages get regenerated, moved into HQ, and deleted. A door to a file that
    /// is gone is worse than no door: it spends a click to say nothing.
    func testAPageThatIsGoneOffersNothing() {
        ArtifactStore.record("/tmp/gone.html", session: session, root: root)
        XCTAssertNil(ArtifactStore.latest(for: session, root: root, exists: { _ in false }))
    }

    func testASessionThatWroteNothingOffersNothing() {
        XCTAssertNil(ArtifactStore.latest(for: session, root: root, exists: { _ in true }))
    }

    /// The id arrives from a hook payload and becomes a filename.
    func testASessionIdCannotLeaveTheDirectory() {
        XCTAssertFalse(ArtifactStore.record("/tmp/p.html", session: "../../etc/passwd", root: root))
        XCTAssertNil(ArtifactStore.latest(for: "../../etc/passwd", root: root,
                                          exists: { _ in true }))
        XCTAssertFalse(ArtifactStore.record("/tmp/p.html", session: "", root: root))
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
