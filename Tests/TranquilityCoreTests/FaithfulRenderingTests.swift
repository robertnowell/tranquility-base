import Foundation
import XCTest
@testable import TranquilityCore

/// Every HTML a session writes is a report and belongs on the hub. What the hub
/// may not do is link something that renders unstyled.
///
/// Those two facts rule out the obvious fix. Excluding fragments was tried first
/// and answers "this would render badly" by deleting the report — so the work
/// vanishes from the page instead of appearing properly. There is no skip list
/// here. One question is asked of every recorded file: what is the faithful
/// rendering of this?
final class FaithfulRenderingTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rendering-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func write(_ name: String, _ contents: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private let page = "<!doctype html><html><head><style>b{}</style></head><body>x</body></html>"
    private let fragment = "<section class=\"deck\"><h1>Defensible in the middle</h1></section>"

    /// The incident: a hub linked `aeo-teardown.body.html` and the browser
    /// showed default Times with the stat block collapsed into prose. The
    /// finished page was 190 KB, written the same minute, sitting beside it.
    func testAFragmentResolvesToTheFinishedPageBesideIt() throws {
        let built = try write("index.html", page)
        let body = try write("body.snippet.html", fragment)
        XCTAssertEqual(ArtifactStore.faithfulRendering(of: body), built,
                       "the report is shown, and it is shown styled")
    }

    /// Naming is not the test, because naming drifted four times in two days.
    /// Every shape resolves the same way.
    func testEveryNamingShapeResolvesTheSameWay() throws {
        let built = try write("index.html", page)
        for name in ["body.html", "body.snippet.html",
                     "aeo-teardown.body.html", "aeo-build-plan-page-body.html"] {
            let body = try write(name, fragment)
            XCTAssertEqual(ArtifactStore.faithfulRendering(of: body), built, "\(name)")
        }
    }

    /// A complete document renders as itself and must not be redirected at its
    /// own sibling — otherwise two real reports in one folder collapse into one.
    func testACompletePageRendersAsItself() throws {
        _ = try write("index.html", page)
        let other = try write("teardown.html", page)
        XCTAssertEqual(ArtifactStore.faithfulRendering(of: other), other)
    }

    /// Mid-build: a fragment with no finished page yet has nothing faithful to
    /// show. Not an error and not a permanent exclusion — the finished page
    /// records itself when it is written.
    func testAFragmentWithNoFinishedPageIsNotShownYet() throws {
        let body = try write("body.html", fragment)
        XCTAssertNil(ArtifactStore.faithfulRendering(of: body))
    }

    /// The rule this replaced, kept as a test so it cannot come back: a fragment
    /// is no longer EXCLUDED. Exclusion deleted the report.
    /// Asserted on a REAL path shape rather than the test's own fixture: the
    /// temp directory is `/var/folders/...`, which `excluded` filters for its
    /// own good reasons, so a fixture there passes this by accident.
    func testAFragmentIsNoLongerExcluded() {
        XCTAssertFalse(
            ArtifactStore.excluded("/Users/x/Projects/aeo-teardown-page/body.snippet.html"),
            "the report belongs on the hub; only its rendering was ever the issue")
    }

    /// A hub is the index over artifacts, never one of them (15 Aug).
    func testAHubIsStillExcluded() {
        XCTAssertTrue(ArtifactStore.excluded("/Users/x/Documents/agents/4fed02db/index.html"))
    }
}
