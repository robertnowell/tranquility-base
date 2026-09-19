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
        let raise = try XCTUnwrap(
            TerminalTabFocus.raiseScript(windowId: 4211, sessionName: "tb-e8c484b1"))
        for script in [attach, raise] {
            XCTAssertFalse(script.contains("tty"),
                           "no focus path may address a tab by tty: \(script)")
            XCTAssertFalse(script.contains("tabs of windows"),
                           "no focus path may walk tabs: \(script)")
        }
    }

    func testRaiseScriptAddressesOneWindowByIdAndSaysWhenItIsGone() throws {
        let script = try XCTUnwrap(
            TerminalTabFocus.raiseScript(windowId: 4211, sessionName: "tb-e8c484b1"))
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

    // MARK: - The window we measured, not the window we guessed (17 Sep)

    func testRaiseRefusesAWindowShowingAnotherSession() throws {
        // A live window with a tab is not yet OUR window. The attach wrote
        // down a stranger's id (below), and because that window was real,
        // `exists` and the tab count both passed, the raise said "ok", and
        // the fresh-attach fallback was never reached: four presses at
        // 21:23, all to window 725 (tb-29124722) for a card naming
        // tb-2894d1e0. The name check is what makes a wrong id
        // self-correcting instead of sticky for the life of the process.
        let script = try XCTUnwrap(
            TerminalTabFocus.raiseScript(windowId: 725, sessionName: "tb-2894d1e0"))
        XCTAssertTrue(script.contains("(name of window id 725) contains \"tb-2894d1e0\""),
                      "the raise must ask whether the window still shows THIS session")
        XCTAssertTrue(script.contains("return \"notfound|stranger\""),
                      "a stranger's window takes the closed-window path")
        // The order matters: the name is only read from a window that has
        // a tab, so a zombie never gets asked its name.
        let tabs = try XCTUnwrap(script.range(of: "count of tabs"))
        let name = try XCTUnwrap(script.range(of: "name of window"))
        XCTAssertLessThan(tabs.lowerBound, name.lowerBound)
        // Both "not ours" answers map to the same outcome, and that outcome
        // is the one focus() answers by forgetting and attaching fresh.
        XCTAssertEqual(
            TerminalTabFocus.outcome(of: .success("notfound|stranger"), timeout: 5), .tabGone)
    }

    func testRaiseRefusesToScriptAnUnexpectedSessionName() {
        // The name goes into an AppleScript string literal, so it gets the
        // same filter the attach applies. A name we would not attach is a
        // name we cannot have a window for.
        XCTAssertNil(TerminalTabFocus.raiseScript(
            windowId: 1, sessionName: "tb-e8c\" then do shell script \"rm -rf ~\""))
        XCTAssertNil(TerminalTabFocus.raiseScript(windowId: 1, sessionName: ""))
    }

    func testAttachMeasuresTheWindowItOpenedRatherThanReadingWindowOne() throws {
        // `do script` opens a new window and leaves it frontmost, but
        // Terminal has not re-ordered its windows at the instant the next
        // line runs, so `window 1` is still the window that was frontmost
        // BEFORE — another agent's. Probed live 17 Sep, twice: window 1 said
        // 1028 when the new window was 1235, then 1235 when it was 1237.
        // Off by one attach, every time, and the wrong id was remembered.
        let script = try XCTUnwrap(TerminalTabFocus.attachScript(
            binary: "/opt/homebrew/bin/tmux", socket: "tb",
            tmuxTmpDir: "/x", sessionName: "tb-e8c484b1"))
        XCTAssertFalse(script.contains("window 1"),
                       "an index is a guess about ordering; the id must be measured")
        XCTAssertTrue(script.contains("set newTab to do script"),
                      "do script returns the tab it made; that is the window's identity")
        XCTAssertTrue(script.contains("first window whose selected tab is newTab"))
        XCTAssertTrue(script.contains("set idsBefore to id of windows"),
                      "the before/after diff is the fallback when the tab lookup fails")
        let before = try XCTUnwrap(script.range(of: "set idsBefore"))
        let open = try XCTUnwrap(script.range(of: "do script"))
        XCTAssertLessThan(before.lowerBound, open.lowerBound,
                          "the before-list must be taken before the window opens")
    }

    func testAttachReportsTheWindowItOpened() throws {
        let script = try XCTUnwrap(TerminalTabFocus.attachScript(
            binary: "/opt/homebrew/bin/tmux", socket: "tb",
            tmuxTmpDir: "/x", sessionName: "tb-e8c484b1"))
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
