import XCTest
@testable import TranquilityCore

final class SubprocessTests: XCTestCase {

    func testRunCapturesStdout() {
        let out = Subprocess.run("/bin/echo", ["hello"], timeout: 5)
        guard case .success(let text) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(text, "hello")
    }

    func testDeadlineKillsAndSaysSo() {
        let start = Date()
        let out = Subprocess.run("/bin/sleep", ["30"], timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        guard case .failure(let error) = out else { return XCTFail("expected timeout") }
        XCTAssertTrue(error.timedOut)
    }

    func testNonZeroExitCarriesStderr() {
        let out = Subprocess.run("/bin/sh", ["-c", "echo nope >&2; exit 3"], timeout: 5)
        guard case .failure(let error) = out else { return XCTFail("expected failure") }
        XCTAssertFalse(error.timedOut)
        XCTAssertTrue(error.message.contains("nope"))
    }

    func testStdinReachesChild() {
        let out = Subprocess.run("/bin/cat", [], stdin: Data("payload".utf8), timeout: 5)
        guard case .success(let text) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(text, "payload")
    }

    func testLargeOutputDoesNotDeadlock() {
        // A child writing far past the 64KB pipe buffer must not wedge
        // against a parent blocked in wait — the drain runs concurrently.
        let out = Subprocess.run("/bin/sh", ["-c", "yes x | head -100000"], timeout: 10)
        guard case .success(let text) = out else { return XCTFail("\(out)") }
        XCTAssertGreaterThan(text.count, 150_000)
    }

    // MARK: the liveness witness is the registry plus the kernel

    private func entry(_ pid: Int, _ id: String, kind: String? = "interactive",
                       procStart: Date? = nil, status: String? = "idle") -> SessionRegistry.Entry {
        SessionRegistry.Entry(pid: pid, sessionId: id, cwd: "/tmp", status: status, tmux: nil,
                              messagingSocketPath: nil, name: nil, updatedAt: nil, kind: kind,
                              procStart: procStart)
    }

    func testADeadPidIsNotARow() {
        // The reboot case: files outlive their processes, and the kernel is
        // the witness. [] here, never nil — nobody home is a positive finding.
        let rows = ClaudeAgentsCLI.witnessed(
            [entry(1, "a"), entry(2, "b")], isAlive: { $0 == 2 }, startTime: { _ in nil },
            trace: nil)
        XCTAssertEqual(rows.map(\.sessionId), ["b"])
    }

    func testAReusedPidIsNotARow() {
        // Alive, but not the process the file was written by: the kernel's
        // start time disagrees with the file's by more than two seconds.
        let recorded = Date(timeIntervalSince1970: 1_000_000)
        final class Traced: @unchecked Sendable { var lines: [String] = [] }
        let traced = Traced()
        let rows = ClaudeAgentsCLI.witnessed(
            [entry(1, "recycled", procStart: recorded),
             entry(2, "same", procStart: recorded)],
            isAlive: { _ in true },
            startTime: { $0 == 1 ? recorded.addingTimeInterval(3_600) : recorded.addingTimeInterval(1) },
            trace: { traced.lines.append($0) })
        XCTAssertEqual(rows.map(\.sessionId), ["same"])
        XCTAssertEqual(traced.lines.count, 1)
        XCTAssertTrue(traced.lines[0].contains("pid 1 is alive but is not recycled"), traced.lines[0])
    }

    func testAFileWithNoProcStartIsKeptOnThePidAlone() {
        // Older CLIs wrote no start time; missing means absent (seam rule 1),
        // and the pid alone is what every probe before this trusted.
        let rows = ClaudeAgentsCLI.witnessed(
            [entry(1, "old")], isAlive: { _ in true },
            startTime: { _ in Date() }, trace: nil)
        XCTAssertEqual(rows.map(\.sessionId), ["old"])
    }

    func testTheFilesWordsReachTheRowUnchanged() {
        // "bg" is the file's spelling of the CLI's "background"; `isBackground`
        // still reads the CLI's word. Status and waitingFor pass through as
        // written, which is the whole reason the CLI is no longer in the way.
        var e = entry(1, "job", kind: "bg", status: "waiting")
        e.waitingFor = "permission prompt"
        e.startedAt = 1_789_603_195_942
        let rows = ClaudeAgentsCLI.witnessed([e], isAlive: { _ in true },
                                             startTime: { _ in nil }, trace: nil)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].isBackground)
        XCTAssertEqual(rows[0].status, "waiting")
        XCTAssertEqual(rows[0].waitingFor, "permission prompt")
        XCTAssertEqual(rows[0].startedAt, 1_789_603_195_942)
    }

    func testAnUnreadableRegistryIsNilAndAnAbsentOneIsEmpty() throws {
        // nil means "could not determine"; [] means "nobody is home". The
        // difference is load-bearing: the sweep holds on nil and retires on [].
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-registry-\(UUID().uuidString)", isDirectory: true)
        XCTAssertEqual(SessionRegistry.read(in: base)?.count, 0, "a directory that was never made")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        XCTAssertEqual(SessionRegistry.read(in: base)?.count, 0, "an empty one")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: base.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.path)
            try? FileManager.default.removeItem(at: base)
        }
        XCTAssertNil(SessionRegistry.read(in: base), "one that exists and cannot be listed")
    }

    func testShellIsAReadyStatus() throws {
        // The registry's third word, rendered `busy` by the CLI (9 Sep). Between
        // turns with shells still running, the session takes a reply.
        let live = try JSONDecoder().decode(LiveSession.self, from: Data(
            #"{"pid": 1, "sessionId": "s", "status": "shell"}"#.utf8))
        XCTAssertEqual(Readiness.classify(live), .ready)
    }

    // MARK: shared readiness mapping

    func testClassifyCoversTheVocabulary() throws {
        func live(_ status: String, waitingFor: String? = nil) throws -> LiveSession {
            let wf = waitingFor.map { ", \"waitingFor\": \"\($0)\"" } ?? ""
            return try JSONDecoder().decode(LiveSession.self, from: Data(
                "{\"pid\": 1, \"sessionId\": \"s\", \"status\": \"\(status)\"\(wf)}".utf8))
        }
        XCTAssertEqual(Readiness.classify(nil), .notRegistered)
        XCTAssertEqual(try Readiness.classify(live("idle")), .ready)
        XCTAssertEqual(try Readiness.classify(live("busy")), .busy)
        XCTAssertEqual(try Readiness.classify(live("waiting", waitingFor: "dialog open")),
                       .waiting("dialog open"))
        XCTAssertEqual(try Readiness.classify(live("someday-new-status")), .notRegistered)
        // The dialog gate composes: waiting-at-dialog classifies as waiting
        // AND refuses dispatch, which is the #163 ruling surviving the dedupe.
        XCTAssertFalse(try Readiness.classify(live("waiting", waitingFor: "dialog open")).canDispatch)
        XCTAssertTrue(try Readiness.classify(live("waiting", waitingFor: "user input")).canDispatch)
    }

    // MARK: shared readiness mapping — Codex's rollout-tail half

    func testClassifyRolloutCoversTheVocabulary() {
        // Same shape as testClassifyCoversTheVocabulary above, different
        // ground truth: Codex has no `agents --json`, so `isBusy` off its
        // own rollout stands in for `LiveSession.status`.
        XCTAssertEqual(Readiness.classify(rollout: nil), .notRegistered)
        XCTAssertEqual(Readiness.classify(rollout: CodexRollout.Parsed(isBusy: false)), .ready)
        XCTAssertEqual(Readiness.classify(rollout: CodexRollout.Parsed(isBusy: true)), .busy)
        // Busy still dispatches (Codex queues mid-turn input, same as Claude
        // Code) — canDispatch composes for free, exactly as it does above.
        XCTAssertTrue(Readiness.classify(rollout: CodexRollout.Parsed(isBusy: true)).canDispatch)
        // No rollout found fails CLOSED, matching the absent-LiveSession
        // case: a session that hasn't written its first turn yet (or a
        // wrong id) must never read as safe to inject into.
        XCTAssertFalse(Readiness.classify(rollout: nil).canDispatch)
    }

    /// Found live, 26 Aug: a Codex session's FIRST-EVER dispatch — no
    /// rollout yet, since it has taken no turn — refused as `.notRegistered`
    /// on a session that was demonstrably alive and idle. The thread-writer
    /// lock (written at thread creation, independent of any turn) is what
    /// disambiguates "no turns yet" from "not found".
    func testClassifyRolloutTreatsALiveThreadWithNoRolloutYetAsReady() {
        XCTAssertEqual(
            Readiness.classify(rollout: nil, sessionId: "abc", liveThreadIds: ["abc"]),
            .ready)
        // Absent from the live-thread list too: the original, honest refusal
        // stands — this is not a blanket "no rollout means ready" escape
        // hatch, only a narrower one for a session known to exist.
        XCTAssertEqual(
            Readiness.classify(rollout: nil, sessionId: "abc", liveThreadIds: ["other"]),
            .notRegistered)
        // A real rollout always wins over the lock-file fallback — busy/ready
        // classification is unchanged once there is something to tail.
        XCTAssertEqual(
            Readiness.classify(rollout: CodexRollout.Parsed(isBusy: true),
                                sessionId: "abc", liveThreadIds: ["abc"]),
            .busy)
    }

    // MARK: ProcessProbe.matchPid — the real agent pid behind a tmux pane

    func testMatchPidFindsTheRealAgentProcessVerbatim() {
        // Captured live, 22 Aug: `codex resume <id>` sitting directly on a
        // tty after zsh's own last-command exec optimization replaced the
        // wrapping shell — confirming the process this needs to find is
        // not tmux's own `#{pane_pid}`.
        let ps = "13928 codex resume 01a02b49-fd58-7852-8cfe-25ea386db7a3"
        XCTAssertEqual(
            ProcessProbe.matchPid(psOutput: ps, containing: "01a02b49-fd58-7852-8cfe-25ea386db7a3"),
            13928)
    }

    func testMatchPidPrefersTheParentOverItsOwnChildren() {
        // Captured live, 22 Aug: a resumed Codex process spawning its own
        // MCP-server children on the SAME tty. A needle match on the
        // session id — present only in the parent's argv — is what tells
        // them apart; a bare "codex"-prefix match could not.
        let ps = """
          3798 codex resume 01a02a91-e209-7bc0-a873-36127f9586e8
          3884 /Applications/Codex.app/Contents/Resources/cua_node/bin/node_repl
          3885 npm exec tsx /Users/robertnowell/Projects/konid/src/index.ts
        """
        XCTAssertEqual(
            ProcessProbe.matchPid(psOutput: ps, containing: "01a02a91-e209-7bc0-a873-36127f9586e8"),
            3798)
    }

    func testMatchPidReturnsNilWhenNothingMatches() {
        XCTAssertNil(ProcessProbe.matchPid(psOutput: "1 /sbin/launchd", containing: "abc-123"))
        XCTAssertNil(ProcessProbe.matchPid(psOutput: "", containing: "abc-123"))
    }

    func testMatchPidRefusesAnEmptyNeedle() {
        // An empty needle would match every row's command line — the exact
        // shape of "find literally anything," never a real answer.
        XCTAssertNil(ProcessProbe.matchPid(psOutput: "1 codex resume abc", containing: ""))
    }

    func testMatchPidIgnoresMalformedLines() {
        XCTAssertNil(ProcessProbe.matchPid(psOutput: "garbage\n\nnot-a-pid codex", containing: "codex"))
    }
}
