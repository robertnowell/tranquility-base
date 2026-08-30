import XCTest
@testable import TranquilityCore

/// Codex rows wear the name Codex gave them.
///
/// The file is versioned and theirs, so the part worth pinning is the choice
/// of file: reading a stale one after their next migration would serve names
/// that quietly stop updating, which is worse than none because nothing looks
/// wrong.
final class CodexThreadNamesTests: XCTestCase {

    func testTheNewestStateFileWins() {
        XCTAssertEqual(
            CodexThreadNames.newestState(among: [
                "state_3.sqlite", "state_5.sqlite", "state_4.sqlite"]),
            "state_5.sqlite")
    }

    /// Numeric, not lexical. A string sort puts "state_9" above "state_10" and
    /// would pin this to a database Codex had already migrated away from.
    func testTenBeatsNine() {
        XCTAssertEqual(
            CodexThreadNames.newestState(among: ["state_9.sqlite", "state_10.sqlite"]),
            "state_10.sqlite")
    }

    /// The directory has plenty of neighbours: WAL and shm siblings, other
    /// databases entirely. None of them is a state file.
    func testNeighboursAreNotMistakenForIt() {
        XCTAssertNil(CodexThreadNames.newestState(among: [
            "state_5.sqlite-wal", "state_5.sqlite-shm",
            "history.sqlite", "thread_history_1.sqlite", "config.toml",
            "state_.sqlite", "state_x.sqlite",
        ]))
    }

    func testNothingThereIsNil() {
        XCTAssertNil(CodexThreadNames.newestState(among: []))
    }

    /// Every failure path ends in "no names", never a throw: this decorates a
    /// row that already exists, and a missing title must cost that row its
    /// name and nothing else.
    func testAnAbsentCodexHomeYieldsNoNamesRatherThanFailing() {
        let ghost = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("no-codex-\(UUID().uuidString)")
        XCTAssertTrue(CodexThreadNames.all(in: ghost).isEmpty)
    }

    func testADirectoryWithNoStateFileYieldsNoNames() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not a database".utf8)
            .write(to: dir.appendingPathComponent("config.toml"))
        XCTAssertTrue(CodexThreadNames.all(in: dir).isEmpty)
    }
}
