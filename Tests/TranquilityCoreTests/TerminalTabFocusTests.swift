import XCTest
@testable import TranquilityCore

final class TerminalTabFocusTests: XCTestCase {

    // MARK: - Window identity (replacing the tty match, 14 Sep)

    func testNothingMatchesOnATtyAnyMore() throws {
        // The regression guard for the whole defect. A tty is not a unique
        // key: Terminal reports the stale tty of tabs whose shell exited and
        // macOS recycles the numbers, so five windows claimed /dev/ttys045 on
        // one machine and GO TO AGENT raised a dead one twelve times while
        // reporting success. If a tab walk ever comes back, this fails.
        let attach = try XCTUnwrap(TerminalTabFocus.attachScript(
            binary: "/opt/homebrew/bin/tmux", socket: "tb",
            tmuxTmpDir: "/x", sessionName: "tb-e8c484b1"))
        let raise = TerminalTabFocus.raiseScript(windowId: 4211)
        for script in [attach, raise] {
            XCTAssertFalse(script.contains("tty"),
                           "no focus path may address a tab by tty: \(script)")
            XCTAssertFalse(script.contains("tabs of windows"),
                           "no focus path may walk tabs: \(script)")
        }
    }

    func testRaiseScriptAddressesOneWindowByIdAndSaysWhenItIsGone() {
        let script = TerminalTabFocus.raiseScript(windowId: 4211)
        XCTAssertTrue(script.contains("window id 4211"))
        XCTAssertTrue(script.contains("exists window id 4211"),
                      "a closed window must be a fact, not a near-miss")
        // And `exists` alone is not that fact. Measured against the real
        // Terminal: a CLOSED window still answers `exists` with true, as a
        // zombie reporting tabs = 0. Raising it succeeds and shows nothing,
        // which is this file's own defect one layer up.
        XCTAssertTrue(script.contains("count of tabs of window id 4211"),
                      "a window with no tabs has nothing to show")
        XCTAssertTrue(script.contains("return \"notfound\""))
        XCTAssertTrue(script.contains("return \"ok\""))
    }

    func testAttachReportsTheWindowItOpened() throws {
        let script = try XCTUnwrap(TerminalTabFocus.attachScript(
            binary: "/opt/homebrew/bin/tmux", socket: "tb",
            tmuxTmpDir: "/x", sessionName: "tb-e8c484b1"))
        XCTAssertTrue(script.contains("id of window 1"),
                      "the id is only knowable at the moment we open it")
        XCTAssertTrue(script.contains("\"ok|\""))
        XCTAssertEqual(TerminalTabFocus.windowId(fromAttach: "ok|4211"), 4211)
        XCTAssertEqual(TerminalTabFocus.windowId(fromAttach: "ok|4211\n"), 4211)
        XCTAssertNil(TerminalTabFocus.windowId(fromAttach: "ok|"),
                     "an unreadable id costs a reopen, never a wrong window")
        XCTAssertNil(TerminalTabFocus.windowId(fromAttach: "ok"))
    }

    func testAttachDetachesTheOldClientRatherThanMirroringOntoIt() throws {
        // 23 Aug: GO TO AGENT clicked twice opened two Terminal windows onto
        // the same pane. That was handled by searching Terminal for the
        // existing client's tty; `-d` is tmux's own verb for it and needs no
        // search at all, so the old window closes itself.
        let script = try XCTUnwrap(TerminalTabFocus.attachScript(
            binary: "/opt/homebrew/bin/tmux", socket: "tb",
            tmuxTmpDir: "/x", sessionName: "tb-e8c484b1"))
        XCTAssertTrue(script.contains("attach -d -t"))
    }

    func testTheWindowRegistryRemembersForgetsAndIsPerSession() {
        TerminalWindows.forgetAll()
        XCTAssertNil(TerminalWindows.windowId(for: "tb-aaaa1111"))
        TerminalWindows.remember(sessionName: "tb-aaaa1111", windowId: 7)
        TerminalWindows.remember(sessionName: "tb-bbbb2222", windowId: 9)
        XCTAssertEqual(TerminalWindows.windowId(for: "tb-aaaa1111"), 7)
        XCTAssertEqual(TerminalWindows.windowId(for: "tb-bbbb2222"), 9)
        TerminalWindows.forget(sessionName: "tb-aaaa1111")
        XCTAssertNil(TerminalWindows.windowId(for: "tb-aaaa1111"))
        XCTAssertEqual(TerminalWindows.windowId(for: "tb-bbbb2222"), 9,
                       "forgetting one session must not touch another")
        TerminalWindows.forgetAll()
    }

    // MARK: - tmux attach (the 22 Aug fix: every launch is tmux, so the tab
    // walk above never matches TB's own sessions any more)

    func testAttachScriptOnOurSocketSetsTmuxTmpDirAndDashL() throws {
        let script = try XCTUnwrap(TerminalTabFocus.attachScript(
            binary: "/opt/homebrew/bin/tmux", socket: "tb",
            tmuxTmpDir: "/Users/robert/Library/Application Support/VoiceDispatch/tmux",
            sessionName: "tb-e8c484b1"))
        XCTAssertTrue(script.contains("TMUX_TMPDIR"))
        XCTAssertTrue(script.contains("-L "))
        XCTAssertTrue(script.contains("\"tb-e8c484b1\""))
        XCTAssertTrue(script.contains("attach -d -t"))
        XCTAssertTrue(script.contains("do script"))
    }

    func testAttachScriptOnTheDefaultServerSkipsTmuxTmpDirAndDashL() throws {
        let script = try XCTUnwrap(TerminalTabFocus.attachScript(
            binary: "/opt/homebrew/bin/tmux", socket: nil,
            tmuxTmpDir: "/unused", sessionName: "tb-probe"))
        XCTAssertFalse(script.contains("TMUX_TMPDIR"))
        XCTAssertFalse(script.contains("-L"))
        XCTAssertTrue(script.contains("\"tb-probe\""))
    }

    func testAttachScriptRefusesAnUnexpectedSessionName() {
        // A live tmux server's own listing is the one input here that did
        // not originate inside this process — filtered on principle, even
        // though every session name this app creates is `tb-<hex>`.
        XCTAssertNil(TerminalTabFocus.attachScript(
            binary: "/opt/homebrew/bin/tmux", socket: "tb", tmuxTmpDir: "/x",
            sessionName: "tb-e8c\" then do shell script \"rm -rf ~\""))
        XCTAssertNil(TerminalTabFocus.attachScript(
            binary: "/opt/homebrew/bin/tmux", socket: "tb", tmuxTmpDir: "/x",
            sessionName: ""))
        XCTAssertNil(TerminalTabFocus.attachScript(
            binary: "/opt/homebrew/bin/tmux", socket: "tb", tmuxTmpDir: "/x",
            sessionName: String(repeating: "a", count: 65)))
    }

    // MARK: - Outcome mapping (pure, no Terminal required)

    func testOutcomeMapping() {
        XCTAssertEqual(
            TerminalTabFocus.outcome(of: .success("ok"), timeout: 5), .focused)
        XCTAssertEqual(
            TerminalTabFocus.outcome(of: .success("notfound"), timeout: 5), .tabGone)
        XCTAssertEqual(
            TerminalTabFocus.outcome(
                of: .failure(ScriptError(message: "killed after 5s", timedOut: true)),
                timeout: 5),
            .timedOut(seconds: 5))
        XCTAssertEqual(
            TerminalTabFocus.outcome(
                of: .failure(ScriptError(message: "Not authorized")), timeout: 5),
            .failed("Not authorized"))
    }
}

final class AppleScriptRunTests: XCTestCase {

    // MARK: - Async variant

    func testAsyncRunReturnsScriptResult() async {
        let result = await AppleScript.run(script: "return \"hi\"", timeout: 10)
        XCTAssertEqual(try? result.get(), "hi")
    }

    func testAsyncRunSurfacesScriptErrors() async {
        let result = await AppleScript.run(script: "error \"boom\"", timeout: 10)
        guard case .failure(let e) = result else { return XCTFail("expected failure") }
        XCTAssertFalse(e.timedOut)
        XCTAssertTrue(e.message.contains("boom"))
    }

    func testAsyncRunKillsAStalledScriptAtTheDeadline() async {
        let started = Date()
        let result = await AppleScript.run(script: "delay 30", timeout: 0.5)
        let elapsed = Date().timeIntervalSince(started)
        guard case .failure(let e) = result else { return XCTFail("expected timeout") }
        XCTAssertTrue(e.timedOut, "deadline kill must be marked as such: \(e.message)")
        XCTAssertLessThan(elapsed, 5, "the 30 s delay must not be waited out")
    }

    // MARK: - The 64 KB pipe deadlock (issue 14, latent half)

    /// Builds ~256 KB of output — four times the pipe buffer. Before the
    /// concurrent drain, both run() variants deadlocked here forever: the
    /// child blocked writing, the parent blocked in waitUntilExit.
    private let bigOutputScript = """
        set s to "0123456789abcdef"
        repeat 14 times
          set s to s & s
        end repeat
        return s
        """

    func testSyncRunSurvivesOutputLargerThanThePipeBuffer() {
        let result = AppleScript.run(script: bigOutputScript)
        XCTAssertEqual((try? result.get())?.count, 16 * 16384)
    }

    func testAsyncRunSurvivesOutputLargerThanThePipeBuffer() async {
        let result = await AppleScript.run(script: bigOutputScript, timeout: 30)
        XCTAssertEqual((try? result.get())?.count, 16 * 16384)
    }
}
