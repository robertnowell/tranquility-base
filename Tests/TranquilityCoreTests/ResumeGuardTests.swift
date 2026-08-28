import XCTest
@testable import TranquilityCore

/// The guard that stands between GO TO AGENT and a forked transcript.
///
/// Every fixture here is real `ps` text captured on 27 Aug, from the machine
/// where the loss was measured — including the tmux server line that would
/// have made the guard refuse every resume forever if it were counted.
final class ResumeGuardTests: XCTestCase {

    private let sid = "e73e8975-9f7a-429a-aa0a-976791d1d841"

    /// The failure exactly as it happened: three live processes, one id.
    func testFindsEveryDuplicateResume() {
        let ps = """
        13945 claude --dangerously-skip-permissions --resume \(sid)
        14460 claude --dangerously-skip-permissions --resume \(sid)
        14769 claude --dangerously-skip-permissions --resume \(sid)
        71403 claude --dangerously-skip-permissions
        """
        let v = ResumeGuard.classify(psOutput: ps, sessionId: sid, exempt: [])
        XCTAssertEqual(v.holders.map(\.pid), [13945, 14460, 14769])
    }

    func testClearWhenNobodyHoldsTheId() {
        let ps = """
        71403 claude --dangerously-skip-permissions
        14018 claude --dangerously-skip-permissions --resume 2d7c3314-f7f9-4ae6-9c73-2d506f3cda47
        """
        XCTAssertEqual(ResumeGuard.classify(psOutput: ps, sessionId: sid, exempt: []), .clear)
    }

    /// The trap that would have made this guard worse than nothing: the tmux
    /// SERVER keeps the argv of the new-session that started it, so it still
    /// advertises a `--resume` long after that pane has exited. Counting it
    /// would mean no session could ever be revived a second time.
    func testTmuxServerArgvIsNotAHolder() {
        let ps = """
        3636 /opt/homebrew/bin/tmux -L tb new-session -d -s tb-ae813b43 -x 220 -y 50 \
        /bin/zsh -c cd '/Users/robertnowell' && arch -arm64 claude \
        --dangerously-skip-permissions '--resume' '\(sid)'
        """
        XCTAssertEqual(ResumeGuard.classify(psOutput: ps, sessionId: sid, exempt: []), .clear)
    }

    func testBareTmuxBinaryIsAlsoRecognised() {
        XCTAssertTrue(ResumeGuard.isTmuxServer("tmux -L tb new-session -d --resume \(sid)"))
        XCTAssertTrue(ResumeGuard.isTmuxServer("/opt/homebrew/bin/tmux attach -t tb-90c65706"))
        XCTAssertFalse(ResumeGuard.isTmuxServer("claude --resume \(sid)"))
        // A harness resuming inside a directory that merely contains the word.
        XCTAssertFalse(ResumeGuard.isTmuxServer("/usr/bin/claude --resume \(sid) # /opt/tmux"))
    }

    /// `OwnershipTransfer` ends the hand-started process and then resumes it.
    /// Its corpse must not block its own restart.
    func testEndedPidIsExempt() {
        let ps = "14460 claude --dangerously-skip-permissions --resume \(sid)"
        XCTAssertEqual(
            ResumeGuard.classify(psOutput: ps, sessionId: sid, exempt: [14460]), .clear)
        XCTAssertEqual(
            ResumeGuard.classify(psOutput: ps, sessionId: sid, exempt: [99999]).holders.count, 1)
    }

    /// Codex spells resume differently; the id is the needle either way.
    func testMatchesCodexResumeArgv() {
        let ps = "49581 codex --dangerously-bypass-approvals-and-sandbox resume \(sid)"
        XCTAssertEqual(ResumeGuard.classify(psOutput: ps, sessionId: sid, exempt: []).holders.count, 1)
    }

    func testEmptySessionIdNeverBlocks() {
        XCTAssertEqual(ResumeGuard.classify(psOutput: "1 claude", sessionId: "", exempt: []), .clear)
    }

    /// Malformed rows are skipped, not crashed on.
    func testIgnoresUnparseableRows() {
        let ps = """
        not-a-pid claude --resume \(sid)

        14460 claude --resume \(sid)
        """
        XCTAssertEqual(ResumeGuard.classify(psOutput: ps, sessionId: sid, exempt: []).holders.map(\.pid), [14460])
    }

    /// The refusal has to give the reader somewhere to go.
    func testRefusalNamesThePids() {
        let msg = ResumeGuard.refusal(
            sessionId: sid, holders: [.init(pid: 13945, command: "claude")])
        XCTAssertTrue(msg.contains("pid 13945"))
        XCTAssertTrue(msg.contains("e73e8975"))
        XCTAssertTrue(msg.contains("fork"))
        // House copy: no em dash in a string that reaches a card (rule, 18 Aug).
        XCTAssertFalse(msg.contains("\u{2014}"), "refusal copy must not carry an em dash")
    }

    /// An unreadable process table is not evidence of absence.
    func testUnreadableTableIsTreatedAsContended() {
        // `classify` over empty text is clear; the fail-closed decision lives
        // in `check`, so this pins the contract the refusal message states.
        let msg = ResumeGuard.refusal(sessionId: sid, holders: [])
        XCTAssertTrue(msg.contains("could not be read"))
    }
}

/// The false positives that would turn this guard into the bug it prevents.
extension ResumeGuardTests {

    /// Caught live before shipping: a wrapper shell whose argv carried the id
    /// inside a heredoc, running no harness, mentioning `.claude` in a path.
    func testShellThatMerelyMentionsTheIdIsNotAHolder() {
        let ps = "58442 /bin/zsh -c source /Users/robertnowell/.claude/shell-snapshots/"
            + "snapshot-zsh-1787877045235.sh && grep e73e8975-9f7a-429a-aa0a-976791d1d841 out.txt"
        XCTAssertEqual(
            ResumeGuard.classify(psOutput: ps,
                                 sessionId: "e73e8975-9f7a-429a-aa0a-976791d1d841",
                                 exempt: []),
            .clear)
    }

    func testReadingATranscriptIsNotAHolder() {
        let sid = "e73e8975-9f7a-429a-aa0a-976791d1d841"
        for cmd in ["cat /Users/robertnowell/.claude/projects/-Users-robertnowell/\(sid).jsonl",
                    "grep -c foo \(sid).jsonl",
                    "/usr/bin/python3 analyze.py \(sid)"] {
            XCTAssertEqual(ResumeGuard.classify(psOutput: "999 \(cmd)", sessionId: sid, exempt: []),
                           .clear, cmd)
        }
    }

    /// The real launch line, quoting and all, must still be caught.
    func testQuotedLaunchLineIsAHolder() {
        let sid = "e73e8975-9f7a-429a-aa0a-976791d1d841"
        let ps = "14769 /bin/zsh -c export PATH='/opt/homebrew/bin'; cd '/Users/robertnowell' "
            + "&& arch -arm64 claude --dangerously-skip-permissions '--resume' '\(sid)'"
        XCTAssertEqual(ResumeGuard.classify(psOutput: ps, sessionId: sid, exempt: []).holders.count, 1)
    }

    func testHarnessFragmentsComeFromTheAdapters() {
        XCTAssertTrue(ResumeGuard.runsAHarness("claude --resume x"))
        XCTAssertTrue(ResumeGuard.runsAHarness("/opt/homebrew/bin/codex resume x"))
        XCTAssertFalse(ResumeGuard.runsAHarness("vim /Users/x/.claude/projects/x.jsonl"))
        XCTAssertFalse(ResumeGuard.runsAHarness("bash -c 'echo claude-code'"))
    }
}

/// The race the `ps` scan cannot close on its own.
extension ResumeGuardTests {

    /// 18082 and 18103 were launched one second apart. A scan takes ~120ms
    /// and a pane takes longer than a second to reach an exec'd harness, so
    /// both calls scanned a table that showed neither of them. Exactly one
    /// of N simultaneous claims may win.
    func testOnlyOneOfManySimultaneousClaimsWins() {
        let id = "race-test-\(UUID().uuidString)"
        let attempts = 32
        let won = NSCounter()
        let group = DispatchGroup()
        var claims: [ResumeGuard.Claim] = []
        let claimsLock = NSLock()
        for _ in 0..<attempts {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                if case .success(let c) = ResumeGuard.claim(sessionId: id) {
                    won.increment()
                    // Hold it, exactly as `resumeTmux` does for its duration.
                    claimsLock.lock(); claims.append(c); claimsLock.unlock()
                }
            }
        }
        group.wait()
        XCTAssertEqual(won.value, 1,
                       "\(won.value) of \(attempts) concurrent resumes were allowed to spawn")
        claims.forEach { $0.release() }
    }

    /// Releasing has to actually free the id, or one refusal becomes permanent.
    func testReleaseFreesTheIdForTheNextResume() {
        let id = "release-test-\(UUID().uuidString)"
        guard case .success(let first) = ResumeGuard.claim(sessionId: id) else {
            return XCTFail("the first claim on a fresh id must succeed")
        }
        guard case .failure = ResumeGuard.claim(sessionId: id) else {
            return XCTFail("a second claim while the first is held must be refused")
        }
        first.release()
        guard case .success(let third) = ResumeGuard.claim(sessionId: id) else {
            return XCTFail("after release the id must be claimable again")
        }
        third.release()
    }

    /// Double release must not corrupt the set — `resumeTmux` releases via
    /// `defer` and `Claim.deinit` releases too.
    func testDoubleReleaseIsHarmless() {
        let id = "double-release-\(UUID().uuidString)"
        guard case .success(let c) = ResumeGuard.claim(sessionId: id) else {
            return XCTFail("claim must succeed")
        }
        c.release(); c.release(); c.release()
        guard case .success(let again) = ResumeGuard.claim(sessionId: id) else {
            return XCTFail("the id must be free after release")
        }
        again.release()
    }
}

/// Minimal thread-safe counter — the test needs one and the package has none.
final class NSCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func increment() { lock.lock(); n += 1; lock.unlock() }
}
