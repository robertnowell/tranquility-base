import XCTest
@testable import TranquilityCore

final class TerminalTabFocusTests: XCTestCase {

    // MARK: - Script shape

    func testScriptBatchesTheTtyFetchIntoOneEvent() throws {
        let script = try XCTUnwrap(TerminalTabFocus.script(focusing: "/dev/ttys042"))
        // The whole point of the rewrite: one batched property fetch, not one
        // Apple event per tab (issue 14 — 192 tabs took 3.5 s that way).
        XCTAssertTrue(script.contains("tty of tabs of windows"))
        XCTAssertFalse(script.contains("tty of t)"),
                       "per-tab tty reads are the shape that froze the app")
        XCTAssertTrue(script.contains("\"/dev/ttys042\""))
        XCTAssertTrue(script.contains("return \"notfound\""))
    }

    func testScriptRefusesAnythingThatIsNotADevicePath() {
        XCTAssertNil(TerminalTabFocus.script(focusing: "ttys042"),
                     "missing /dev/ prefix")
        XCTAssertNil(TerminalTabFocus.script(focusing: ""))
        // Injection: a quote would escape the string literal inside the script.
        XCTAssertNil(TerminalTabFocus.script(
            focusing: "/dev/ttys042\" then do shell script \"rm -rf ~\""))
        XCTAssertNil(TerminalTabFocus.script(focusing: "/dev/ttys042\ndelay 60"))
        XCTAssertNil(TerminalTabFocus.script(
            focusing: "/dev/" + String(repeating: "a", count: 100)),
            "over-long tty")
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
        XCTAssertTrue(script.contains("attach -t"))
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
        // not originate inside this process — filtered the same way
        // `script(focusing:)` filters a tty, on principle even though every
        // session name this app creates is `tb-<hex>`.
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
