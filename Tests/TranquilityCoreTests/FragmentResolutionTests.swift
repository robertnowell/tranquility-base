import XCTest
@testable import TranquilityCore

/// What a hub should link when a build input sits beside its finished page.
final class FragmentResolvesToItsBuiltPageTests: XCTestCase {

    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tranquility-tests/faithful-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ name: String, _ body: String) throws -> String {
        let u = dir.appendingPathComponent(name)
        try body.write(to: u, atomically: true, encoding: .utf8)
        return u.path
    }

    /// The case Robert opened: a fragment linked instead of the styled page.
    func testAFragmentResolvesToTheBuiltPageBesideIt() throws {
        _ = try write("report.html", "<!doctype html><html><body>styled</body></html>")
        let frag = try write("report.fragment.html", "<section>no doctype</section>")
        XCTAssertEqual(ArtifactStore.faithfulRendering(of: frag),
                       dir.appendingPathComponent("report.html").path)
    }

    /// A whole document is itself, always.
    func testACompletePageIsItsOwnRendering() throws {
        let p = try write("whole.html", "<!doctype html><html><body>x</body></html>")
        XCTAssertEqual(ArtifactStore.faithfulRendering(of: p), p)
    }

    /// share-as-page's shape still works: body.html beside its built index.html.
    func testABodyFragmentStillResolvesToItsIndex() throws {
        let idx = try write("index.html", "<!doctype html><html><body>built</body></html>")
        let body = try write("body.html", "<section>fragment</section>")
        XCTAssertEqual(ArtifactStore.faithfulRendering(of: body), idx)
    }

    /// And never to a hub. agents/<slug>/index.html is the index over the
    /// pages: resolving to it would make the hub list itself.
    func testAFragmentNeverResolvesToAnAgentHub() throws {
        let agents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/agents")
        XCTAssertTrue(ArtifactStore.isAgentHub(agents.appendingPathComponent("0d04e845/index.html").path))
        XCTAssertFalse(ArtifactStore.isAgentHub(agents.appendingPathComponent("0d04e845/a-report/index.html").path))
    }
}
