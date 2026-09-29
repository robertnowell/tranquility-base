import XCTest
@testable import TranquilityCore

/// The scan reads a transcript once per change, not once per tick.
///
/// Both directions are asserted, because each fails quietly: a cache that
/// never hits costs two-thirds of a core (29 Sep), and a cache that hits on a
/// moved file shows a stale row that nothing would ever correct.
final class TranscriptFactsCacheTests: XCTestCase {

    private var root: URL!
    private var codex: URL!
    private let slug = "-Users-x-Projects-a"

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("facts-\(UUID().uuidString)")
        root = base.appendingPathComponent("projects")
        codex = base.appendingPathComponent("codex")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(slug), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private let head = #"{"type":"user","entrypoint":"cli","cwd":"/Users/x/Projects/a"}"#
    private let spoke = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}"#
    private let asked = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"next"}]}}"#

    private var file: URL { root.appendingPathComponent(slug).appendingPathComponent("s1.jsonl") }

    private func write(_ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: false, encoding: .utf8)
    }

    private func scan() -> SessionDiscovery.Session? {
        SessionDiscovery.scan(window: 7 * 86_400, limit: 60, now: Date(),
                              projects: root, titles: TranscriptTitles(),
                              sessions: codex, temporaryRoots: []).sessions.first
    }

    /// Same size, same mtime, different bytes: the last two lines swap, so
    /// a fresh read would say "answered". Only the cache can still say
    /// "unanswered", which proves the second scan did not read the file.
    func testAnUnchangedFileIsNotReadAgain() throws {
        // A whole second, so restoring it below is exact: a read-back stamp
        // loses the nanoseconds, and the cache is right to call that a move.
        let stamp = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 60)
        try write([head, asked, spoke])
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
        XCTAssertEqual(scan()?.answered, false)

        try write([head, spoke, asked])
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
        XCTAssertEqual(scan()?.answered, false)
    }

    /// The file grows by one prompt: the tail is re-read and the row flips.
    func testAGrownFileIsReadAgain() throws {
        try write([head, asked, spoke])
        XCTAssertEqual(scan()?.answered, false)
        try write([head, asked, spoke, asked])
        XCTAssertEqual(scan()?.answered, true)
    }

    /// A settled head survives growth; a head still missing its cwd does not.
    func testAHeadWithoutACwdIsReadAgainWhenTheFileGrows() throws {
        let bare = #"{"type":"user","entrypoint":"cli"}"#
        let late = #"{"type":"user","cwd":"/Users/x/Projects/b","message":{"role":"user","content":"hi"}}"#
        try write([bare, spoke])
        XCTAssertNil(scan()?.cwd)
        try write([bare, spoke, late, spoke])
        XCTAssertEqual(scan()?.cwd, "/Users/x/Projects/b")
    }

    /// Codex rollouts are parsed whole, so they get the same memo.
    func testAMovedRolloutIsParsedAgain() throws {
        let meta = #"{"timestamp":"2026-08-30T09:00:00.000Z","type":"session_meta","payload":"#
            + #"{"id":"01a05338-1306-7f40-9dc4-6e3b8e69c9dc","cwd":"/Users/x/Projects/a"}}"#
        let rollout = codex.appendingPathComponent("rollout-x-01a05338.jsonl")
        try (meta + "\n").write(to: rollout, atomically: false, encoding: .utf8)
        func codexRow() -> SessionDiscovery.Session? {
            SessionDiscovery.scan(window: 7 * 86_400, limit: 60, now: Date(),
                                  projects: root, titles: TranscriptTitles(),
                                  sessions: codex, temporaryRoots: [])
                .sessions.first { $0.harness == CodexAdapter().id }
        }
        XCTAssertEqual(codexRow()?.cwd, "/Users/x/Projects/a")

        let moved = meta.replacingOccurrences(of: "Projects/a", with: "Projects/bb")
        try (moved + "\n").write(to: rollout, atomically: false, encoding: .utf8)
        XCTAssertEqual(codexRow()?.cwd, "/Users/x/Projects/bb")
    }
}
