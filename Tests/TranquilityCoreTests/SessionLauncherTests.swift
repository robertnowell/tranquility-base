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
        XCTAssertTrue(command.hasSuffix("cd '/Users/x/Projects/thing' && "
                                        + "\(SessionLauncher.nativeArchPrefix)"
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
            sessionId: "abc-123", directory: "/Users/x/Projects/thing",
            launch: HarnessLaunch(adapter: ClaudeCodeAdapter(), command: "claude"))
        XCTAssertEqual(line, "cd '/Users/x/Projects/thing' && claude --resume abc-123")
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


/// An agent must not inherit an accident of which Homebrew installed tmux.
final class NativeArchTests: XCTestCase {

    /// On Apple Silicon the harness is re-execed natively; the prefix sits
    /// immediately before the command and nowhere else, so nothing about the
    /// PATH export or the cd is disturbed by it.
    func testTheHarnessIsTheThingRunNatively() {
        let command = SessionLauncher.paneCommand(
            path: "/usr/bin:/bin", directory: "/tmp/x", command: "claude --resume 'abc'")
        #if arch(arm64)
        XCTAssertTrue(command.contains("&& arch -arm64 claude --resume 'abc'"),
                      "the prefix belongs to the agent, not the shell or the cd: \(command)")
        #else
        XCTAssertTrue(command.hasSuffix("&& claude --resume 'abc'"),
                      "an Intel host must not be handed an arm64 re-exec: \(command)")
        #endif
    }

    /// The manual line a human pastes stays plain: their own shell is already
    /// whatever their machine is, and `arch -arm64` in a command someone is
    /// asked to trust is noise they would have to evaluate.
    func testTheManualLineIsNotReExeced() {
        let line = SessionLauncher.manualRevival(
            sessionId: "abc", directory: "/tmp/x",
            launch: HarnessLaunch(adapter: ClaudeCodeAdapter(), command: "claude"))
        XCTAssertFalse(line.contains("arch -arm64"), line)
    }
}

/// A revive must speak its own harness's language.
///
/// Measured 26 Aug on session f83191a4, a Codex session: it was revived with
/// Codex's binary and Claude Code's flag spelling — `codex … --resume <id>` —
/// which Codex rejects outright ("unexpected argument '--resume' found"; it is
/// `codex resume <id>`, a subcommand). The pane exited inside a second. The
/// same wrong default then produced the RESCUE line copied to the clipboard,
/// so the card promised a manual revival command and handed over one that
/// could not work for that agent.
final class HarnessSpecificRevivalTests: XCTestCase {

    func testCodexResumesWithItsSubcommandNotAFlag() {
        XCTAssertEqual(CodexAdapter().resumeArguments(sessionId: "abc"), ["resume", "abc"],
                       "`codex --resume` is not a thing; it is a subcommand")
        XCTAssertEqual(ClaudeCodeAdapter().resumeArguments(sessionId: "abc"), ["--resume", "abc"])
    }

    /// The rescue line is only a rescue if it runs. Pinned per harness, since
    /// the bug was a DEFAULT quietly applying the wrong one.
    func testTheManualLineMatchesTheHarnessItIsFor() {
        let codex = SessionLauncher.manualRevival(
            sessionId: "abc", directory: "/x",
            launch: HarnessLaunch(adapter: CodexAdapter(), command: "codex"))
        XCTAssertEqual(codex, "cd '/x' && codex resume abc")

        let claude = SessionLauncher.manualRevival(
            sessionId: "abc", directory: "/x",
            launch: HarnessLaunch(adapter: ClaudeCodeAdapter(), command: "claude"))
        XCTAssertEqual(claude, "cd '/x' && claude --resume abc")
    }

    /// The lookup the call site now uses, pinned so a renamed id fails here
    /// rather than in a pane that dies in a second.
    func testTheHarnessIdResolvesToItsOwnAdapter() {
        XCTAssertEqual(KnownHarnesses.adapter(for: CodexAdapter().id).id, CodexAdapter().id)
        XCTAssertEqual(KnownHarnesses.adapter(for: ClaudeCodeAdapter().id).id,
                       ClaudeCodeAdapter().id)
    }
}

/// The command and the harness cannot disagree any more.
///
/// They were two independently-defaulted parameters — `command:` defaulting
/// to the Settings default launcher, `adapter:` hardcoded to Claude Code — on
/// four signatures. While the default launcher was Claude Code they agreed by
/// luck. The day it was set to Codex, GO TO AGENT ended a live Claude Code
/// session and tried to reopen it as `codex … --resume <id>`, which Codex
/// rejects outright, and the rescue command copied to the clipboard was the
/// same impossible string. One session ended, nothing restarted, remedy
/// unusable.
final class HarnessLaunchTests: XCTestCase {

    /// One id in, both values out — the property that makes the old bug
    /// unexpressible.
    func testOneHarnessDecidesBothTheBinaryAndTheFlags() {
        let codex = HarnessLaunch(harness: CodexAdapter().id)
        XCTAssertEqual(codex.adapter.id, CodexAdapter().id)
        XCTAssertEqual(codex.adapter.resumeArguments(sessionId: "x"), ["resume", "x"])

        let claude = HarnessLaunch(harness: ClaudeCodeAdapter().id)
        XCTAssertEqual(claude.adapter.id, ClaudeCodeAdapter().id)
        XCTAssertEqual(claude.adapter.resumeArguments(sessionId: "x"), ["--resume", "x"])
    }

    /// An unknown id resolves to Claude Code rather than trapping — the same
    /// fail-safe direction `KnownHarnesses.adapter(for:)` already takes.
    func testAnUnknownHarnessFallsSafeRatherThanTrapping() {
        XCTAssertEqual(HarnessLaunch(harness: "a-harness-from-the-future").adapter.id,
                       ClaudeCodeAdapter().id)
    }

    /// The Settings default is for a NEW agent only. An EXISTING session takes
    /// its harness from disk, because what a new agent would be has nothing to
    /// do with what this session is — confusing the two is the whole bug.
    func testAnExistingSessionIsNotResolvedFromTheSettingsDefault() {
        // No Codex rollout exists for a random id, so it must read as Claude
        // Code regardless of what the default launcher is set to.
        let launch = HarnessLaunch.forExistingSession(UUID().uuidString)
        XCTAssertEqual(launch.adapter.id, ClaudeCodeAdapter().id)
    }
}
