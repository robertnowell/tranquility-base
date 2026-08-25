import XCTest
@testable import TranquilityCore

/// The 24 Aug launch failure, pinned.
///
/// Four launches in six minutes died inside a second while the panel reported
/// every one of them as a success. The cause was measured against tmux 3.7b:
/// a pane inherits the tmux CLIENT's environment, and `new-session -e` writes
/// only the SESSION environment, which the pane never reads. The session env
/// held the right PATH throughout; the pane saw the app's own four-entry
/// system PATH, `claude` was not on it, and every pane exited 127.
///
/// The fix is one line of shell in the pane's own command, which is exactly
/// the kind of thing that gets "tidied" back out by someone who reads the
/// `-e PATH=` two lines above it and concludes it is redundant. It is not
/// redundant. This test is here to say so.
final class SessionLauncherPaneCommandTests: XCTestCase {

    func testThePaneExportsItsOwnPathRatherThanTrustingTheSessionEnvironment() {
        let command = SessionLauncher.paneCommand(
            path: "/Users/x/.local/bin:/usr/bin:/bin",
            directory: "/Users/x/Projects/thing",
            command: "claude --dangerously-skip-permissions")

        XCTAssertTrue(command.hasPrefix("export PATH='/Users/x/.local/bin:/usr/bin:/bin';"),
                      "the export must come FIRST and carry the full candidate list — a pane "
                      + "that reaches `claude` with the app's inherited PATH exits 127: \(command)")
        XCTAssertTrue(command.contains("cd '/Users/x/Projects/thing' && "
                                       + "claude --dangerously-skip-permissions"),
                      "the cd and the harness command still follow, in that order: \(command)")
    }

    /// Same discipline the directory already had: neither value is a constant,
    /// and both land in a raw `/bin/zsh -c "…"` string.
    func testBothTheDirectoryAndThePathAreQuotedAsShellLiterals() {
        let command = SessionLauncher.paneCommand(
            path: "/opt/it's here/bin",
            directory: "/Users/x/a dir; rm -rf /",
            command: "claude")

        XCTAssertTrue(command.contains("export PATH='/opt/it'\\''s here/bin';"),
                      "an apostrophe in a PATH entry must not close the quote: \(command)")
        XCTAssertTrue(command.contains("cd '/Users/x/a dir; rm -rf /'"),
                      "a semicolon in a directory must stay inside its quotes: \(command)")
    }
}

/// A transfer that ended a process and then failed must not report that
/// nothing happened — the 24 Aug "Nothing was closed." over a session the
/// button had just killed.
final class OwnershipTransferOutcomeTests: XCTestCase {

    func testOnlyAMoveCarriesAPane() {
        let refused = SessionLauncher.OwnershipTransfer.Outcome.refused("busy")
        let ended = SessionLauncher.OwnershipTransfer.Outcome.endedButNotRestarted(
            "no pane", worthRetrying: false, manualRevival: "cd '/x' && claude --resume 'i'")
        XCTAssertNil(refused.moved)
        XCTAssertNil(ended.moved,
                     "a session that was ended and not restarted has no pane to hand back, and "
                     + "must still be distinguishable from one that was never touched")
    }
}

/// A failure the user can act on, and a retry offer that means something.
final class ManualRevivalTests: XCTestCase {

    /// The whole point is that this line does NOT carry the pane's PATH
    /// export: it runs in a human's shell, which already has one, and a
    /// command someone is asked to paste should be short enough to read.
    func testTheManualLineIsWhatAHumanWouldType() {
        let line = SessionLauncher.manualRevival(
            sessionId: "abc-123", directory: "/Users/x/Projects/thing", command: "claude")
        XCTAssertEqual(line, "cd '/Users/x/Projects/thing' && claude --resume 'abc-123'")
        XCTAssertFalse(line.contains("export PATH"),
                       "the app's PATH is the app's problem; a human shell has its own")
    }

    /// Retryability is not a mood. A command that ran and exited on its own
    /// terms will exit the same way next time; a pane tmux never delivered
    /// might.
    func testOnlyAnUndeliveredPaneIsWorthRetrying() {
        XCTAssertTrue(ScriptError(message: "anything").worthRetrying,
                      "the default stays true — most failures here are a busy Terminal")
        XCTAssertFalse(ScriptError(message: "status 127", worthRetrying: false).worthRetrying)
    }
}
