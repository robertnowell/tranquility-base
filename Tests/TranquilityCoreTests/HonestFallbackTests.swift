import XCTest
import GRDB
@testable import TranquilityCore

/// The 1 Sep defects, each pinned by the fact that produced it.
///
/// One file rather than four, because they are one bug: a code path that
/// cannot determine something asserting a specific answer about it anyway.
/// Commit c2afa11 ruled on it once ("'I don't know' is not spelled 'idle'")
/// and the ruling was applied to a single lamp; these are the three places it
/// had not reached, caught the day they cost a whole afternoon.
final class HonestFallbackTests: XCTestCase {

    // MARK: - A Codex sub-agent is not an agent you can go to

    /// The exact first line of
    /// `rollout-2026-09-01T11-02-03-01a05e22-a280-7de2-97ae-f535f1c10763.jsonl`,
    /// trimmed to the fields that decide this. Codex refuses to resume it:
    /// "cannot resume an unloaded multi-agent v2 sub-agent through its parent".
    private let subagentMeta = #"""
    {"type":"session_meta","payload":{"session_id":"01a059da-dcfb-7de2-b406-b1d69e480767","id":"01a05e22-a280-7de2-97ae-f535f1c10763","parent_thread_id":"01a059da-dcfb-7de2-b406-b1d69e480767","cwd":"/Users/robertnowell/Projects","thread_source":"subagent","agent_nickname":"Archimedes"}}
    """#

    private let userMeta = #"""
    {"type":"session_meta","payload":{"session_id":"01a05dc7-79ad-7bf0-a115-e7474705c621","id":"01a05dc7-79ad-7bf0-a115-e7474705c621","cwd":"/Users/robertnowell/Projects","thread_source":"user","source":"cli"}}
    """#

    func testSubagentRolloutSaysSoInItsOwnMeta() throws {
        guard case .meta(let meta) = CodexRollout.record(subagentMeta) else {
            return XCTFail("the sub-agent's session_meta did not decode")
        }
        XCTAssertTrue(meta.isSubagent)
        XCTAssertEqual(meta.agentNickname, "Archimedes")
        // Its OWN id, never the parent's `session_id` — the parent is a real
        // session and must not be shadowed by its children.
        XCTAssertEqual(meta.sessionId, "01a05e22-a280-7de2-97ae-f535f1c10763")
    }

    func testAUserThreadIsNotASubagent() throws {
        guard case .meta(let meta) = CodexRollout.record(userMeta) else {
            return XCTFail("the session's session_meta did not decode")
        }
        XCTAssertFalse(meta.isSubagent)
    }

    /// Absent is not "subagent". Rollouts written before multi-agent v2 carry
    /// no `thread_source` at all, and every one of them is a real session.
    func testAMissingThreadSourceIsASession() throws {
        let line = #"{"type":"session_meta","payload":{"id":"old","cwd":"/tmp"}}"#
        guard case .meta(let meta) = CodexRollout.record(line) else {
            return XCTFail("the legacy session_meta did not decode")
        }
        XCTAssertFalse(meta.isSubagent)
        XCTAssertNil(meta.threadSource)
    }

    private func makeCodexSessions(_ files: [(id: String, lines: [String])]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-honest-\(UUID().uuidString)")
        let dated = root.appendingPathComponent("2026/09/01")
        try FileManager.default.createDirectory(at: dated, withIntermediateDirectories: true)
        for file in files {
            try file.lines.joined(separator: "\n").write(
                to: dated.appendingPathComponent("rollout-x-\(file.id).jsonl"),
                atomically: true, encoding: .utf8)
        }
        return root
    }

    func testTheWalkDropsSubagentsAndCountsThem() throws {
        let root = try makeCodexSessions([
            ("sub", [subagentMeta]),
            ("real", [userMeta]),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = SessionDiscovery.codexWalk(sessions: root)
        XCTAssertEqual(result.scanned, 2)
        XCTAssertEqual(result.subagents, 1)
        XCTAssertEqual(result.sessions.map(\.sessionId),
                       ["01a05dc7-79ad-7bf0-a115-e7474705c621"])
    }

    // MARK: - A fast death is not evidence of a second writer

    /// The captured pane from the live reproduction, 1 Sep 17:10. The point of
    /// the helper is that the sentence a person needs is the SECOND line of
    /// the error, never the first, and is buried under a logo.
    private let codexRefusalScreen = """
    ╭─────────────────────────────────────────╮
    │ >_ OpenAI Codex (v0.152.0)              │
    │                                         │
    │ model:       loading   /model to change │
    ╰─────────────────────────────────────────╯
      Resuming session…
    › Error: Failed to resume session from /Users/robertnowell/.codex/sessions/2026/09/01/rollout-x.jsonl: thread/resume failed during TUI bootstrap:
     thread/resume failed: cannot resume an unloaded multi-agent v2 sub-agent through its parent; resume the parent first, or use thread/read to inspect it (code -32600)
    """

    func testThePointOfFailureIsTheActionableSentence() {
        let said = SessionLauncher.pointOfFailure(in: codexRefusalScreen, limit: 400)
        XCTAssertTrue(said.contains("cannot resume an unloaded multi-agent v2 sub-agent"))
        // The half that tells you what to do next survives the trim.
        XCTAssertTrue(said.contains("resume the parent first"))
        // The logo does not.
        XCTAssertFalse(said.contains("OpenAI Codex"))
    }

    func testThePointOfFailureIsCappedForAHuman() {
        let said = SessionLauncher.pointOfFailure(in: codexRefusalScreen, limit: 60)
        XCTAssertLessThanOrEqual(said.count, 61)
        XCTAssertTrue(said.hasSuffix("…"))
    }

    /// A screen with nothing that looks like an error still answers with
    /// something. Half an answer beats a confident silence.
    func testAnUnrecognisableScreenStillSaysSomething() {
        XCTAssertEqual(SessionLauncher.pointOfFailure(in: "\n\n  banner\n  last word  \n"),
                       "last word")
    }

    /// The needle that IS evidence, so the two paths stay distinguishable.
    func testTheConflictNeedleIsStillRecognised() {
        let screen = "codex: this session already has an active writer (pid 123)"
        XCTAssertEqual(
            SessionLauncher.classifyCodexResumeScreen(screen, settledNeedle: nil),
            .alreadyLive)
    }

    // MARK: - "I could not open the database" is not "there are no names"

    func testAMissingCodexHomeIsUnreadableNotEmpty() {
        let ghost = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("no-codex-here-\(UUID().uuidString)")
        guard case .unreadable(let why) = CodexThreadNames.attemptRead(in: ghost) else {
            return XCTFail("a missing ~/.codex read as a database that holds no names")
        }
        XCTAssertTrue(why.contains("could not be listed"), why)
    }

    /// A directory that exists but holds no `state_<n>.sqlite` is equally not
    /// an answer about names. This is the case the old `read` returned `[:]`
    /// for, which downstream renamed every Codex row to its directory.
    func testAHomeWithNoStateDatabaseIsUnreadable() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-nostate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case .unreadable(let why) = CodexThreadNames.attemptRead(in: dir) else {
            return XCTFail("a home with no database read as a database that holds no names")
        }
        XCTAssertTrue(why.contains("no state_"), why)
    }

    /// The reason this whole class of bug is invisible: the compatibility
    /// wrapper still answers `[:]`, so every caller that only wants the map
    /// keeps working — and the fact is available to the one caller that needs
    /// to tell the two apart.
    func testTheMapOnlyWrapperStillAnswersEmptyForAFailedRead() {
        let ghost = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("no-codex-here-\(UUID().uuidString)")
        XCTAssertTrue(CodexThreadNames.read(in: ghost).isEmpty)
    }

    /// A real WAL database with **no live writer**, read exactly the way the
    /// app reads Codex's.
    ///
    /// This is the whole bug in one test. SQLite in WAL mode needs the `-shm`
    /// shared-memory file, and a READ-ONLY connection cannot create one — so
    /// while Codex is running the read works, and the moment the last Codex
    /// process exits it stops. Measured 1 Sep 17:16 against the real file:
    ///
    ///     $ sqlite3 'file:state_5.sqlite?mode=ro' 'select count(*) …'
    ///     Error: in prepare, unable to open database file (14)
    ///     $ sqlite3 'file:state_5.sqlite' 'PRAGMA query_only=ON; select …'
    ///     9
    ///
    /// The sidecars are deleted rather than waited on, so "no live writer" is
    /// a state this test reaches deterministically rather than hopes for. The
    /// first assertion proves the trap is still there; without it the second
    /// would pass on a database that never needed the fallback at all.
    func testAWalDatabaseWithNoLiveWriterIsStillReadable() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-wal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("state_5.sqlite")

        // Scoped so the writer is closed — and its `-shm` released — before
        // anything below reads.
        try {
            var writable = Configuration()
            writable.readonly = false
            let queue = try DatabaseQueue(path: db.path, configuration: writable)
            // OUTSIDE a transaction, deliberately. `queue.write` wraps its body
            // in one, and `PRAGMA journal_mode = WAL` is a silent no-op inside
            // a transaction — the first draft of this test did exactly that,
            // built a rollback-journal database, and passed the assertion
            // below by never being in WAL mode at all. The fixture has to be
            // the thing the bug is about.
            try queue.writeWithoutTransaction { database in
                try database.execute(sql: "PRAGMA journal_mode = WAL")
                try database.execute(sql: "CREATE TABLE threads (id TEXT, name TEXT)")
                try database.execute(sql: """
                    INSERT INTO threads VALUES ('01A05369-AA', 'Verify Tranquility Base install')
                    """)
                // A sub-agent, exactly as Codex stores one: present, and nameless.
                try database.execute(sql: "INSERT INTO threads VALUES ('01a05e22-a2', '')")
            }
            try queue.close()
        }()
        // Byte 18 of the header is the write-version; 2 means WAL. Asserted
        // rather than assumed, for the reason above.
        let header = try FileHandle(forReadingFrom: db).readToEnd() ?? Data()
        XCTAssertEqual(header[18], 2, "the fixture is not a WAL database")

        for sidecar in ["-shm", "-wal"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: db.path + sidecar))
        }

        // The trap, still armed: this is what the app used to do, and all it
        // used to be able to say about the result was `[:]`.
        var readonly = Configuration()
        readonly.readonly = true
        XCTAssertThrowsError(
            try DatabaseQueue(path: db.path, configuration: readonly)
                .read { try Row.fetchAll($0, sql: "SELECT id FROM threads") },
            "a read-only handle opened a WAL database with no -shm; this test "
                + "no longer reproduces the condition it exists for")

        guard case .names(let map) = CodexThreadNames.attemptRead(in: dir) else {
            return XCTFail("a WAL database with no live writer read as unreadable")
        }
        // Lowercased to match the rollout's own casing.
        XCTAssertEqual(map["01a05369-aa"], "Verify Tranquility Base install")
        XCTAssertNil(map["01a05e22-a2"])
    }

    // MARK: - Remembering names across a launch

    func testTheNameMapSurvivesARoundTripToDisk() throws {
        let map = ["01a05369-aa": "Verify Tranquility Base install"]
        CodexThreadNames.saveToDisk(map)
        defer { try? FileManager.default.removeItem(at: CodexThreadNames.diskPath) }
        XCTAssertEqual(CodexThreadNames.loadFromDisk(), map)
    }

    /// An empty map is never written. The cold start it would produce — every
    /// Codex row wearing its directory — is the thing the file exists to
    /// prevent, so it must not be what the file remembers.
    func testAnEmptyMapIsNotPersistedOverAGoodOne() throws {
        let map = ["01a05369-aa": "Verify Tranquility Base install"]
        CodexThreadNames.saveToDisk(map)
        defer { try? FileManager.default.removeItem(at: CodexThreadNames.diskPath) }
        CodexThreadNames.saveToDisk([:])
        XCTAssertEqual(CodexThreadNames.loadFromDisk(), map)
    }
}
