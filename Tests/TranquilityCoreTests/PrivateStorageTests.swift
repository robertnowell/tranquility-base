import XCTest
@testable import TranquilityCore

/// This app's data directory holds every session's assistant messages, every
/// recording of the user's voice, and both transcripts — `PrivateStorage` is
/// the one thing standing between that and any other local account reading
/// it. Untested since it shipped (store-riders cleanup, 23 Aug): the modes it
/// sets are exactly the kind of thing that regresses silently, since a wrong
/// mode produces no error, no crash, nothing `swift test` would otherwise catch.
final class PrivateStorageTests: XCTestCase {
    var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-privatestorage-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func mode(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? nil
    }

    func testCreateDirectoryIsOwnerOnly() throws {
        try PrivateStorage.createDirectory(at: tmpDir)
        XCTAssertEqual(mode(tmpDir.path), 0o700)
    }

    func testCreateDirectoryResetsAnExistingLooseMode() throws {
        // createDirectory(withIntermediateDirectories:) does not touch the
        // attributes of a directory that already exists — an install
        // predating this change stays at the FileManager default (0755)
        // without the explicit reset PrivateStorage adds afterward.
        try FileManager.default.createDirectory(
            at: tmpDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(mode(tmpDir.path), 0o755, "sanity: the directory really did start loose")

        try PrivateStorage.createDirectory(at: tmpDir)
        XCTAssertEqual(mode(tmpDir.path), 0o700)
    }

    func testProtectRestrictsAFileToItsOwner() throws {
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let file = tmpDir.appendingPathComponent("secret.json")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8),
                                       attributes: [.posixPermissions: 0o644])
        XCTAssertEqual(mode(file.path), 0o644, "sanity: the file really did start loose")

        PrivateStorage.protect(file)
        XCTAssertEqual(mode(file.path), 0o600)
    }

    func testProtectIsSilentOnAMissingFile() {
        // "Safe to call on something that does not exist" is the doc
        // comment's own promise — a caller that protects a file it is
        // about to write, or one that may or may not exist yet, must never
        // crash either way.
        PrivateStorage.protect(tmpDir.appendingPathComponent("never-written.json"))
    }

    func testHardenFixesModesThroughoutAnExistingTree() throws {
        // The whole reason `harden` exists: an install that predates this
        // code has files and directories sitting at the FileManager
        // defaults (0755/0644), and startup is the only chance to bring
        // them up to the current expectation.
        let nested = tmpDir.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nested, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let file = nested.appendingPathComponent("data.json")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8),
                                       attributes: [.posixPermissions: 0o644])

        PrivateStorage.harden(directory: tmpDir)

        XCTAssertEqual(mode(tmpDir.path), 0o700)
        XCTAssertEqual(mode(nested.path), 0o700)
        XCTAssertEqual(mode(file.path), 0o600)
    }

    func testHardenCreatesTheDirectoryIfItDoesNotExistYet() {
        // A first-ever launch calls this before anything has written
        // there — must not crash on an enumerator over nothing.
        PrivateStorage.harden(directory: tmpDir)
        XCTAssertEqual(mode(tmpDir.path), 0o700)
    }
}
