import XCTest
@testable import TranquilityCore

final class ClaudeConfigRepairTests: XCTestCase {

    func testRewritesWriteToEdit() {
        let (out, changed) = ClaudeConfigRepair.rewriteAllow(
            ["Write(//Users/k/Documents/deep-research/**)", "WebSearch"])
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(out, ["Edit(//Users/k/Documents/deep-research/**)", "WebSearch"])
    }

    func testDeduplicatesWhenEditFormAlreadyPresent() {
        let (out, changed) = ClaudeConfigRepair.rewriteAllow(
            ["Write(//a/**)", "Edit(//a/**)"])
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(out, ["Edit(//a/**)"], "the rewritten Write collapses onto the existing Edit")
    }

    func testLeavesACleanListUntouched() {
        let (out, changed) = ClaudeConfigRepair.rewriteAllow(["Edit(//a/**)", "WebSearch"])
        XCTAssertEqual(changed, 0)
        XCTAssertEqual(out, ["Edit(//a/**)", "WebSearch"])
    }

    func testRepairsAFileAndKeepsABackup() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cc-repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent("settings.json")
        try #"{"permissions":{"allow":["Write(//a/**)","WebSearch"]},"cleanupPeriodDays":365}"#
            .write(to: settings, atomically: true, encoding: .utf8)

        let changed = ClaudeConfigRepair.repairStaleWriteRules(settingsURL: settings)
        XCTAssertEqual(changed, 1)

        let after = try String(contentsOf: settings, encoding: .utf8)
        XCTAssertTrue(after.contains("Edit(//a/**)"), after)
        XCTAssertFalse(after.contains("Write(//a/**)"), after)
        XCTAssertTrue(after.contains("cleanupPeriodDays"), "unrelated keys survive")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: settings.appendingPathExtension("tb-backup").path), "a backup is kept")

        // Idempotent: a second run finds nothing.
        XCTAssertEqual(ClaudeConfigRepair.repairStaleWriteRules(settingsURL: settings), 0)
    }

    func testAMissingFileIsLeftAloneAndReturnsZero() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)/settings.json")
        XCTAssertEqual(ClaudeConfigRepair.repairStaleWriteRules(settingsURL: missing), 0)
    }
}
