import XCTest
@testable import TranquilityCore

/// `GoneStart.claude`: the reply's own revive (ruled 11 Nov 2026). Every case
/// where it has no proof the process is gone must start nothing.
final class GoneStartTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
    private let pane = TmuxPaneAddress(socketName: "tb", paneId: "%7",
                                       sessionName: "tb-fixture", paneTty: "/dev/ttys998")

    private func row(_ liveness: SessionDiscovery.Liveness, revivable: Bool = true,
                     cwd: String? = NSTemporaryDirectory(),
                     harness: String = ClaudeCodeAdapter().id) -> SessionDiscovery.Session {
        SessionDiscovery.Session(sessionId: "sess-1", cwd: cwd, transcriptPath: "/tmp/t.jsonl",
                                 title: nil, lastActivityAt: Date(), answered: false,
                                 activity: nil, liveness: liveness, revivable: revivable,
                                 harness: harness)
    }

    private func witness(_ found: SessionDiscovery.Session?, owns: Bool = false,
                         resumes: Counter,
                         result: Result<TmuxPaneAddress, ScriptError>? = nil) -> GoneStart.Witness {
        let answer = result ?? .success(pane)
        return GoneStart.Witness(
            discover: { _ in found },
            ownsLiveProcess: { _ in owns },
            resume: { _, _ in resumes.bump(); return answer })
    }

    func testAGoneSessionWithSomewhereToLandIsStartedOnce() {
        let resumes = Counter()
        XCTAssertEqual(GoneStart.claude(sessionId: "sess-1",
                                        witness: witness(row(.gone), resumes: resumes)),
                       .started(pane))
        XCTAssertEqual(resumes.count, 1)
    }

    /// The main hazard: a registry that could not be read is not an empty
    /// machine, and starting on it would put a second process on a live id.
    func testAnUnreadableRegistryStartsNothing() {
        let resumes = Counter()
        guard case .notGone = GoneStart.claude(
            sessionId: "sess-1", witness: witness(row(.unknown, revivable: false), resumes: resumes))
        else { return XCTFail("unknown liveness must not start a process") }
        XCTAssertEqual(resumes.count, 0)
    }

    func testALiveSessionStartsNothing() {
        let resumes = Counter()
        guard case .notGone = GoneStart.claude(
            sessionId: "sess-1", witness: witness(row(.live, revivable: false), resumes: resumes))
        else { return XCTFail("a live session must not be started") }
        XCTAssertEqual(resumes.count, 0)
    }

    func testASessionNoTranscriptKnowsStartsNothing() {
        let resumes = Counter()
        guard case .notGone = GoneStart.claude(sessionId: "sess-1",
                                               witness: witness(nil, resumes: resumes))
        else { return XCTFail("an unknown id must not be started") }
        XCTAssertEqual(resumes.count, 0)
    }

    /// Codex keeps the tap until its own readiness proof is wired (step 2).
    func testACodexSessionStartsNothing() {
        let resumes = Counter()
        guard case .notGone = GoneStart.claude(
            sessionId: "sess-1",
            witness: witness(row(.gone, harness: CodexAdapter().id), resumes: resumes))
        else { return XCTFail("a Codex id is not this path's to start") }
        XCTAssertEqual(resumes.count, 0)
    }

    /// The registry dropped a session this app launched and can still see.
    func testAProcessThisAppStillOwnsIsNotGone() {
        let resumes = Counter()
        guard case .notGone = GoneStart.claude(
            sessionId: "sess-1", witness: witness(row(.gone), owns: true, resumes: resumes))
        else { return XCTFail("an owned live process must not get a twin") }
        XCTAssertEqual(resumes.count, 0)
    }

    func testAGoneSessionWithNowhereToLandIsRefusedWithTheReason() {
        let resumes = Counter()
        XCTAssertEqual(GoneStart.claude(
            sessionId: "sess-1",
            witness: witness(row(.gone, revivable: false), resumes: resumes)),
            .refused("its directory is gone"))
        XCTAssertEqual(resumes.count, 0)
    }

    /// The tap is already resuming it: one resume, and the reply waits on it.
    func testAResumeAlreadyInFlightCountsAsStarted() {
        let resumes = Counter()
        let busy = ScriptError(message: "already resuming", duplicateResume: true)
        XCTAssertEqual(GoneStart.claude(
            sessionId: "sess-1",
            witness: witness(row(.gone), resumes: resumes, result: .failure(busy))),
            .started(nil))
    }

    /// A process holds the id and the registry does not list it: it is on a
    /// dialog, which is the old refusal's case and stays its case.
    func testAHolderTheRegistryDoesNotListIsNotGone() {
        let resumes = Counter()
        let held = ScriptError(message: "already running as pid 1",
                               alreadyRunning: [ResumeGuard.Holder(pid: 1, command: "claude --resume sess-1")])
        guard case .notGone = GoneStart.claude(
            sessionId: "sess-1",
            witness: witness(row(.gone), resumes: resumes, result: .failure(held)))
        else { return XCTFail("a held id must not read as started or refused") }
    }

    func testALaunchThatFailsIsRefusedWithItsOwnMessage() {
        let resumes = Counter()
        let died = ScriptError(message: "exited immediately (status 127)", worthRetrying: false)
        XCTAssertEqual(GoneStart.claude(
            sessionId: "sess-1",
            witness: witness(row(.gone), resumes: resumes, result: .failure(died))),
            .refused("exited immediately (status 127)"))
    }
}
