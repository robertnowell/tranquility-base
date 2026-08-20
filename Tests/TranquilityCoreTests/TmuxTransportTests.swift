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

    func testNoPromptCharReadsAsEmpty() {
        // A plain-shell harness target has no ❯; the landing check is the
        // guard that matters there, and the floor check stands aside.
        XCTAssertEqual(TmuxTransport.classifyPromptLine(screen: "$ ", payload: "x"),
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
}
