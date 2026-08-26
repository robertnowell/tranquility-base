import XCTest
@testable import TranquilityCore

final class SessionOwnershipTests: XCTestCase {

    private func makeStore() -> (FileSessionOwnershipStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("session-ownership-\(UUID().uuidString)")
        let store = FileSessionOwnershipStore(
            fileURL: dir.appendingPathComponent("session-ownership.json"))
        return (store, dir)
    }

    func testRecordThenCurrentRoundTrips() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = SessionOwnershipRecord(
            sessionId: "s1", harness: "codex", pid: 4242,
            paneId: "%3", socketName: "tb", sessionName: "tb-abc", paneTty: "/dev/ttys004")
        store.record(record)

        XCTAssertEqual(store.current(sessionId: "s1"), record)
        XCTAssertEqual(store.current(sessionId: "s1")?.pane?.paneId, "%3")
    }

    func testMissingSessionReadsAsNil() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(store.current(sessionId: "nobody"))
    }

    func testCorruptFileReadsAsEmptyRatherThanCrashing() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "not json".write(to: store.fileURL, atomically: true, encoding: .utf8)
        XCTAssertNil(store.current(sessionId: "s1"))
        XCTAssertEqual(store.all().count, 0)
    }

    func testRemoveDropsExactlyThatSession() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(SessionOwnershipRecord(sessionId: "s1", harness: "codex", pid: 1))
        store.record(SessionOwnershipRecord(sessionId: "s2", harness: "codex", pid: 2))
        store.remove(sessionId: "s1")
        XCTAssertNil(store.current(sessionId: "s1"))
        XCTAssertEqual(store.current(sessionId: "s2")?.pid, 2)
    }

    func testRecordOverwritesTheSameSessionId() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(SessionOwnershipRecord(sessionId: "s1", harness: "codex", pid: 1))
        store.record(SessionOwnershipRecord(sessionId: "s1", harness: "codex", pid: 2))
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.current(sessionId: "s1")?.pid, 2)
    }

    func testAllReturnsEveryHarnessTogether() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(SessionOwnershipRecord(sessionId: "c1", harness: "codex", pid: 1))
        store.record(SessionOwnershipRecord(sessionId: "cc1", harness: "claude-code", pid: 2))
        XCTAssertEqual(Set(store.all().map(\.harness)), ["codex", "claude-code"])
    }

    // MARK: verifiedCurrent — the liveness gate

    private struct StubStore: SessionOwnershipStore {
        let value: SessionOwnershipRecord?
        func record(_ r: SessionOwnershipRecord) {}
        func current(sessionId: String) -> SessionOwnershipRecord? { value }
        func remove(sessionId: String) {}
        func all() -> [SessionOwnershipRecord] { value.map { [$0] } ?? [] }
    }

    func testVerifiedCurrentRefusesADeadPid() {
        // pid 1 is launchd — always alive on macOS — pick a pid guaranteed
        // never to be alive instead: the max pid_t plus something absurd is
        // not a valid trick on macOS (pids wrap far below Int.max), so
        // assert against a pid this test process itself just reaped instead
        // — deterministic without depending on nothing-at-that-pid forever.
        var reaped: Process? = Process()
        reaped?.executableURL = URL(fileURLWithPath: "/bin/echo")
        try? reaped?.run()
        let deadPid = Int(reaped?.processIdentifier ?? -1)
        reaped?.waitUntilExit()
        reaped = nil

        let store = StubStore(value: SessionOwnershipRecord(
            sessionId: "s1", harness: "codex", pid: deadPid))
        XCTAssertNil(store.verifiedCurrent(sessionId: "s1"))
    }

    func testVerifiedCurrentReturnsALivePid() {
        let store = StubStore(value: SessionOwnershipRecord(
            sessionId: "s1", harness: "codex", pid: Int(ProcessInfo.processInfo.processIdentifier)))
        XCTAssertEqual(store.verifiedCurrent(sessionId: "s1")?.sessionId, "s1")
    }

    func testVerifiedCurrentIsNilWhenNothingIsRecorded() {
        let store = StubStore(value: nil)
        XCTAssertNil(store.verifiedCurrent(sessionId: "s1"))
    }

    // MARK: - liveNonRegistrySessions (26 Aug, the shared fix for ~30
    // call sites that all asked "is this session alive" by calling
    // agents.sessions() alone, which never carries Codex)

    func testLiveNonRegistrySessionsIncludesACodexRecordWithALivePid() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(SessionOwnershipRecord(
            sessionId: "codex-1", harness: "codex",
            pid: Int(ProcessInfo.processInfo.processIdentifier), cwd: "/tmp/x"))
        let live = store.liveNonRegistrySessions()
        XCTAssertEqual(live.map(\.sessionId), ["codex-1"])
        XCTAssertEqual(live.first?.cwd, "/tmp/x")
    }

    /// Claude Code is excluded even when this store holds a record for it
    /// (a revive writes one) — `agents.sessions()` is already authoritative
    /// there, and combining both would double-count the same session.
    func testLiveNonRegistrySessionsExcludesClaudeCode() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(SessionOwnershipRecord(
            sessionId: "cc-1", harness: "claude-code",
            pid: Int(ProcessInfo.processInfo.processIdentifier)))
        XCTAssertTrue(store.liveNonRegistrySessions().isEmpty)
    }

    func testLiveNonRegistrySessionsExcludesADeadPid() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var reaped: Process? = Process()
        reaped?.executableURL = URL(fileURLWithPath: "/bin/echo")
        try? reaped?.run()
        let deadPid = Int(reaped?.processIdentifier ?? -1)
        reaped?.waitUntilExit()
        reaped = nil

        store.record(SessionOwnershipRecord(sessionId: "codex-1", harness: "codex", pid: deadPid))
        XCTAssertTrue(store.liveNonRegistrySessions().isEmpty)
    }
}
