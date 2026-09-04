import Foundation
import XCTest
@testable import TranquilityCore

/// Writing the trust record instead of pressing at the dialog that asks for it.
///
/// The file being written is the user's real Claude Code config, which another
/// process owns and writes concurrently, so the properties that matter here are
/// not "does the key land" (it obviously does) but "is everything else still
/// there afterwards" and "does it decline to write when it has nothing to add".
final class ClaudeTrustTests: XCTestCase {

    private var dir: URL!
    private var config: URL!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-trust-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        config = dir.appendingPathComponent(".claude.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func write(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        try! data.write(to: config)
    }

    private func read() -> [String: Any] {
        let data = try! Data(contentsOf: config)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testRecordsTrustForTheDirectory() {
        write(["projects": [:]])
        XCTAssertTrue(ClaudeTrust.trust(directory: "/tmp/a", at: config))
        let projects = read()["projects"] as! [String: Any]
        let entry = projects["/tmp/a"] as! [String: Any]
        XCTAssertEqual(entry["hasTrustDialogAccepted"] as? Bool, true)
    }

    /// The property that matters most. A 350KB config with a year of state in
    /// it must come back byte-for-byte equivalent apart from the one leaf.
    func testPreservesEveryOtherKey() {
        write([
            "numStartups": 412,
            "hasCompletedOnboarding": true,
            "theme": "dark",
            "tipsHistory": ["a": 1, "b": 2],
            "projects": [
                "/tmp/other": ["hasTrustDialogAccepted": true, "history": ["x", "y"]],
                "/tmp/a": ["allowedTools": ["Bash"]],
            ],
        ])
        XCTAssertTrue(ClaudeTrust.trust(directory: "/tmp/a", at: config))
        let root = read()
        XCTAssertEqual(root["numStartups"] as? Int, 412)
        XCTAssertEqual(root["hasCompletedOnboarding"] as? Bool, true)
        XCTAssertEqual(root["theme"] as? String, "dark")
        XCTAssertEqual((root["tipsHistory"] as? [String: Int])?["b"], 2)

        let projects = root["projects"] as! [String: Any]
        // The untouched sibling survives whole.
        let other = projects["/tmp/other"] as! [String: Any]
        XCTAssertEqual(other["hasTrustDialogAccepted"] as? Bool, true)
        XCTAssertEqual(other["history"] as? [String], ["x", "y"])
        // The target keeps its own existing keys and gains exactly one.
        let target = projects["/tmp/a"] as! [String: Any]
        XCTAssertEqual(target["allowedTools"] as? [String], ["Bash"])
        XCTAssertEqual(target["hasTrustDialogAccepted"] as? Bool, true)
    }

    /// The steady state. Every launch after the first must not touch the file
    /// at all, because the cheapest correct thing to do to a document another
    /// process is writing is nothing.
    func testDoesNotWriteWhenAlreadyTrusted() throws {
        write(["projects": ["/tmp/a": ["hasTrustDialogAccepted": true]]])
        let before = try FileManager.default
            .attributesOfItem(atPath: config.path)[.modificationDate] as! Date
        XCTAssertFalse(ClaudeTrust.trust(directory: "/tmp/a", at: config))
        let after = try FileManager.default
            .attributesOfItem(atPath: config.path)[.modificationDate] as! Date
        XCTAssertEqual(before, after, "an already-trusted directory must cost no write")
    }

    func testUpgradesAnExplicitFalse() {
        write(["projects": ["/tmp/a": ["hasTrustDialogAccepted": false]]])
        XCTAssertFalse(ClaudeTrust.isTrusted(directory: "/tmp/a", at: config))
        XCTAssertTrue(ClaudeTrust.trust(directory: "/tmp/a", at: config))
        XCTAssertTrue(ClaudeTrust.isTrusted(directory: "/tmp/a", at: config))
    }

    func testCreatesTheProjectsMapWhenAbsent() {
        write(["numStartups": 1])
        XCTAssertTrue(ClaudeTrust.trust(directory: "/tmp/a", at: config))
        XCTAssertTrue(ClaudeTrust.isTrusted(directory: "/tmp/a", at: config))
        XCTAssertEqual(read()["numStartups"] as? Int, 1)
    }

    /// A missing or unreadable config is a machine where Claude Code has never
    /// run. Refusing quietly is right: there is no document to add a key to,
    /// and inventing one would be writing a config on another tool's behalf.
    func testRefusesRatherThanInventingAConfig() {
        XCTAssertFalse(ClaudeTrust.trust(directory: "/tmp/a", at: config))
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))
    }

    func testRefusesOnCorruptConfigWithoutDestroyingIt() throws {
        try "{ not json".write(to: config, atomically: true, encoding: .utf8)
        XCTAssertFalse(ClaudeTrust.trust(directory: "/tmp/a", at: config))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "{ not json",
                       "a config this cannot parse must be left exactly as found")
    }

    func testIsTrustedIsFalseForAnUnknownDirectory() {
        write(["projects": ["/tmp/other": ["hasTrustDialogAccepted": true]]])
        XCTAssertFalse(ClaudeTrust.isTrusted(directory: "/tmp/a", at: config))
    }
}
