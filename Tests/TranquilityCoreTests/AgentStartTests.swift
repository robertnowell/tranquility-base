import XCTest
@testable import TranquilityCore

/// `AgentStart.ensureRunning`: the one function every door calls (ruled
/// 14 Nov 2026). Every case with no proof the process is gone starts nothing.
final class AgentStartTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
    private let pane = TmuxPaneAddress(socketName: "tb", paneId: "%7",
                                       sessionName: "tb-fixture", paneTty: "/dev/ttys998")
    private let claude = ClaudeCodeAdapter().id
    private let codex = CodexAdapter().id
    private var here: String { SessionDiscovery.landingDirectory(for: NSTemporaryDirectory())! }

    /// Each test its own id: the reservation is process-wide.
    private func id(_ name: String = #function) -> String { "agent-start-\(name)" }

    private func row(_ id: String, _ liveness: SessionDiscovery.Liveness, revivable: Bool = true,
                     harness: String? = nil) -> SessionDiscovery.Session {
        SessionDiscovery.Session(sessionId: id, cwd: NSTemporaryDirectory(),
                                 transcriptPath: "/tmp/t.jsonl", title: nil,
                                 lastActivityAt: Date(), answered: false, activity: nil,
                                 liveness: liveness, revivable: revivable,
                                 harness: harness ?? claude)
    }

    private func witness(
        _ found: SessionDiscovery.Session?, owns: Bool = false,
        stranger: ResumeGuard.Holder? = nil, starts: Counter,
        resume: Result<TmuxPaneAddress, ScriptError>? = nil,
        attach: Result<SessionLauncher.CodexResumeOutcome, ScriptError> = .success(.attached(tty: "/dev/ttys998")),
        adopt: TmuxPaneAddress? = nil, pid: Int? = 4242
    ) -> AgentStart.Witness {
        let resumed = resume ?? .success(pane)
        return AgentStart.Witness(
            discover: { _ in found },
            ownsLiveProcess: { _ in owns },
            stranger: { _, _ in stranger },
            resume: { _, _ in starts.bump(); return resumed },
            attach: { _, _ in starts.bump(); return attach },
            adopt: { _, _ in adopt },
            awaitPid: { _ in pid })
    }

    // MARK: - It starts

    func testAGoneAgentIsStartedOnceAndTheCallerHearsFirst() {
        let starts = Counter(), heard = Counter()
        let outcome = AgentStart.ensureRunning(
            sessionId: id(), unasked: false,
            witness: witness(row(id(), .gone), starts: starts), willStart: { heard.bump() })
        XCTAssertEqual(outcome, .started(how: .resumed, pane: pane, pid: 4242, cwd: here))
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(heard.count, 1)
        XCTAssertFalse(ResumeGuard.isInFlight(id()), "the reservation ends with the call")
    }

    func testAStartThatNeverRegistersSaysSo() {
        let outcome = AgentStart.ensureRunning(
            sessionId: id(), unasked: false,
            witness: witness(row(id(), .gone), starts: Counter(), pid: nil))
        XCTAssertEqual(outcome, .started(how: .resumed, pane: pane, pid: nil, cwd: here))
        XCTAssertEqual(outcome.word, "started_unregistered")
    }

    /// Ruled 14 Nov: the Codex path, in place of "not a Claude Code session".
    func testAHarnessWithNoRegistryIsAttachedNotRefused() {
        let starts = Counter()
        let outcome = AgentStart.ensureRunning(
            sessionId: id(), unasked: true,
            witness: witness(row(id(), .unknown, harness: codex), starts: starts))
        XCTAssertEqual(outcome, .started(how: .attached, pane: nil, pid: 4242, cwd: here))
        XCTAssertEqual(starts.count, 1)
    }

    func testARunningCodexThisAppLostIsAdopted() {
        let outcome = AgentStart.ensureRunning(
            sessionId: id(), unasked: false,
            witness: witness(row(id(), .unknown, harness: codex), starts: Counter(),
                             attach: .success(.alreadyLive), adopt: pane))
        XCTAssertEqual(outcome, .started(how: .adopted, pane: pane, pid: 4242, cwd: here))
    }

    // MARK: - It starts nothing

    /// The 21 Sep race, and the hole the reply's first version had: the
    /// tap's reservation is in `intents`, which the guard's claim never reads.
    func testASecondCallerWhileADoorHoldsTheIdStartsNothing() {
        let starts = Counter(), heard = Counter()
        XCTAssertTrue(ResumeGuard.beginIntent(id()))
        defer { ResumeGuard.endIntent(id()) }
        let outcome = AgentStart.ensureRunning(
            sessionId: id(), unasked: true,
            witness: witness(row(id(), .gone), starts: starts), willStart: { heard.bump() })
        XCTAssertEqual(outcome, .joined)
        XCTAssertEqual(starts.count, 0)
        XCTAssertEqual(heard.count, 0)
        XCTAssertTrue(ResumeGuard.isInFlight(id()), "the first door's reservation is untouched")
    }

    func testALiveAgentStartsNothing() {
        let starts = Counter()
        XCTAssertEqual(AgentStart.ensureRunning(
            sessionId: id(), unasked: false,
            witness: witness(row(id(), .live, revivable: false), starts: starts)), .running)
        XCTAssertEqual(starts.count, 0)
    }

    /// A registry that could not be read is not an empty machine.
    func testAnUnreadableRegistryStartsNothing() {
        let starts = Counter()
        guard case .unknown = AgentStart.ensureRunning(
            sessionId: id(), unasked: false,
            witness: witness(row(id(), .unknown, revivable: false), starts: starts))
        else { return XCTFail("unknown liveness must not start a process") }
        XCTAssertEqual(starts.count, 0)
    }

    /// One decision on the launch record, for every caller and both harnesses.
    func testAProcessThisAppLaunchedIsRunningWhateverTheRegistrySays() {
        let starts = Counter()
        for harness in [claude, codex] {
            XCTAssertEqual(AgentStart.ensureRunning(
                sessionId: id(), unasked: false,
                witness: witness(row(id(), .gone, harness: harness), owns: true, starts: starts)),
                .running)
        }
        XCTAssertEqual(starts.count, 0)
    }

    func testNoTranscriptAndNoDirectoryAreRefusedWithoutAStart() {
        let starts = Counter()
        XCTAssertEqual(AgentStart.ensureRunning(
            sessionId: id(), unasked: false, witness: witness(nil, starts: starts)),
            .refused(.notOnDisk, cwd: nil))
        guard case .refused(.directoryGone, _) = AgentStart.ensureRunning(
            sessionId: id(), unasked: false,
            witness: witness(row(id(), .gone, revivable: false), starts: starts))
        else { return XCTFail("no directory to land in must refuse") }
        XCTAssertEqual(starts.count, 0)
    }

    /// Ruled 14 Nov: a failed process scan is "unknown", never a refusal.
    func testAnUnreadableProcessTableIsUnknownNotARefusal() {
        let unreadable = ScriptError(message: "the process table could not be read",
                                     worthRetrying: false, scanUnreadable: true)
        guard case .unknown = AgentStart.ensureRunning(
            sessionId: id(), unasked: false,
            witness: witness(row(id(), .gone), starts: Counter(), resume: .failure(unreadable)))
        else { return XCTFail("an unreadable scan must not become a refusal") }
    }

    func testTheGuardSaysWhichCaseAnEmptyHolderListIs() {
        XCTAssertTrue(ResumeGuard.Verdict.alreadyResuming([]) == .alreadyResuming([]))
        XCTAssertFalse(ResumeGuard.Verdict.inFlight == .alreadyResuming([]))
    }

    func testAProcessHoldingTheIdIsNamedAndNothingElseStarts() {
        let holder = ResumeGuard.Holder(pid: 31293, command: "claude --resume x")
        let held = ScriptError(message: "already running", worthRetrying: false,
                               alreadyRunning: [holder])
        XCTAssertEqual(AgentStart.ensureRunning(
            sessionId: id(), unasked: false,
            witness: witness(row(id(), .gone), starts: Counter(), resume: .failure(held))),
            .heldBy([holder], cwd: here))
    }

    /// 11 Sep: a pane on a question was adopted as resumed, and the next
    /// dictation was typed into the menu.
    func testAPaneOnAQuestionIsNeverAdopted() {
        let outcome = AgentStart.ensureRunning(
            sessionId: id(), unasked: false,
            witness: witness(row(id(), .unknown, harness: codex), starts: Counter(),
                             attach: .success(.stoppedOnPrompt(says: "Update?", screen: "1. Update now",
                                                               pane: pane)),
                             adopt: pane))
        XCTAssertEqual(outcome, .waitingOnQuestion(says: "Update?", screen: "1. Update now", pane: pane))
    }

    // MARK: - A start nobody tapped for

    /// Measured 12 Nov: a hand-started agent has no id in its command line.
    func testAnUnaskedStartStopsBesideAProcessNothingAccountsFor() {
        let starts = Counter(), heard = Counter()
        let stranger = ResumeGuard.Holder(pid: 777, command: "claude")
        XCTAssertEqual(AgentStart.ensureRunning(
            sessionId: id(), unasked: true,
            witness: witness(row(id(), .gone), stranger: stranger, starts: starts),
            willStart: { heard.bump() }),
            .heldBy([stranger], cwd: here))
        XCTAssertEqual(starts.count, 0)
        XCTAssertEqual(heard.count, 0)
    }

    func testATapIsNotHeldToThat() {
        let starts = Counter()
        let stranger = ResumeGuard.Holder(pid: 777, command: "claude")
        guard case .started = AgentStart.ensureRunning(
            sessionId: id(), unasked: false,
            witness: witness(row(id(), .gone), stranger: stranger, starts: starts))
        else { return XCTFail("a person's tap starts it") }
        XCTAssertEqual(starts.count, 1)
    }

    // MARK: - What a reply hears

    func testAReplyGoesOnAsBeforeWheneverThereIsNoProof() {
        for outcome: AgentStart.Outcome in [
            .running, .unknown("x"), .heldBy([], cwd: "/"), .refused(.notOnDisk, cwd: nil),
            .refused(.liveElsewhere, cwd: "/"),
        ] {
            guard case .notGone = outcome.forReply
            else { return XCTFail("\(outcome) must not stop or start a reply") }
        }
        XCTAssertEqual(AgentStart.Outcome.joined.forReply, .started(nil))
        XCTAssertEqual(AgentStart.Outcome.refused(.directoryGone, cwd: nil).forReply,
                       .refused("its directory is gone"))
    }

    // MARK: - The directory guard's pure halves

    func testOnlyAProcessWhoseCommandIsTheHarnessCounts() {
        let ps = """
          101 claude
          102 /opt/homebrew/bin/claude --resume abc
          103 grep claude /Users/x/.claude/projects/a.jsonl
          104 /bin/zsh /Users/x/.claude/shell-snapshots/snapshot-zsh-1.sh
          105 codex resume abc
        """
        XCTAssertEqual(UnregisteredProcess.harnessProcesses(psOutput: ps, harness: claude).map(\.pid),
                       [101, 102])
        XCTAssertEqual(UnregisteredProcess.harnessProcesses(psOutput: ps, harness: codex).map(\.pid),
                       [105])
    }

    func testTheDirectoryIsReadFromLsofFieldOutput() {
        let lsof = "p101\nfcwd\nn/tmp/a\np102\nfcwd\nn/tmp/b\n"
        XCTAssertEqual(UnregisteredProcess.pids(lsofOutput: lsof, in: "/tmp/b"), [102])
    }
}
