import XCTest
@testable import TranquilityCore

/// The pure halves of the tmux transport: inventory matching, kind decoding,
/// prompt-line classification, and the selection defaults. The subprocess
/// halves are evidenced by scripts/test-dispatch-tmux.sh, the same division
/// the AppleScript transport lives with (unit tests for text preparation,
/// the integration drill for the injection itself).
final class TmuxTransportTests: XCTestCase {

    // MARK: inventory matching

    func testInventoryMatchFindsPaneByTty() {
        let inventory = """
        /dev/ttys003\t%1\ttarget
        /dev/ttys011\t%4\ttb-a1b2c3d4
        /dev/ttys012\t%7\ttb-e5f6a7b8
        """
        let pane = TmuxOwnership.match(inventory: inventory, tty: "/dev/ttys011", socket: "tb")
        XCTAssertEqual(pane?.paneId, "%4")
        XCTAssertEqual(pane?.sessionName, "tb-a1b2c3d4")
        XCTAssertEqual(pane?.socketName, "tb")
    }

    func testInventoryMatchMissesAbsentTty() {
        // The 19 Aug misfire in miniature: a tty NOT in live inventory must
        // resolve to nothing, whatever stale records claim elsewhere.
        let inventory = "/dev/ttys003\t%1\ttarget"
        XCTAssertNil(TmuxOwnership.match(inventory: inventory, tty: "/dev/ttys011", socket: nil))
    }

    func testInventoryMatchSurvivesOddSessionNames() {
        // maxSplits keeps a tab inside a session name from shearing the row.
        let inventory = "/dev/ttys002\t%9\tname\twith\ttabs"
        let pane = TmuxOwnership.match(inventory: inventory, tty: "/dev/ttys002", socket: nil)
        XCTAssertEqual(pane?.paneId, "%9")
        XCTAssertEqual(pane?.sessionName, "name\twith\ttabs")
    }

    func testInventoryMatchIgnoresMalformedLines() {
        XCTAssertNil(TmuxOwnership.match(inventory: "garbage line\n\n", tty: "/dev/ttys011", socket: nil))
    }

    // MARK: kind decoding

    func decode(_ json: String) throws -> [LiveSession] {
        try JSONDecoder().decode([LiveSession].self, from: Data(json.utf8))
    }

    func testKindDecodesWhenPresent() throws {
        let sessions = try decode("""
        [{"pid": 1, "sessionId": "a", "kind": "interactive"},
         {"pid": 2, "sessionId": "b", "kind": "background"}]
        """)
        XCTAssertFalse(sessions[0].isBackground)
        XCTAssertTrue(sessions[1].isBackground)
    }

    func testAbsentKindReadsAsInteractive() throws {
        // Exclusion needs positive evidence — the sdk-cli filter's asymmetry,
        // applied to the hosting discriminator: a CLI that stops emitting
        // `kind` must not turn every session into an untouchable one.
        let sessions = try decode(#"[{"pid": 3, "sessionId": "c"}]"#)
        XCTAssertFalse(sessions[0].isBackground)
    }

    func testUnknownKindReadsAsInteractive() throws {
        let sessions = try decode(#"[{"pid": 4, "sessionId": "d", "kind": "holographic"}]"#)
        XCTAssertFalse(sessions[0].isBackground)
    }

    // MARK: prompt-line classification (the floor check)

    func testEmptyPromptLine() {
        let screen = "some scrollback\n────\n❯ \n────\n  ⏵⏵ auto mode on"
        XCTAssertEqual(TmuxTransport.classifyPromptLine(screen: screen, payload: "hello"),
                       .empty)
    }

    func testOurPayloadOnPromptLine() {
        let screen = "────\n❯ deploy the fix please\n────"
        XCTAssertEqual(TmuxTransport.classifyPromptLine(screen: screen,
                                                        payload: "deploy the fix please"),
                       .holds(ours: true))
    }

    func testForeignTextOnPromptLineHoldsTheFloor() {
        let screen = "────\n❯ half a thought the user is still typ\n────"
        XCTAssertEqual(TmuxTransport.classifyPromptLine(screen: screen, payload: "our reply"),
                       .holds(ours: false))
    }

    func testTruncatedEchoOfOurPayloadStillReadsAsOurs() {
        // The TUI wraps and elides long input; a visible prefix of the
        // payload is our own paste, not a stranger's.
        let screen = "────\n❯ deploy the fix\n────"
        XCTAssertEqual(TmuxTransport.classifyPromptLine(screen: screen,
                                                        payload: "deploy the fix please and verify"),
                       .holds(ours: true))
    }

    func testShortForeignPrefixDoesNotReadAsTruncatedEcho() {
        // Codebase audit, 21 Aug: `payload.contains(content)` (an unanchored
        // substring test, either direction) classified a human's half-typed
        // "go" as OURS against a dispatched "go ahead and merge it" — the
        // splice-corruption class `floorHeld` exists to prevent, arrived at
        // from the other side. A short coincidental prefix must hold the
        // floor, not submit under the human's half-typed message.
        let screen = "────\n❯ go\n────"
        XCTAssertEqual(TmuxTransport.classifyPromptLine(
            screen: screen, payload: "go ahead and merge it"),
            .holds(ours: false))
    }

    func testNoPromptCharReadsAsEmpty() {
        // A plain-shell harness target has no ❯; the landing check is the
        // guard that matters there, and the floor check stands aside.
        XCTAssertEqual(TmuxTransport.classifyPromptLine(screen: "$ ", payload: "x"),
                       .empty)
    }

    func testClassifyPromptLineHonorsACustomGlyph() {
        // Codex's composer echoes behind `›`, not Claude Code's `❯`
        // (measured live 21 Aug, CodexAdapter.capabilities.promptGlyph).
        // Reading the SAME screen with the wrong glyph is the exact gap
        // that made the floor check silently a no-op for any harness other
        // than Claude Code before DispatchTarget carried its own glyph.
        let screen = "────\n› deploy the fix please\n────"
        XCTAssertEqual(TmuxTransport.classifyPromptLine(
            screen: screen, payload: "deploy the fix please", glyph: "›"),
            .holds(ours: true))
        XCTAssertEqual(TmuxTransport.classifyPromptLine(
            screen: screen, payload: "deploy the fix please"),
            .empty)
    }

    // MARK: selection defaults

    func testDispatchTargetDefaultsStayTerminal() {
        // Every existing construction site compiles unchanged and still means
        // Terminal.app — co-existence, not rip-out.
        let target = DispatchTarget(sessionId: "s")
        XCTAssertEqual(target.kind, .terminalApp)
        XCTAssertNil(target.pane)
    }

    func testDispatchTargetDefaultPromptGlyphIsClaudeCodes() {
        // Same co-existence guarantee as the transport default above: no
        // caller constructing a target today passes promptGlyph, so it must
        // stay Claude Code's own until something explicitly asks for another.
        XCTAssertEqual(DispatchTarget(sessionId: "s").promptGlyph, "❯")
    }

    func testFloorHeldRefusesDispatch() {
        XCTAssertFalse(Readiness.floorHeld.canDispatch)
    }

    func testTerminalTransportRefusesTmuxOwnedTarget() async {
        // Defense in depth behind the Coordinator's selection: the misfire
        // shape (Terminal typing at a tmux-owned target) must be impossible
        // even if a caller wires the wrong transport by hand.
        let pane = TmuxPaneAddress(socketName: "tb", paneId: "%1",
                                   sessionName: "tb-x", paneTty: "/dev/ttys011")
        let target = DispatchTarget(kind: .tmux, sessionId: "s", pid: 1,
                                    pane: pane, readinessSource: .processAlive)
        let outcome = await TerminalAppTransport().send(text: "x", to: target)
        guard case .failed(.injectionFailed(let why)) = outcome else {
            return XCTFail("expected refusal, got \(outcome)")
        }
        XCTAssertTrue(why.contains("refusing Terminal.app injection"))
    }

    // MARK: dual-live dispatch-target resolution (M3)

    private static let fakePane = TmuxPaneAddress(
        socketName: "tb", paneId: "%1", sessionName: "tb-x", paneTty: "/dev/ttys011")

    /// A one-value mailbox, so a `@Sendable` trace closure can report back to
    /// a synchronous test without the compiler mistaking it for a race —
    /// nothing here ever runs concurrently, `preferringTmuxOwned` calls the
    /// closure inline, on the calling thread. Also counts calls, so the
    /// single-row fast path's whole reason to exist (never paying a live
    /// tmux round trip when there is nothing to disambiguate) is provable,
    /// not assumed.
    final class Mailbox: @unchecked Sendable {
        var value: String?
        var resolveCalls = 0
        func resolve(_ pane: TmuxPaneAddress?) -> (Int) -> TmuxPaneAddress? {
            { _ in self.resolveCalls += 1; return pane }
        }
    }

    func testPreferringTmuxOwnedIsANoOpWithOneRowAndNeverTouchesTmux() {
        let live = [LiveSession(pid: 1, sessionId: "s", cwd: "/tmp",
                                status: "idle", name: nil, waitingFor: nil)]
        let mailbox = Mailbox()
        let chosen = live.preferringTmuxOwned(sessionId: "s",
                                              resolvePane: mailbox.resolve(nil))
        XCTAssertEqual(chosen?.session.pid, 1)
        XCTAssertNil(chosen?.pane, "single-row path never resolves a pane")
        XCTAssertEqual(mailbox.resolveCalls, 0,
                       "the whole point of the fast path is skipping the live lookup")
    }

    func testPreferringTmuxOwnedPicksTheTmuxRowAmongDuplicatesAndReturnsItsPane() {
        // The dual-live shape itself: Claude Code resumed by a foreground
        // Terminal process (pid 1) AND, independently, by TB's own tmux
        // pane (pid 2) — proven safe live 19 Aug, arbitrary before this fix.
        let live = [
            LiveSession(pid: 1, sessionId: "dup", cwd: "/tmp", status: "idle", name: nil, waitingFor: nil),
            LiveSession(pid: 2, sessionId: "dup", cwd: "/tmp", status: "idle", name: nil, waitingFor: nil),
        ]
        let chosen = live.preferringTmuxOwned(
            sessionId: "dup", resolvePane: { $0 == 2 ? Self.fakePane : nil })
        XCTAssertEqual(chosen?.session.pid, 2)
        XCTAssertEqual(chosen?.pane, Self.fakePane,
                       "the caller must reuse this, not re-resolve — see Coordinator.dispatch")
    }

    func testPreferringTmuxOwnedIgnoresATmuxOwnedRowFromAnotherSession() {
        // The cross-session misroute this fixture exists to rule out: an
        // implementation that filtered `self` instead of the sessionId-
        // matched subset would happily return "unrelated"'s pane here.
        let live = [
            LiveSession(pid: 1, sessionId: "dup", cwd: "/tmp", status: "idle", name: nil, waitingFor: nil),
            LiveSession(pid: 2, sessionId: "dup", cwd: "/tmp", status: "idle", name: nil, waitingFor: nil),
            LiveSession(pid: 3, sessionId: "unrelated", cwd: "/tmp", status: "idle", name: nil, waitingFor: nil),
        ]
        let chosen = live.preferringTmuxOwned(
            sessionId: "dup", resolvePane: { $0 == 3 ? Self.fakePane : nil })
        XCTAssertEqual(chosen?.session.sessionId, "dup")
        XCTAssertEqual(chosen?.session.pid, 1, "neither dup row is tmux-owned; falls back within dup")
        XCTAssertNil(chosen?.pane)
    }

    func testPreferringTmuxOwnedTracesAndFallsBackWhenNoneAreTmuxOwned() {
        // Neither duplicate is TB's own — two hand-started Terminal.app rows
        // for one conversation, a real shape even with no flag to cause it
        // (every TB-made launch is tmux; a session the user started by hand
        // is not TB-made). This helper is scoped to the tmux half of the
        // ambiguity only. Must still resolve to SOMETHING deterministic,
        // with the ambiguity traced rather than hidden.
        let live = [
            LiveSession(pid: 1, sessionId: "dup", cwd: "/tmp", status: "idle", name: nil, waitingFor: nil),
            LiveSession(pid: 2, sessionId: "dup", cwd: "/tmp", status: "idle", name: nil, waitingFor: nil),
        ]
        let mailbox = Mailbox()
        let chosen = live.preferringTmuxOwned(sessionId: "dup", resolvePane: { _ in nil },
                                              trace: { mailbox.value = $0 })
        XCTAssertEqual(chosen?.session.pid, 1, "falls back to the first row, deterministically")
        XCTAssertNil(chosen?.pane)
        XCTAssertTrue(mailbox.value?.contains("0 tmux-owned") ?? false)
    }

    func testPreferringTmuxOwnedTracesWhenMoreThanOneIsTmuxOwned() {
        // Should not occur (two tmux panes cannot share one pid's tty), but
        // the fallback must still be deterministic and visible, not a crash —
        // and it must still honor the function's own reuse promise (codebase
        // audit, 21 Aug: this used to discard the pane it had just resolved
        // for the row it was about to return, forcing the caller into a
        // second live lookup that could disagree with the first).
        let firstPane = TmuxPaneAddress(socketName: "tb", paneId: "%1",
                                        sessionName: "tb-first", paneTty: "/dev/ttys001")
        let secondPane = TmuxPaneAddress(socketName: "tb", paneId: "%2",
                                         sessionName: "tb-second", paneTty: "/dev/ttys002")
        let live = [
            LiveSession(pid: 1, sessionId: "dup", cwd: "/tmp", status: "idle", name: nil, waitingFor: nil),
            LiveSession(pid: 2, sessionId: "dup", cwd: "/tmp", status: "idle", name: nil, waitingFor: nil),
        ]
        let mailbox = Mailbox()
        let chosen = live.preferringTmuxOwned(
            sessionId: "dup",
            resolvePane: { $0 == 1 ? firstPane : secondPane },
            trace: { mailbox.value = $0 })
        XCTAssertEqual(chosen?.session.pid, 1)
        XCTAssertEqual(chosen?.pane, firstPane,
                       "must reuse the pane already resolved for the row it's returning, not discard it")
        XCTAssertTrue(mailbox.value?.contains("2 tmux-owned") ?? false)
    }

    func testPreferringTmuxOwnedReturnsNilWhenAbsent() {
        let live = [LiveSession(pid: 1, sessionId: "other", cwd: "/tmp",
                                status: "idle", name: nil, waitingFor: nil)]
        XCTAssertNil(live.preferringTmuxOwned(sessionId: "dup", resolvePane: { _ in Self.fakePane }))
    }

    func testMatchingRequiresBothSessionIdAndPid() {
        // The transport-layer half of the same fix: once Coordinator has
        // already chosen a pid, a readiness probe matching sessionId alone
        // could read the OTHER duplicate's busy/dialog state.
        let live = [
            LiveSession(pid: 1, sessionId: "dup", cwd: "/tmp", status: "busy", name: nil, waitingFor: nil),
            LiveSession(pid: 2, sessionId: "dup", cwd: "/tmp", status: "idle", name: nil, waitingFor: nil),
        ]
        XCTAssertEqual(live.matching(sessionId: "dup", pid: 2)?.status, "idle")
        XCTAssertEqual(live.matching(sessionId: "dup", pid: 1)?.status, "busy")
        XCTAssertNil(live.matching(sessionId: "dup", pid: 99))
        XCTAssertNil(live.matching(sessionId: "other", pid: 2))
    }
}
