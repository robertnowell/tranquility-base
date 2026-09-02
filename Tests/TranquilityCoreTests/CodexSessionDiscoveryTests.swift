import XCTest
@testable import TranquilityCore

/// Codex registers nothing and writes no briefs, so the only record that one of
/// its sessions existed is the file it left behind. Every sweep that asked the
/// brief table for "every agent" was really asking "every Claude Code agent",
/// which is how 218 of 225 Codex sessions had no hub.
final class CodexSessionDiscoveryTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tb-codex-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func touch(_ relative: String) throws {
        let f = dir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: f)
    }

    func testItFindsIdsNestedUnderTheDatedDirectories() throws {
        try touch("2026/09/02/rollout-2026-09-02T10-00-00-019eb3b8-e53e-7d71-869b-7cf32e48e13f.jsonl")
        try touch("2026/08/31/rollout-2026-08-31T09-00-00-01a05369-22d7-7973-95a2-581ae81ad221.jsonl")
        XCTAssertEqual(CodexRollout.knownSessionIds(sessions: dir),
                       ["019eb3b8-e53e-7d71-869b-7cf32e48e13f",
                        "01a05369-22d7-7973-95a2-581ae81ad221"])
    }

    /// The id is the last five dash groups and it is 36 characters. Anything
    /// else in that directory is somebody else's file.
    func testItRefusesWhatIsNotAnId() throws {
        try touch("2026/09/02/notes.jsonl")
        try touch("2026/09/02/rollout-2026-09-02T10-00-00-short.jsonl")
        try touch("2026/09/02/rollout-2026-09-02T10-00-00-019eb3b8-e53e-7d71-869b-7cf32e48e13f.txt")
        XCTAssertTrue(CodexRollout.knownSessionIds(sessions: dir).isEmpty)
    }

    func testAMissingDirectoryIsEmptyNotACrash() {
        let nowhere = dir.appendingPathComponent("no-such-thing", isDirectory: true)
        XCTAssertTrue(CodexRollout.knownSessionIds(sessions: nowhere).isEmpty)
    }

    /// One session, two rollout files (a resume writes another): one agent.
    func testTheSameSessionTwiceIsOneId() throws {
        let id = "019eb3b8-e53e-7d71-869b-7cf32e48e13f"
        try touch("2026/09/01/rollout-2026-09-01T10-00-00-\(id).jsonl")
        try touch("2026/09/02/rollout-2026-09-02T11-00-00-\(id).jsonl")
        XCTAssertEqual(CodexRollout.knownSessionIds(sessions: dir), [id])
    }
}
