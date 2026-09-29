import XCTest
@testable import TranquilityCore

/// Where the app looks for `tbase` (29 Sep 2026).
///
/// It executes that helper for every question the manager asks about the fleet,
/// and until today it could only find it at a path in hq.json or a hardcoded
/// path inside a source checkout — a file somebody had to build by hand, which
/// no deploy ever did. Measured 28 Sep: the binary the app was running had been
/// built seven days and five shipped fixes earlier, still answering
/// `status --json` with 200 rows while the fixed source answered with 15.
final class TbasePathTests: XCTestCase {

    private func config(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hq-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The developer's override still wins, and must: pointing at a local build
    /// is something you do on purpose, and the bundled copy would silently
    /// ignore you.
    func testAnExplicitPathBeatsTheBundledCopy() throws {
        let url = try config(#"{"manager":{"tbase":"/tmp/my-own/tbase"}}"#)
        XCTAssertEqual(ManagerConfig.tbasePath(config: url, bundled: "/Apps/T.app/tbase"),
                       "/tmp/my-own/tbase")
    }

    /// The fix. With no override, the copy inside the app is used — so
    /// installing the app updates the helper, like everything else.
    func testTheBundledCopyIsUsedWhenNothingOverridesIt() throws {
        let url = try config(#"{"manager":{}}"#)
        XCTAssertEqual(ManagerConfig.tbasePath(config: url, bundled: "/Apps/T.app/tbase"),
                       "/Apps/T.app/tbase")
    }

    /// And the checkout path is last, for a build running with no bundle around
    /// it. It is NOT a reasonable default for anybody else: on a Mac without a
    /// clone of this repository there is no file there at all.
    func testTheCheckoutPathIsOnlyTheLastResort() throws {
        let url = try config(#"{"manager":{}}"#)
        let path = ManagerConfig.tbasePath(config: url, bundled: nil)
        XCTAssertTrue(path.hasSuffix("/.build/arm64-apple-macosx/debug/tbase"), path)
        XCTAssertTrue(path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path), path)
    }

    /// An empty string in the config is not an override. It used to read as one
    /// only because the guard tested for nil; a key somebody blanked out should
    /// fall through to the app's own copy rather than to an unrunnable path.
    func testAnEmptyOverrideFallsThroughToTheBundle() throws {
        let url = try config(#"{"manager":{"tbase":""}}"#)
        XCTAssertEqual(ManagerConfig.tbasePath(config: url, bundled: "/Apps/T.app/tbase"),
                       "/Apps/T.app/tbase")
    }

    /// A tilde in the override is expanded, because that is how it is written
    /// in hq.json today and an unexpanded "~" is not a path anything can run.
    func testATildeInTheOverrideIsExpanded() throws {
        let url = try config(#"{"manager":{"tbase":"~/build/tbase"}}"#)
        let path = ManagerConfig.tbasePath(config: url, bundled: nil)
        XCTAssertFalse(path.contains("~"), path)
        XCTAssertTrue(path.hasSuffix("/build/tbase"), path)
    }
}
