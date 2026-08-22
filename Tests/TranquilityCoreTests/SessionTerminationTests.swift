import XCTest
@testable import TranquilityCore

/// A process that exists on paper, so the ladder's decisions can be asserted
/// without killing anything. Scripted by rung: what `ps` says at each look, and
/// what the process does when signalled.
private final class FakeControl: SessionTermination.ProcessControlling, @unchecked Sendable {
    /// Identities the ladder will see, in order. The last one repeats forever,
    /// which is what "and it stays that way" looks like.
    var identities: [SessionTermination.Identity?]
    var deliverable: Set<Int32>
    /// Signal → the identity the process presents once it has been delivered.
    var onSignal: [Int32: SessionTermination.Identity?] = [:]

    private(set) var sent: [(signal: Int32, target: SessionTermination.Target)] = []
    private(set) var looks = 0
    private var clock = 0

    init(identities: [SessionTermination.Identity?],
         deliverable: Set<Int32> = [SIGTERM, SIGKILL]) {
        self.identities = identities
        self.deliverable = deliverable
    }

    func identity(of pid: Int) -> SessionTermination.Identity? {
        defer { looks += 1 }
        return identities[min(looks, identities.count - 1)]
    }

    func send(_ signal: Int32, to target: SessionTermination.Target) -> Bool {
        guard deliverable.contains(signal) else { return false }
        sent.append((signal, target))
        if let after = onSignal[signal] {
            // Everything from here on shows the post-signal state.
            identities = [after]
            looks = 0
        }
        return true
    }

    func waitBriefly(_ seconds: TimeInterval) { clock += Int(seconds * 1000) }
    func nowMs() -> Int { clock }
}

private func claude(pid: Int = 4242, pgid: Int = 4242,
                    tty: String? = "/dev/ttys012") -> SessionTermination.Identity {
    SessionTermination.Identity(command: "claude", pgid: pgid, tty: tty)
}

private func codex(pid: Int = 71800, pgid: Int = 71800,
                   tty: String? = "/dev/ttys003") -> SessionTermination.Identity {
    SessionTermination.Identity(command: "codex", pgid: pgid, tty: tty)
}

final class SessionTerminationTests: XCTestCase {

    // MARK: - The ordinary case

    func testDiesOnSigtermAndSignalsTheProcessGroup() {
        let control = FakeControl(identities: [claude()])
        control.onSignal[SIGTERM] = .some(nil)

        let outcome = SessionTermination.end(
            pid: 4242, named: "promotions-31", control: control)

        XCTAssertEqual(outcome, .died(rung: .term, afterMs: 250,
                                      target: .group(pgid: 4242)))
        XCTAssertEqual(control.sent.count, 1)
        XCTAssertEqual(control.sent.first?.signal, SIGTERM)
        // The group, not the pid: that is what takes the MCP children with it.
        XCTAssertEqual(control.sent.first?.target, .group(pgid: 4242))
        XCTAssertTrue(outcome.isGone)
    }

    /// Claude not leading its group is the one case where a negative-pid signal
    /// could reach past this session, so it must degrade to the narrow kill.
    func testSignalsTheBareProcessWhenItDoesNotLeadItsGroup() {
        let control = FakeControl(identities: [claude(pid: 4242, pgid: 99)])
        control.onSignal[SIGTERM] = .some(nil)

        let outcome = SessionTermination.end(pid: 4242, named: "odd", control: control)

        XCTAssertEqual(control.sent.first?.target, .process(pid: 4242))
        if case .died(_, _, let target) = outcome {
            XCTAssertEqual(target, .process(pid: 4242))
        } else {
            XCTFail("expected a death, got \(outcome)")
        }
    }

    // MARK: - Escalation

    func testEscalatesToSigkillWhenSigtermIsIgnored() {
        let control = FakeControl(identities: [claude()])
        control.onSignal[SIGKILL] = .some(nil)   // only KILL lands

        let outcome = SessionTermination.end(
            pid: 4242, named: "wedged", control: control,
            policy: .init(termWindow: 1, killWindow: 1, poll: 0.25))

        XCTAssertEqual(control.sent.map(\.signal), [SIGTERM, SIGKILL])
        if case .died(let rung, _, _) = outcome {
            XCTAssertEqual(rung, .kill)
        } else {
            XCTFail("expected a death on SIGKILL, got \(outcome)")
        }
    }

    func testReportsSurvivalWhenNeitherSignalLands() {
        let control = FakeControl(identities: [claude()])   // never dies

        let outcome = SessionTermination.end(
            pid: 4242, named: "immortal", control: control,
            policy: .init(termWindow: 1, killWindow: 1, poll: 0.5))

        XCTAssertEqual(outcome, .survived)
        XCTAssertFalse(outcome.isGone)
        XCTAssertEqual(control.sent.map(\.signal), [SIGTERM, SIGKILL])
    }

    /// TERM landing just after its window closes must not be credited to a
    /// SIGKILL that was never sent.
    func testCreditsSigtermWhenItWinsAfterItsWindow() {
        var looks: [SessionTermination.Identity?] = Array(repeating: claude(), count: 6)
        looks.append(nil)                    // dead by the pre-SIGKILL look
        let control = FakeControl(identities: looks)

        let outcome = SessionTermination.end(
            pid: 4242, named: "slow", control: control,
            policy: .init(termWindow: 1, killWindow: 1, poll: 0.25))

        if case .died(let rung, _, _) = outcome {
            XCTAssertEqual(rung, .term)
        } else {
            XCTFail("expected a late SIGTERM death, got \(outcome)")
        }
        XCTAssertEqual(control.sent.map(\.signal), [SIGTERM],
                       "SIGKILL must not be sent once the process is gone")
    }

    // MARK: - The identity guard

    func testRefusesAPidThatIsNotAClaudeSession() {
        let control = FakeControl(identities: [
            SessionTermination.Identity(command: "Xcode", pgid: 4242, tty: "/dev/ttys012")])

        let outcome = SessionTermination.end(pid: 4242, named: "stale row", control: control)

        guard case .refused(let why) = outcome else {
            return XCTFail("expected a refusal, got \(outcome)")
        }
        XCTAssertTrue(why.contains("Xcode"), why)
        XCTAssertTrue(control.sent.isEmpty, "nothing may be signalled after a refusal")
    }

    func testRefusesAClaudeOnADifferentTerminalThanTheRowWasSeenOn() {
        let control = FakeControl(identities: [claude(tty: "/dev/ttys999")])

        let outcome = SessionTermination.end(
            pid: 4242, named: "recycled", expectedTty: "/dev/ttys012", control: control)

        guard case .refused = outcome else {
            return XCTFail("expected a refusal, got \(outcome)")
        }
        XCTAssertTrue(control.sent.isEmpty)
    }

    /// The hazard the six-second cache creates: our process dies, the pid is
    /// recycled, and the ladder must read that as the death it asked for rather
    /// than escalate onto a stranger.
    func testTreatsAPidRecycledMidLadderAsTheDeathItAskedFor() {
        let control = FakeControl(identities: [
            claude(),                                                   // opening guard
            claude(),                                                   // pre-SIGTERM look
            SessionTermination.Identity(command: "node", pgid: 4242, tty: "/dev/ttys012"),
        ])

        let outcome = SessionTermination.end(
            pid: 4242, named: "recycled", control: control,
            policy: .init(termWindow: 1, killWindow: 1, poll: 0.25))

        if case .died(let rung, _, _) = outcome {
            XCTAssertEqual(rung, .term)
        } else {
            XCTFail("expected the recycled pid to read as a death, got \(outcome)")
        }
        XCTAssertEqual(control.sent.map(\.signal), [SIGTERM],
                       "a recycled pid must never be escalated onto")
    }

    func testAnAlreadyDeadSessionIsSuccessNotFailure() {
        let control = FakeControl(identities: [nil])

        let outcome = SessionTermination.end(pid: 4242, named: "ghost", control: control)

        XCTAssertEqual(outcome, .alreadyGone)
        XCTAssertTrue(outcome.isGone)
        XCTAssertTrue(control.sent.isEmpty)
    }

    func testUndeliverableSignalWithTheProcessStillThereIsARefusal() {
        let control = FakeControl(identities: [claude()], deliverable: [])

        let outcome = SessionTermination.end(pid: 4242, named: "not ours", control: control)

        guard case .refused(let why) = outcome else {
            return XCTFail("expected a refusal, got \(outcome)")
        }
        XCTAssertTrue(why.contains("process group 4242"), why)
    }

    // MARK: - Per-harness expectedCommand (generalized 22 Aug: the guard was
    // hardcoded to Claude Code, and live-tested REFUSED to end a genuine,
    // ownership-verified Codex session — "pid 71800 is `codex`, not a Claude
    // session" — until this parameter existed.)

    func testEndsACodexProcessWhenToldToExpectCodex() {
        let control = FakeControl(identities: [codex()])
        control.onSignal[SIGTERM] = .some(nil)

        let outcome = SessionTermination.end(
            pid: 71800, named: "01a02b5f", expectedCommand: "codex", control: control)

        XCTAssertEqual(outcome, .died(rung: .term, afterMs: 250,
                                      target: .group(pgid: 71800)))
        XCTAssertTrue(outcome.isGone)
    }

    func testDefaultExpectedCommandStillRefusesACodexProcess() {
        // The default is "claude" so every pre-existing caller (Claude
        // Code's own terminate paths) is byte-for-byte unchanged by this
        // generalization — it must still refuse a Codex pid it never asked
        // to be told about.
        let control = FakeControl(identities: [codex()])

        let outcome = SessionTermination.end(pid: 71800, named: "01a02b5f", control: control)

        guard case .refused(let why) = outcome else {
            return XCTFail("expected a refusal, got \(outcome)")
        }
        XCTAssertTrue(why.contains("not a claude session"), why)
    }

    func testExpectedCommandCodexRefusesAClaudeProcess() {
        // The guard still works the other direction: a stray Claude pid must
        // not be signalled by a caller that believes it is ending Codex.
        let control = FakeControl(identities: [claude()])

        let outcome = SessionTermination.end(
            pid: 4242, named: "not-codex", expectedCommand: "codex", control: control)

        guard case .refused(let why) = outcome else {
            return XCTFail("expected a refusal, got \(outcome)")
        }
        XCTAssertTrue(why.contains("not a codex session"), why)
    }

    // MARK: - Reading ps

    func testParsesThePsLineIntoAnIdentity() {
        let id = LiveProcessControl.parse(
            psLine: "97590 ttys000 /Users/robert/.local/bin/claude")
        XCTAssertEqual(id?.pgid, 97590)
        XCTAssertEqual(id?.tty, "/dev/ttys000")
        XCTAssertEqual(id?.command, "claude")
        XCTAssertEqual(id?.matches(expected: "claude"), true)
    }

    func testAProcessWithNoControllingTerminalParsesWithNoTty() {
        let id = LiveProcessControl.parse(psLine: "412 ?? /usr/libexec/somed")
        XCTAssertNil(id?.tty)
        XCTAssertEqual(id?.command, "somed")
        XCTAssertEqual(id?.matches(expected: "claude"), false)
    }

    func testIdentityMatchesIsPerHarnessNotHardcodedToClaude() {
        // The exact regression this generalization exists to prevent: a
        // genuine Codex process must be recognized as Codex, not refused as
        // "not a Claude session" — live-tested 22 Aug against a real
        // codex-cli 0.149.0 resume before this fix landed.
        let id = LiveProcessControl.parse(psLine: "71800 ttys003 codex")
        XCTAssertEqual(id?.matches(expected: "codex"), true)
        XCTAssertEqual(id?.matches(expected: "claude"), false)
    }

    func testGarbageFromPsIsNotAnIdentity() {
        XCTAssertNil(LiveProcessControl.parse(psLine: ""))
        XCTAssertNil(LiveProcessControl.parse(psLine: "no-pgid ttys000 claude"))
    }

    /// `identity(of:)` itself, not just its parser — against a real `ps`,
    /// live. Routed through `Subprocess.run` (codebase audit, 21 Aug: it used
    /// to be a raw, unbounded `Process`, the one spawn in this repo M1 didn't
    /// catch, on the path re-read before every rung of the kill ladder). This
    /// is the swap that matters: proving the bounded runner still finds this
    /// test's own process, not just that the string parser is unchanged.
    func testLiveIdentityFindsTheRunningTestProcess() {
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        let id = LiveProcessControl().identity(of: pid)
        XCTAssertNotNil(id, "a live pid must resolve to an identity")
        XCTAssertGreaterThan(id?.pgid ?? 0, 0)
    }

    func testLiveIdentityIsNilForADeadPid() {
        // A pid astronomically unlikely to be live; `ps -p` exits non-zero
        // and `Subprocess.run` must surface that as .failure, same as the
        // raw `Process` this replaced did via `terminationStatus`.
        XCTAssertNil(LiveProcessControl().identity(of: 999_999))
    }
}
