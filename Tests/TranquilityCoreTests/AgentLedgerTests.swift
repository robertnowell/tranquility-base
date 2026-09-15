import XCTest
@testable import TranquilityCore

/// The 15 Sep morning, as a fixture: two tmux servers, both holding a pane
/// `%1`, and a registry entry that names a pane without its server. Every
/// test here is a claim about which of the five answers comes back, and the
/// one that matters most is that no answer ever names the stranger's pane.
final class AgentLedgerTests: XCTestCase {

    // The real app's server: the Kopi session lives in %1.
    private let ours: [AgentLedger.PaneRow] = [
        .init(socketName: "tb", sessionName: "tb-44578e05", paneId: "%0", paneTty: "/dev/ttys012"),
        .init(socketName: "tb", sessionName: "tb-7bca9c69", paneId: "%1", paneTty: "/dev/ttys014"),
    ]

    private func registry(_ sessionId: String, pid: Int, tmux: String?) -> SessionRegistry.Entry {
        SessionRegistry.Entry(pid: pid, sessionId: sessionId, cwd: "/Users/x/Projects",
                              status: "idle", tmux: tmux, messagingSocketPath: nil,
                              name: nil, updatedAt: 1)
    }

    private func facts(record: SessionOwnershipRecord? = nil,
                       registry: SessionRegistry.Entry? = nil,
                       pidHint: Int? = nil,
                       inventories: [(socket: String?, inventory: AgentLedger.Inventory)]? = nil,
                       alive: Set<Int>,
                       ttys: [Int: String]) -> AgentLedger.Facts {
        AgentLedger.Facts(
            record: record, registry: registry, pidHint: pidHint,
            inventories: inventories ?? [("tb", .listed(ours)), (nil, .listed([]))],
            isAlive: { alive.contains($0) },
            ttyOf: { ttys[$0] })
    }

    private func decide(_ f: AgentLedger.Facts) -> AgentLocation {
        AgentLedger.decide(sessionId: "a77cbb1d-2468", harness: nil, facts: f).location
    }

    // MARK: the incident

    /// The registry says `tb-68cf6fcf:@1.%1`. Our server has a `%1` too. The
    /// old join matched the pane id and typed into it. The ledger sees the
    /// session name is on no server of ours and says so.
    func testAPaneIdOnAnotherServerIsElsewhereNotOurs() {
        let f = facts(registry: registry("a77cbb1d-2468", pid: 84430, tmux: "tb-68cf6fcf:@1.%1"),
                      alive: [84430], ttys: [84430: "/dev/ttys010"])
        let location = decide(f)
        XCTAssertNil(location.pane, "must never resolve to the stranger's %1")
        guard case .elsewhere(let why) = location else {
            return XCTFail("expected elsewhere, got \(location.summary)")
        }
        XCTAssertTrue(why.contains("tb-68cf6fcf"))
    }

    /// The same facts with the process dead: nothing to be elsewhere.
    func testAForeignPaneWithADeadPidIsGone() {
        let f = facts(registry: registry("a77cbb1d-2468", pid: 84430, tmux: "tb-68cf6fcf:@1.%1"),
                      alive: [], ttys: [:])
        XCTAssertEqual(decide(f), .gone)
    }

    /// A TEST build's view of a real agent: the registry names OUR real
    /// server's session, the TEST build's servers do not have it. Elsewhere,
    /// not hand-started, so the transfer that killed two agents refuses.
    func testTheTestBuildSeesARealAgentAsElsewhere() {
        let f = facts(registry: registry("bee124ae", pid: 46275, tmux: "tb-49ab6900:@0.%0"),
                      inventories: [("tb", .listed([])), (nil, .listed([]))],
                      alive: [46275], ttys: [46275: "/dev/ttys036"])
        guard case .elsewhere = decide(f) else { return XCTFail(decide(f).summary) }
    }

    // MARK: the record

    func testOurRecordVerifiedByPidOnThePaneTtyIsHere() {
        let record = SessionOwnershipRecord(
            sessionId: "a77cbb1d-2468", harness: "claude-code", pid: 26327,
            paneId: "%1", socketName: "tb", sessionName: "tb-7bca9c69", paneTty: "/dev/ttys014")
        let f = facts(record: record, alive: [26327], ttys: [26327: "/dev/ttys014"])
        let d = AgentLedger.decide(sessionId: "a77cbb1d-2468", harness: nil, facts: f)
        XCTAssertEqual(d.location.pane?.sessionName, "tb-7bca9c69")
        XCTAssertEqual(d.location.pid, 26327)
        XCTAssertNil(d.adopt, "a record that already says this is not rewritten")
    }

    /// The record's pane exists but its pid moved (a resume in place). The
    /// registry's pid is on that tty, so the answer is here, and the record
    /// is brought up to date.
    func testARecordWithAStalePidIsRefreshedFromTheRegistry() {
        let record = SessionOwnershipRecord(
            sessionId: "a77cbb1d-2468", harness: "claude-code", pid: 1111,
            paneId: "%1", socketName: "tb", sessionName: "tb-7bca9c69", paneTty: "/dev/ttys014")
        let f = facts(record: record,
                      registry: registry("a77cbb1d-2468", pid: 2222, tmux: "tb-7bca9c69:@1.%1"),
                      alive: [2222], ttys: [2222: "/dev/ttys014"])
        let d = AgentLedger.decide(sessionId: "a77cbb1d-2468", harness: nil, facts: f)
        XCTAssertEqual(d.location.pid, 2222)
        XCTAssertEqual(d.adopt?.pid, 2222)
        XCTAssertEqual(d.adopt?.harness, "claude-code")
    }

    /// A record names a session our server no longer has, and the registry
    /// has no pane either: whatever is alive is a bare process.
    func testARecordWhosePaneIsGoneFallsToTheProcessFacts() {
        let record = SessionOwnershipRecord(
            sessionId: "a77cbb1d-2468", harness: "claude-code", pid: 5555,
            paneId: "%9", socketName: "tb", sessionName: "tb-deadbeef", paneTty: "/dev/ttys099")
        let f = facts(record: record, registry: registry("a77cbb1d-2468", pid: 5555, tmux: nil),
                      alive: [5555], ttys: [5555: "/dev/ttys099"])
        XCTAssertEqual(decide(f), .unhosted(pid: 5555))
    }

    // MARK: adoption

    /// Claude Code's registry names OUR pane, and its pid is on that tty:
    /// verified, adopted, addressed by record from now on.
    func testARegistryClaimOnOurServerIsVerifiedAndAdopted() {
        let f = facts(registry: registry("4394c0ec", pid: 26327, tmux: "tb-7bca9c69:@1.%1"),
                      alive: [26327], ttys: [26327: "/dev/ttys014"])
        let d = AgentLedger.decide(sessionId: "4394c0ec", harness: nil, facts: f)
        XCTAssertEqual(d.location.pane?.paneId, "%1")
        XCTAssertEqual(d.adopt?.sessionName, "tb-7bca9c69")
        XCTAssertEqual(d.adopt?.socketName, "tb")
        XCTAssertEqual(d.adopt?.cwd, "/Users/x/Projects")
    }

    /// The registry names our pane but the pid it gives is on a different
    /// tty. The facts disagree; nothing is typed and nothing is ended.
    func testARegistryClaimWhosePidIsNotOnThatTtyIsUnknown() {
        let f = facts(registry: registry("4394c0ec", pid: 26327, tmux: "tb-7bca9c69:@1.%1"),
                      alive: [26327], ttys: [26327: "/dev/ttys099"])
        guard case .unknown = decide(f) else { return XCTFail(decide(f).summary) }
    }

    /// A harness with no registry (Codex) and no record yet: its pid's tty
    /// is one of our panes, so it is adopted from the pane it sits in.
    func testABarePidOnOurPaneIsAdopted() {
        let f = facts(pidHint: 7777, alive: [7777], ttys: [7777: "/dev/ttys012"])
        let d = AgentLedger.decide(sessionId: "codex-1", harness: "codex", facts: f)
        XCTAssertEqual(d.location.pane?.sessionName, "tb-44578e05")
        XCTAssertEqual(d.adopt?.harness, "codex")
    }

    /// A live pid on a tty no server of ours owns, and no claim from any
    /// registry: the only case a transfer may act on.
    func testABarePidInNoTmuxIsUnhosted() {
        let f = facts(pidHint: 8888, alive: [8888], ttys: [8888: "/dev/ttys050"])
        XCTAssertEqual(decide(f), .unhosted(pid: 8888))
    }

    // MARK: never destructive on an unanswered question

    func testAnUnaskableServerIsUnknownNotUnhosted() {
        let f = facts(pidHint: 8888,
                      inventories: [("tb", .unaskable("timed out")), (nil, .listed([]))],
                      alive: [8888], ttys: [8888: "/dev/ttys050"])
        guard case .unknown(let why) = decide(f) else { return XCTFail(decide(f).summary) }
        XCTAssertTrue(why.contains("timed out"))
    }

    func testAForeignRegistryClaimWithAnUnaskableServerIsUnknownNotElsewhere() {
        let f = facts(registry: registry("a77cbb1d-2468", pid: 84430, tmux: "tb-68cf6fcf:@1.%1"),
                      inventories: [("tb", .listed(ours)), (nil, .unaskable("no answer"))],
                      alive: [84430], ttys: [84430: "/dev/ttys010"])
        guard case .unknown = decide(f) else { return XCTFail(decide(f).summary) }
    }

    func testNoPidAnywhereIsGone() {
        XCTAssertEqual(decide(facts(alive: [], ttys: [:])), .gone)
    }

    // MARK: inventory parsing

    func testInventoryRowsCarryDeadness() {
        let rows = AgentLedger.parse(inventory: "tb-a\t%3\t/dev/ttys003\t0\ntb-b\t%4\t/dev/ttys004\t1\n",
                                     socket: "tb")
        XCTAssertEqual(rows.count, 2)
        XCTAssertFalse(rows[0].dead)
        XCTAssertTrue(rows[1].dead)
        XCTAssertEqual(rows[1].address.sessionName, "tb-b")
    }

    func testADeadPaneIsNeverHere() {
        let dead: [AgentLedger.PaneRow] = [
            .init(socketName: "tb", sessionName: "tb-7bca9c69", paneId: "%1", paneTty: "/dev/ttys014", dead: true),
        ]
        let f = facts(registry: registry("4394c0ec", pid: 26327, tmux: "tb-7bca9c69:@1.%1"),
                      inventories: [("tb", .listed(dead)), (nil, .listed([]))],
                      alive: [26327], ttys: [26327: "/dev/ttys014"])
        XCTAssertEqual(decide(f), .gone)
    }
}

/// The other half of the 15 Sep ruling: a test build ends only what it made.
final class TerminationLedgerGuardTests: XCTestCase {

    private final class Store: SessionOwnershipStore, @unchecked Sendable {
        var records: [SessionOwnershipRecord] = []
        func record(_ r: SessionOwnershipRecord) { records.append(r) }
        func current(sessionId: String) -> SessionOwnershipRecord? { records.first { $0.sessionId == sessionId } }
        func remove(sessionId: String) { records.removeAll { $0.sessionId == sessionId } }
        func all() -> [SessionOwnershipRecord] { records }
    }

    /// A control that would happily end anything, so a refusal can only
    /// have come from the guard.
    private struct Willing: SessionTermination.ProcessControlling {
        func identity(of pid: Int) -> SessionTermination.Identity? {
            .init(command: "claude --resume x", pgid: pid, tty: "/dev/ttys001")
        }
        func send(_ signal: Int32, to target: SessionTermination.Target) -> Bool { true }
        func waitBriefly(_ seconds: TimeInterval) {}
        func nowMs() -> Int { 0 }
    }

    override func tearDown() {
        SessionTermination.mayEndForeignProcesses = { AppIdentity.channel != .test }
        super.tearDown()
    }

    func testATestBuildRefusesAPidItDidNotLaunch() {
        SessionTermination.mayEndForeignProcesses = { false }
        let outcome = SessionTermination.end(pid: 46275, named: "bee124ae", expectedCommand: "claude",
                                             control: Willing(), ledger: Store())
        guard case .refused(let why) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(why.contains("test build"))
    }

    func testATestBuildMayEndWhatItsLedgerHolds() {
        SessionTermination.mayEndForeignProcesses = { false }
        let store = Store()
        store.record(SessionOwnershipRecord(sessionId: "bee124ae", harness: "claude-code", pid: 46275))
        let outcome = SessionTermination.end(pid: 46275, named: "bee124ae", expectedCommand: "claude",
                                             control: Willing(), ledger: store)
        if case .refused(let why) = outcome, why.contains("test build") {
            XCTFail("the guard fired on the build's own agent: \(why)")
        }
    }
}
