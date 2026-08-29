import XCTest
@testable import TranquilityCore

/// The launch path, end to end, against a real harness — opt-in via
/// `TB_LIVE_TRUST=1`, skipped in every ordinary `swift test` run.
///
/// It exists because the 27 Aug trust-prompt regression was invisible to
/// everything that runs by default. `swift test` proved the watcher pressed
/// SOMETHING; only a real pane could say the something was "No, exit". The
/// unit tests added with that fix pin a CAPTURED screen, which is the right
/// guard against the logic drifting — and no guard at all against the screen
/// itself changing again, which is the thing that actually happened and will
/// happen again.
///
/// So this drives the shipped code and nothing else: `SessionLauncher.launch`
/// runs the real watcher, which reads `capture-pane`, computes the travel to
/// the accepting row itself, and sends its own keys. The only thing supplied
/// here is a directory nobody has trusted yet, which is what forces the prompt
/// to render at all.
///
/// NOT under /tmp, and that is load-bearing rather than taste: macOS resolves
/// /tmp to /private/tmp, `agents --json` reports the resolved path, and
/// `awaitRegistration` compares cwd by exact string — so a probe launched in
/// /tmp/x waits the full thirty seconds for a session that registered as
/// /private/tmp/x and is running perfectly. That cost a false failure here
/// before it was understood, and it is the same shape as the bug under test:
/// a launch that worked, reported as one that did not.
final class LiveTrustPromptVerify: XCTestCase {
    func testTheShippedWatcherAcceptsARealTrustPrompt() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TB_LIVE_TRUST"] == "1",
                          "live probe; set TB_LIVE_TRUST=1 to run")

        let dir = NSHomeDirectory() + "/ClaudeWork/tb-verify-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        SessionLauncher.trace = { print("TRACE: \($0)") }
        let launch = HarnessLaunch(adapter: ClaudeCodeAdapter(),
                                   command: "claude --dangerously-skip-permissions")
        // acceptTrustPrompt: true — the watcher under test runs inline, and the
        // trace above is what says which row it decided to land on.
        let result = SessionLauncher.launch(directory: dir, launch: launch,
                                            acceptTrustPrompt: true)
        guard case .success(let tty) = result else {
            return XCTFail("launch failed: \(result)")
        }

        // The fact that was failing: a session registers for this cwd. Nothing
        // registers until trust is granted, so this assertion IS the assertion
        // that the right row was pressed — a declined launch cannot reach it.
        let sid = LaunchGreeting.awaitRegistration(directory: dir, excluding: [])
        XCTAssertNotNil(sid, "no session registered for \(dir) (pane tty \(tty)) — the "
            + "shipped watcher did not get through the trust prompt")

        // Never leave a live agent behind, on either verdict.
        if let sid,
           let row = ClaudeAgentsCLI().sessions()?.first(where: { $0.sessionId == sid }) {
            _ = SessionTermination.end(pid: row.pid, named: "tb-verify")
        }
    }
}
