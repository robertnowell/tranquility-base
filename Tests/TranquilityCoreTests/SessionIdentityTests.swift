import XCTest
@testable import TranquilityCore

/// A directory is the full session id; the eight-character form is a display
/// name and a compatibility symlink, and the two spellings are one session.
final class SessionIdentityTests: XCTestCase {

    private let a = "01a06cf1-a252-7670-a4f7-a155178e6766"
    private let b = "01a06cf1-c211-75c1-831b-9c505a1fd0fd"   // same first eight

    func testTheDirectoryIsTheWholeIdLowercased() {
        XCTAssertEqual(SessionIdentity.directoryName(a.uppercased()), a)
        XCTAssertEqual(SessionIdentity.short(a), "01a06cf1")
    }

    func testEitherSpellingIsTheSameSession() {
        XCTAssertTrue(SessionIdentity.same(a, "01a06cf1"))
        XCTAssertTrue(SessionIdentity.same("01A06CF1", a))
        XCTAssertTrue(SessionIdentity.same(a, a))
    }

    /// The defect itself: two full ids that share eight characters are two
    /// sessions, and a prefix shorter than eight is nobody.
    func testTwoSessionsWithOnePrefixAreNotTheSame() {
        XCTAssertFalse(SessionIdentity.same(a, b))
        XCTAssertFalse(SessionIdentity.same(a, "01a0"))
        XCTAssertFalse(SessionIdentity.same("", ""))
    }

    func testWhatCountsAsASessionDirectory() {
        XCTAssertTrue(SessionIdentity.isDirectoryName("01a06cf1"))
        XCTAssertTrue(SessionIdentity.isDirectoryName(a))
        XCTAssertFalse(SessionIdentity.isDirectoryName("_archive"))
        XCTAssertFalse(SessionIdentity.isDirectoryName("index.html"))
        XCTAssertFalse(SessionIdentity.isDirectoryName("sess"))
    }
}

/// The app heals a directory the bulk migration never saw, and refuses the
/// one case the rename exists to end.
final class LegacyDirectoryAdoptionTests: XCTestCase {

    private var root: URL!
    private let a = "01a06cf1-a252-7670-a4f7-a155178e6766"
    private let b = "01a06cf1-c211-75c1-831b-9c505a1fd0fd"

    override func setUpWithError() throws {
        // Caches, not the system temp directory: see HubReconcileTests.
        root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tranquility-tests/adopt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func legacyHub(owner: String?) throws {
        let dir = root.appendingPathComponent("01a06cf1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let link = owner.map { "<a href=\"tranquilitybase://discuss?session=\($0)&amp;ref=x\">" } ?? ""
        try "<html><body>\(link)</body></html>".write(
            to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    func testAnOldDirectoryIsRenamedAndLinked() throws {
        try legacyHub(owner: a)
        XCTAssertTrue(HomeBase.adoptLegacyDirectory(sessionId: a, root: root))
        let new = root.appendingPathComponent(a)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: new.appendingPathComponent("index.html").path))
        XCTAssertTrue(isSymlink(root.appendingPathComponent("01a06cf1")))
        // Through the link, the old address still opens the same page.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("01a06cf1/index.html").path))
        // And a second call has nothing left to do.
        XCTAssertFalse(HomeBase.adoptLegacyDirectory(sessionId: a, root: root))
    }

    /// The collision: the directory's hub names session A, so session B, which
    /// shares the eight characters, does not get to take it.
    func testAnotherSessionsDirectoryIsRefused() throws {
        try legacyHub(owner: a)
        XCTAssertFalse(HomeBase.adoptLegacyDirectory(sessionId: b, root: root))
        XCTAssertFalse(isSymlink(root.appendingPathComponent("01a06cf1")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(b).path))
    }

    /// A hub that names nobody (written before the Discuss button existed) is
    /// adopted by whoever asks first; there is nothing to contradict them.
    func testAnUnclaimedDirectoryIsAdopted() throws {
        try legacyHub(owner: nil)
        XCTAssertTrue(HomeBase.adoptLegacyDirectory(sessionId: b, root: root))
    }

    func testAPrefixResolvesToTheOneRealDirectory() throws {
        try legacyHub(owner: a)
        XCTAssertNil(HomeBase.sessionId(matchingPrefix: "01a06cf1", root: root))
        HomeBase.adoptLegacyDirectory(sessionId: a, root: root)
        XCTAssertEqual(HomeBase.sessionId(matchingPrefix: "01a06cf1", root: root), a)
        // Two real directories under one prefix is not an answer.
        try FileManager.default.createDirectory(at: root.appendingPathComponent(b),
                                                withIntermediateDirectories: true)
        XCTAssertNil(HomeBase.sessionId(matchingPrefix: "01a06cf1", root: root))
    }
}
