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

    func testRekeyMovesOneAttachmentWithoutChangingItsPaneFacts() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let attached = Date(timeIntervalSince1970: 1234)
        store.record(SessionOwnershipRecord(
            sessionId: "parent", harness: "codex", pid: 42,
            paneId: "%7", socketName: "tb", sessionName: "tb-one",
            paneTty: "/dev/ttys014", cwd: "/Projects", attachedAt: attached))

        let moved = store.rekey(from: "parent", to: "child", expectedPid: 42)

        XCTAssertNil(store.current(sessionId: "parent"))
        XCTAssertEqual(store.current(sessionId: "child"), moved)
        XCTAssertEqual(moved?.sessionId, "child")
        XCTAssertEqual(moved?.paneId, "%7")
        XCTAssertEqual(moved?.paneTty, "/dev/ttys014")
        XCTAssertEqual(moved?.attachedAt, attached)
    }

    func testRekeyRefusesARecordWhosePidChangedAfterItWasObserved() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(SessionOwnershipRecord(sessionId: "parent", harness: "codex", pid: 42))

        XCTAssertNil(store.rekey(from: "parent", to: "child", expectedPid: 99))
        XCTAssertNotNil(store.current(sessionId: "parent"))
        XCTAssertNil(store.current(sessionId: "child"))
    }

    func testRekeyRefusesToOverwriteADifferentLiveOwner() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let livePid = Int(ProcessInfo.processInfo.processIdentifier)
        store.record(SessionOwnershipRecord(sessionId: "parent", harness: "codex", pid: 42))
        store.record(SessionOwnershipRecord(sessionId: "child", harness: "codex", pid: livePid))

        XCTAssertNil(store.rekey(from: "parent", to: "child", expectedPid: 42))
        XCTAssertEqual(store.current(sessionId: "parent")?.pid, 42)
        XCTAssertEqual(store.current(sessionId: "child")?.pid, livePid)
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

    func testLiveNonRegistrySessionsRekeysACodexForkBeforeDecoratingIt() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let livePid = Int(ProcessInfo.processInfo.processIdentifier)
        store.record(SessionOwnershipRecord(
            sessionId: "parent", harness: "codex", pid: livePid,
            paneId: "%12", paneTty: "/dev/ttys014", cwd: "/Projects"))
        var preferenceMove: (String, String)?

        let live = store.liveNonRegistrySessions(
            status: { $0 == "child" ? "busy" : nil },
            name: { $0 == "child" ? "Adapt tariff refund document" : nil },
            activeSessionId: { _ in "child" },
            migratePreference: { preferenceMove = ($0, $1) })

        XCTAssertEqual(live.map(\.sessionId), ["child"])
        XCTAssertEqual(live.first?.status, "busy")
        XCTAssertEqual(live.first?.name, "Adapt tariff refund document")
        XCTAssertNil(store.current(sessionId: "parent"))
        XCTAssertEqual(store.current(sessionId: "child")?.pid, livePid)
        XCTAssertEqual(preferenceMove?.0, "parent")
        XCTAssertEqual(preferenceMove?.1, "child")
    }

    func testNoRuntimeIdentityAnswerLeavesOwnershipUntouched() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let livePid = Int(ProcessInfo.processInfo.processIdentifier)
        store.record(SessionOwnershipRecord(sessionId: "parent", harness: "codex", pid: livePid))

        let live = store.liveNonRegistrySessions(
            activeSessionId: { _ in nil }, migratePreference: { _, _ in
                XCTFail("no identity migration should move a preference")
            })

        XCTAssertEqual(live.map(\.sessionId), ["parent"])
        XCTAssertNotNil(store.current(sessionId: "parent"))
    }
}

final class CodexProcessIdentityTests: XCTestCase {
    private let locks = URL(fileURLWithPath: "/Users/test/.codex/thread-writer-locks")
    private let parent = "01a07cf2-a32a-77d0-b806-e9c3398d9da4"
    private let child = "01a07d1d-a9b8-7e73-932b-7be43ca5c032"

    func testOneHeldWriterLockNamesTheActiveThread() {
        let output = """
        p63621
        f52
        n/Users/test/.codex/thread-writer-locks/\(child).lock
        """
        XCTAssertEqual(CodexProcessIdentity.threadId(lsofOutput: output, locks: locks), child)
    }

    func testNoHeldWriterLockIsNotAnAnswer() {
        XCTAssertNil(CodexProcessIdentity.threadId(lsofOutput: "p63621\nf52", locks: locks))
    }

    func testTwoHeldWriterLocksAreAmbiguousRatherThanNewestWins() {
        let output = """
        p63621
        f51
        n/Users/test/.codex/thread-writer-locks/\(parent).lock
        f52
        n/Users/test/.codex/thread-writer-locks/\(child).lock
        """
        XCTAssertNil(CodexProcessIdentity.threadId(lsofOutput: output, locks: locks))
    }

    func testNonUuidAndNestedFilesCannotBecomeThreadIdentity() {
        let output = """
        p63621
        n/Users/test/.codex/thread-writer-locks/.coordination.lock
        n/Users/test/.codex/thread-writer-locks/nested/\(child).lock
        """
        XCTAssertNil(CodexProcessIdentity.threadId(lsofOutput: output, locks: locks))
    }

    /// The bug of 13 Sep, in the shape the machine actually had it.
    ///
    /// pid 91395 held seven writer locks: the fork Robert had just made by
    /// editing one prompt, and six sub-agents — three of them spawned two
    /// days earlier and never released. Under "exactly one lock or nothing"
    /// this was ambiguity, the pane kept its dead parent id, and the live
    /// conversation appeared nowhere.
    func testSubagentLocksDoNotMakeAForkAmbiguous() {
        let subagents = ["01a0913c-d842-7f72-9950-69956d57d943",
                         "01a09153-c702-7203-b5ab-84fb6da37be0",
                         "01a09153-fa52-7621-817c-2bfd57537bb5",
                         "01a09b8e-9cdd-7d80-9788-0a4c6beb2f7c",
                         "01a09b8e-b24f-7a52-ac5f-5d7013b23bd9",
                         "01a09b8e-c80c-7341-a9a6-653e4d5a1be0"]
        let fork = "01a09b8d-c39b-7111-815c-6a09d382b46a"
        let output = (subagents + [fork])
            .map { "n/Users/test/.codex/thread-writer-locks/\($0).lock" }
            .joined(separator: "\n")
        let meta = { (id: String) -> CodexRollout.SessionMeta? in
            subagents.contains(id)
                ? CodexRollout.SessionMeta(sessionId: id, threadSource: "subagent",
                                           forkedFromId: self.parent)
                : CodexRollout.SessionMeta(sessionId: id, threadSource: "user",
                                           forkedFromId: self.parent)
        }
        XCTAssertEqual(CodexProcessIdentity.threadId(lsofOutput: output, locks: locks,
                                                     recordedId: parent, meta: meta), fork)
    }

    /// A sub-agent excludes itself only by SAYING so. A candidate whose
    /// rollout has not been written yet is still a candidate, because the
    /// alternative is dropping a thread for being new.
    func testAThreadWithNoRolloutYetIsStillACandidate() {
        let output = "n/Users/test/.codex/thread-writer-locks/\(child).lock"
        XCTAssertEqual(CodexProcessIdentity.threadId(lsofOutput: output, locks: locks,
                                                     recordedId: parent,
                                                     meta: { _ in nil }), child)
    }

    /// Two live conversations in one pid stays ambiguity: the fork chain
    /// decides, and when neither candidate descends from the recorded id
    /// there is nothing to decide with.
    func testTwoUnrelatedConversationsInOnePidRemainAmbiguous() {
        let other = "01a09b8f-1111-7000-8000-aaaaaaaaaaaa"
        let output = [child, other]
            .map { "n/Users/test/.codex/thread-writer-locks/\($0).lock" }
            .joined(separator: "\n")
        let meta = { (id: String) -> CodexRollout.SessionMeta? in
            CodexRollout.SessionMeta(sessionId: id, threadSource: "user")
        }
        XCTAssertNil(CodexProcessIdentity.threadId(lsofOutput: output, locks: locks,
                                                   recordedId: parent, meta: meta))
    }

    /// Editing two prompts back forks twice, so the live thread is the
    /// recorded id's GRANDCHILD. The chain is walked, not just the link.
    func testForkOfAForkIsStillTheSameConversation() {
        let middle = "01a09b8e-2222-7000-8000-bbbbbbbbbbbb"
        let output = [child, "01a09b90-3333-7000-8000-cccccccccccc"]
            .map { "n/Users/test/.codex/thread-writer-locks/\($0).lock" }
            .joined(separator: "\n")
        let meta = { (id: String) -> CodexRollout.SessionMeta? in
            switch id {
            case self.child:
                return CodexRollout.SessionMeta(sessionId: id, threadSource: "user",
                                                forkedFromId: middle)
            case middle:
                return CodexRollout.SessionMeta(sessionId: id, threadSource: "user",
                                                forkedFromId: self.parent)
            default:
                return CodexRollout.SessionMeta(sessionId: id, threadSource: "user")
            }
        }
        XCTAssertEqual(CodexProcessIdentity.threadId(lsofOutput: output, locks: locks,
                                                     recordedId: parent, meta: meta), child)
    }

    /// A `forked_from_id` cycle is not something Codex writes, and must not
    /// be something this spins on.
    func testAForkCycleTerminates() {
        let meta = { (id: String) -> CodexRollout.SessionMeta? in
            CodexRollout.SessionMeta(sessionId: id, threadSource: "user",
                                     forkedFromId: id == self.child ? self.parent : self.child)
        }
        XCTAssertFalse(CodexProcessIdentity.descends(child, from: "nobody", meta: meta))
    }

    func testTtyNormalizationTreatsDevPrefixAsPresentationOnly() {
        XCTAssertEqual(CodexProcessIdentity.normalizedTty("/dev/ttys014"), "ttys014")
        XCTAssertEqual(CodexProcessIdentity.normalizedTty("ttys014"), "ttys014")
    }

    func testLsofQueryAvoidsTheDirectorySelectorThatReturnsFailureOnMacOS() {
        XCTAssertEqual(CodexProcessIdentity.lsofArguments(pid: 63621),
                       ["-p", "63621", "-Fn"])
    }

    /// A lock FILE is not a holder. If Codex ever stops dropping the parent's
    /// lock on a fork, the fast path would keep serving the dead id — so a
    /// child of the recorded conversation holding a lock of its own is
    /// treated as proven drift, and the cheap answer is refused.
    func testAForkHoldingItsOwnLockRefusesTheStaleFastPath() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-locks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent(parent + ".lock"))
        try Data().write(to: dir.appendingPathComponent(child + ".lock"))
        let record = SessionOwnershipRecord(
            sessionId: parent, harness: CodexAdapter().id,
            pid: Int(ProcessInfo.processInfo.processIdentifier), paneTty: nil)

        // No tty on the record, so the lsof path refuses too: the assertion
        // that matters is that the stale parent is NOT the answer.
        XCTAssertNil(CodexProcessIdentity.activeThreadId(
            for: record, locks: dir, lineage: { [self.child: self.parent] }))
    }

    /// The overwhelmingly common shape — a pane that never forked — still
    /// answers from the file alone, with no subprocess and no tty.
    func testAnUnforkedConversationStillTakesTheFastPath() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-locks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent(parent + ".lock"))
        try Data().write(to: dir.appendingPathComponent(child + ".lock"))
        let record = SessionOwnershipRecord(
            sessionId: parent, harness: CodexAdapter().id,
            pid: Int(ProcessInfo.processInfo.processIdentifier), paneTty: nil)

        // `child` holds a lock but forked from somebody else entirely.
        XCTAssertEqual(CodexProcessIdentity.activeThreadId(
            for: record, locks: dir,
            lineage: { [self.child: "01a09c00-0000-7000-8000-000000000000"] }),
                       parent)
    }

    func testDriftIsOnlyProvenByADescendantOfThisConversation() {
        let dir = URL(fileURLWithPath: "/nonexistent-locks")
        XCTAssertFalse(CodexProcessIdentity.conversationMovedOn(
            from: parent, locks: dir, lineage: [:]))
    }

    func testExistingRecordedLockIsTheFastPathWithoutNeedingATty() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-locks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent(parent + ".lock"))
        let record = SessionOwnershipRecord(
            sessionId: parent, harness: CodexAdapter().id,
            pid: Int(ProcessInfo.processInfo.processIdentifier), paneTty: nil)

        XCTAssertEqual(CodexProcessIdentity.activeThreadId(for: record, locks: dir,
                                                           lineage: { [:] }), parent)
    }
}

/// A live Codex session carries a name and a busy state, or it sits grey and
/// anonymous beside Claude Code rows that do not.
///
/// Both were hard-coded from the day `liveNonRegistrySessions` was written,
/// honestly: Codex told us nothing then. It does now, and 30 Aug was the day
/// that stopped being an acceptable default, with two sessions visibly
/// "Working (24s)" showing as idle rows both called "Projects".
final class LiveNonRegistryDecorationTests: XCTestCase {

    private final class Store: SessionOwnershipStore, @unchecked Sendable {
        var records: [SessionOwnershipRecord] = []
        func record(_ r: SessionOwnershipRecord) { records.append(r) }
        func current(sessionId: String) -> SessionOwnershipRecord? {
            records.first { $0.sessionId == sessionId }
        }
        func remove(sessionId: String) { records.removeAll { $0.sessionId == sessionId } }
        func all() -> [SessionOwnershipRecord] { records }
    }

    /// A live pid is required, so the fixture uses this process: it is the one
    /// pid a test can be certain is alive.
    private func store(_ ids: [String]) -> Store {
        let s = Store()
        for id in ids {
            s.record(SessionOwnershipRecord(
                sessionId: id, harness: CodexAdapter().id,
                pid: Int(ProcessInfo.processInfo.processIdentifier),
                paneId: "%1", socketName: "tb", sessionName: "tb-x",
                paneTty: "/dev/ttys0", cwd: "/Users/x/Projects",
                attachedAt: Date()))
        }
        return s
    }

    func testAPromptWithNoStopYetReadsBusy() {
        let live = store(["01a05369"]).liveNonRegistrySessions(
            status: { _ in "busy" }, name: { _ in nil })
        XCTAssertEqual(live.first?.status, "busy")
    }

    /// Anything else, including a session that has never said a word, stays
    /// UNKNOWN. This case used to assert "idle", and the reasoning it carried
    /// was right about the wrong word: guessing "busy" from the absence of
    /// evidence is indeed how a lamp starts lying — but so is guessing "idle",
    /// and that is the guess this line was making. `GridAssembler` treats a
    /// process status as a witness that outranks the file, so "idle" here does
    /// not decline to answer, it testifies. Codex has no process-level status
    /// to testify with. Nil is the only honest value.
    func testNoAnswerStaysUnknown() {
        let live = store(["01a05369"]).liveNonRegistrySessions(
            status: { _ in nil }, name: { _ in nil })
        XCTAssertNil(live.first?.status)
    }

    func testTheNameIsCarried() {
        let live = store(["01a05338"]).liveNonRegistrySessions(
            status: { _ in nil }, name: { _ in "Audit Kopi fixes in codebase" })
        XCTAssertEqual(live.first?.name, "Audit Kopi fixes in codebase")
    }

    /// No name is nil, never a placeholder: `SessionRow.displayName` already
    /// owns the fallback, and a second one here would make two rules for one
    /// question.
    func testAnUnnamedSessionCarriesNoName() {
        let live = store(["01a05001"]).liveNonRegistrySessions(
            status: { _ in nil }, name: { _ in nil })
        XCTAssertNil(live.first?.name)
    }

    /// A call site that supplies neither closure asserts nothing about the
    /// session: no name, and no claim about what the process is doing.
    func testTheDefaultsClaimNothing() {
        let live = store(["01a05001"]).liveNonRegistrySessions()
        XCTAssertNil(live.first?.status)
        XCTAssertNil(live.first?.name)
    }
}

/// A `LiveSession` built from an ownership record keeps the harness the record
/// names. It used to drop it, and every downstream caller then had to guess —
/// which each one did by omission, as Claude. That is why the grid's
/// right-click could not end a Codex session: the ladder's identity guard was
/// told to expect `claude` and correctly refused a pid running `codex`.
final class LiveSessionCarriesItsHarnessTests: XCTestCase {

    func testANonRegistryRowKnowsItIsCodex() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = FileSessionOwnershipStore(
            fileURL: dir.appendingPathComponent("session-ownership.json"))
        // This process: alive by construction, so the row survives the filter.
        store.record(SessionOwnershipRecord(
            sessionId: "01a05338", harness: CodexAdapter().id,
            pid: Int(ProcessInfo.processInfo.processIdentifier)))

        let rows = store.liveNonRegistrySessions()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.harness, CodexAdapter().id)
        // And the fragment the termination ladder will be handed.
        XCTAssertEqual(
            KnownHarnesses.adapter(for: rows[0].harness).processCommandFragment, "codex")
    }

    /// The default is still right for everything `agents --json` returns.
    func testARegistryRowIsClaudeCode() throws {
        let json = Data("""
        [{"pid": 1, "sessionId": "abc", "cwd": "/tmp"}]
        """.utf8)
        let rows = try JSONDecoder().decode([LiveSession].self, from: json)
        XCTAssertEqual(rows.first?.harness, ClaudeCodeAdapter().id)
    }
}

/// "I don't know" must not be spelled "idle".
///
/// `GridAssembler` reads a process status as a WITNESS: a session whose file
/// looks busy goes grey if the process says idle, because a real process
/// reporting idle outranks a file that has not caught up. Codex has no
/// process-level status at all (`registersWithLiveness == false`), so an
/// invented "idle" is not a default — it is false testimony, and it silences
/// the only witness there is.
///
/// This cost Robert the same screenshot twice: a pane reading "Working (24s)"
/// beside a grey row, on 30 Aug and again on 01 Sep.
final class OwnershipDoesNotInventAStatusTests: XCTestCase {

    private func store() throws -> FileSessionOwnershipStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = FileSessionOwnershipStore(
            fileURL: dir.appendingPathComponent("session-ownership.json"))
        store.record(SessionOwnershipRecord(
            sessionId: "01a05dc7", harness: CodexAdapter().id,
            pid: Int(ProcessInfo.processInfo.processIdentifier)))
        return store
    }

    func testAnUninjectedStatusIsNil() throws {
        XCTAssertNil(try store().liveNonRegistrySessions().first?.status)
    }

    /// The whole point of the nil: a file that says working now reaches the lamp.
    func testAWorkingFileLightsBlueWhenNobodyClaimsIdle() throws {
        let live = try store().liveNonRegistrySessions().first
        let evidence = SessionActivity.Evidence(
            activity: .working, observedAt: Date(), modifiedAt: Date())
        let lamp = GridAssembler.lampAndReason(
            for: evidence, sessionId: "01a05dc7", live: live)
        XCTAssertEqual(lamp.lamp, .working)
    }

    /// And a silent one still reaches amber rather than going quietly grey.
    func testAStalledFileGoesAmberWhenNobodyClaimsIdle() throws {
        let live = try store().liveNonRegistrySessions().first
        let evidence = SessionActivity.Evidence(
            activity: .stalled(reason: "silent for 3h"), observedAt: Date(), modifiedAt: Date())
        let lamp = GridAssembler.lampAndReason(
            for: evidence, sessionId: "01a05dc7", live: live)
        XCTAssertEqual(lamp.lamp, .fault)
    }

    /// A caller with a REAL source can still say idle, and it still wins —
    /// this removes an invention, not the rule.
    func testAnInjectedIdleStillOutranksTheFile() throws {
        let live = try store().liveNonRegistrySessions(status: { _ in "idle" }).first
        let evidence = SessionActivity.Evidence(
            activity: .working, observedAt: Date(), modifiedAt: Date())
        let lamp = GridAssembler.lampAndReason(
            for: evidence, sessionId: "01a05dc7", live: live)
        XCTAssertEqual(lamp.lamp, .running)
    }
}
