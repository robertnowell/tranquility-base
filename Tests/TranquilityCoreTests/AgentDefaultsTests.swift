import Foundation
import XCTest
@testable import TranquilityCore

/// Per-harness launch settings (App-lane, default launcher, 25 Aug): each
/// harness gets its own command and directory, one of them is the default,
/// and a file written before this shape existed still reads correctly.
final class AgentDefaultsTests: XCTestCase {

    private var savedURL: URL!
    private let claude = ClaudeCodeAdapter().id
    private let codex = CodexAdapter().id

    override func setUp() {
        super.setUp()
        savedURL = AgentDefaults.fileURL
        AgentDefaults.fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-defaults-\(UUID().uuidString).json")
    }

    override func tearDown() {
        AgentDefaults.fileURL = savedURL
        super.tearDown()
    }

    func testMissingFileFallsBackPerHarness() {
        XCTAssertEqual(AgentDefaults.load(for: claude), AgentDefaults.fallback)
        XCTAssertEqual(AgentDefaults.load(for: codex), AgentDefaults.codexFallback)
        XCTAssertEqual(AgentDefaults.defaultHarness, claude)
    }

    func testEachHarnessSavesIndependently() {
        AgentDefaults.save("claude --custom-flag", for: claude)
        AgentDefaults.save("codex --custom-flag", for: codex)
        XCTAssertEqual(AgentDefaults.load(for: claude), "claude --custom-flag")
        XCTAssertEqual(AgentDefaults.load(for: codex), "codex --custom-flag")

        AgentDefaults.save(directory: "/tmp", for: claude)
        AgentDefaults.save(directory: "/var", for: codex)
        XCTAssertEqual(AgentDefaults.directoryAsTyped(for: claude), "/tmp")
        XCTAssertEqual(AgentDefaults.directoryAsTyped(for: codex), "/var")
    }

    /// Saving one harness's command must not touch the other's, or a stray
    /// entry disappears the moment its sibling is edited.
    func testSavingOneHarnessDoesNotClobberTheOther() {
        AgentDefaults.save("claude --one", for: claude)
        AgentDefaults.save("codex --one", for: codex)
        AgentDefaults.save("claude --two", for: claude)
        XCTAssertEqual(AgentDefaults.load(for: claude), "claude --two")
        XCTAssertEqual(AgentDefaults.load(for: codex), "codex --one")
    }

    func testDefaultHarnessRoundTrips() {
        AgentDefaults.defaultHarness = codex
        XCTAssertEqual(AgentDefaults.defaultHarness, codex)
    }

    /// The no-argument API every pre-25-Aug call site uses must track
    /// whichever harness is currently default, not always Claude Code.
    func testNoArgumentAPIFollowsTheDefaultHarness() {
        AgentDefaults.save("claude --mine", for: claude)
        AgentDefaults.save("codex --mine", for: codex)
        XCTAssertEqual(AgentDefaults.load(), "claude --mine")

        AgentDefaults.defaultHarness = codex
        XCTAssertEqual(AgentDefaults.load(), "codex --mine")

        AgentDefaults.save("codex --changed")
        XCTAssertEqual(AgentDefaults.load(for: codex), "codex --changed")
        XCTAssertEqual(AgentDefaults.load(for: claude), "claude --mine",
                       "saving through the no-arg API must still only touch the default harness")
    }

    /// A stored EMPTY command is unset, not honored — the same rule the old
    /// flat shape had, still true per harness.
    func testAnEmptySavedCommandReadsAsUnset() {
        AgentDefaults.save("", for: codex)
        XCTAssertEqual(AgentDefaults.load(for: codex), AgentDefaults.codexFallback)
    }

    /// A directory that does not exist falls back rather than being honored
    /// — but stays visible, as typed, in directoryAsTyped.
    func testANonexistentDirectoryFallsBackButStaysVisibleAsTyped() {
        AgentDefaults.save(directory: "/nowhere/that/exists", for: codex)
        XCTAssertEqual(AgentDefaults.directory(for: codex), AgentDefaults.fallbackDirectory)
        XCTAssertEqual(AgentDefaults.directoryAsTyped(for: codex), "/nowhere/that/exists")
    }

    /// A file written before harnesses existed — one flat command/directory,
    /// no `byHarness` or `defaultHarness` keys — must still read correctly,
    /// as Claude Code's entry, with Claude Code as the default. Nobody's
    /// upgrade may silently change what a bare New Agent press launches.
    func testAnOldFlatShapeFileMigratesToClaudeCode() throws {
        let old = """
        {"command":"claude --old-flag","directory":"/old/path"}
        """
        try old.write(to: AgentDefaults.fileURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(AgentDefaults.defaultHarness, claude)
        XCTAssertEqual(AgentDefaults.load(for: claude), "claude --old-flag")
        XCTAssertEqual(AgentDefaults.directoryAsTyped(for: claude), "/old/path")
        // Codex is untouched by the old file — it gets its own fresh fallback,
        // not a copy of whatever Claude Code happened to have configured.
        XCTAssertEqual(AgentDefaults.load(for: codex), AgentDefaults.codexFallback)
        XCTAssertEqual(AgentDefaults.load(), "claude --old-flag")
    }

    /// Once a migrated file is saved again, it's in the new shape for good —
    /// re-reading it must not re-migrate (which would silently drop a Codex
    /// entry written in the meantime back onto a stale flat reading).
    func testASavedMigratedFileStaysInTheNewShape() throws {
        let old = """
        {"command":"claude --old-flag"}
        """
        try old.write(to: AgentDefaults.fileURL, atomically: true, encoding: .utf8)
        _ = AgentDefaults.load(for: claude)   // read-only; must not itself migrate on disk
        AgentDefaults.save("codex --new", for: codex)

        XCTAssertEqual(AgentDefaults.load(for: claude), "claude --old-flag")
        XCTAssertEqual(AgentDefaults.load(for: codex), "codex --new")
    }

    // MARK: - The hook-trust upgrade (28 Aug)

    /// The case this exists for: a machine configured before Codex hooks
    /// needed trusting. Without the upgrade it keeps launching without
    /// `--dangerously-bypass-hook-trust`, Codex declines to run the hooks, and
    /// says nothing about it, so the needs-you signal is silently dead.
    func testTheOldCodexDefaultGainsHookTrust() throws {
        let stored = """
        {"byHarness":{"codex":{"command":"\(AgentDefaults.codexFallbackBeforeHookTrust)"}},\
        "defaultHarness":"claude-code"}
        """
        try stored.write(to: AgentDefaults.fileURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(AgentDefaults.load(for: codex), AgentDefaults.codexFallback)
        XCTAssertTrue(
            AgentDefaults.load(for: codex).contains("--dangerously-bypass-hook-trust"))
    }

    /// And the guard that keeps the upgrade from being a rewrite of somebody's
    /// decision. A user who deleted the flag, pinned a path, or added their own
    /// typed something that is not the old default, and keeps every word of it.
    func testACustomisedCodexCommandIsNeverRewritten() throws {
        let mine = "/opt/codex/bin/codex --dangerously-bypass-approvals-and-sandbox --search"
        let stored = """
        {"byHarness":{"codex":{"command":"\(mine)"}},"defaultHarness":"codex"}
        """
        try stored.write(to: AgentDefaults.fileURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(AgentDefaults.load(for: codex), mine)
    }

    /// Deliberately choosing the review gate back is a supported choice, and
    /// it survives. This is the same string as the old default and so IS
    /// upgraded, which is the one honest limit of a value-scoped migration:
    /// "never set it" and "set it back to exactly the old text" are
    /// indistinguishable on disk. Recorded as a test rather than left to be
    /// rediscovered, since the escape hatch is to type anything else at all,
    /// including the same flags in a different order.
    func testTheUpgradeIsIdempotent() throws {
        let stored = """
        {"byHarness":{"codex":{"command":"\(AgentDefaults.codexFallback)"}},\
        "defaultHarness":"codex"}
        """
        try stored.write(to: AgentDefaults.fileURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(AgentDefaults.load(for: codex), AgentDefaults.codexFallback)
        XCTAssertEqual(
            AgentDefaults.load(for: codex)
                .components(separatedBy: "--dangerously-bypass-hook-trust").count - 1,
            1, "the flag must not be appended twice")
    }

    /// Claude Code is not touched by any of this.
    func testClaudeCodeIsUnaffectedByTheCodexUpgrade() throws {
        let stored = """
        {"byHarness":{"claude-code":{"command":"\(AgentDefaults.fallback)"},\
        "codex":{"command":"\(AgentDefaults.codexFallbackBeforeHookTrust)"}},\
        "defaultHarness":"claude-code"}
        """
        try stored.write(to: AgentDefaults.fileURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(AgentDefaults.load(for: claude), AgentDefaults.fallback)
        XCTAssertFalse(AgentDefaults.load(for: claude).contains("hook-trust"))
    }
}

/// A revived agent is launched under the same parameters as a fresh one.
///
/// Robert's ruling, 12 Aug: "any new or revived session gets launched under the
/// same parameters." It held on Claude Code and did not hold on Codex, where
/// `attemptCodexResume` passed a bare `codex` binary on purpose. That was
/// harmless for two days and then stopped being harmless, the moment
/// `--dangerously-bypass-hook-trust` landed in the fresh path's command: a
/// resumed agent hit "Hooks need review", sat on the menu, and reported only
/// that it never settled within 20s.
///
/// These assert the seam rather than a launch, because the failure is invisible
/// from outside the process: the bare binary resumes correctly in every case
/// where no flag matters, which is every case until one does.
final class ResumeUsesTheConfiguredCommandTests: XCTestCase {

    private var savedURL: URL!
    private let codex = CodexAdapter().id
    private let claude = ClaudeCodeAdapter().id

    override func setUp() {
        super.setUp()
        savedURL = AgentDefaults.fileURL
        AgentDefaults.fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-launch-\(UUID().uuidString).json")
    }

    override func tearDown() {
        AgentDefaults.fileURL = savedURL
        super.tearDown()
    }

    func testACodexResumeCarriesTheConfiguredFlags() {
        AgentDefaults.save("codex --dangerously-bypass-hook-trust --custom", for: codex)
        XCTAssertEqual(SessionLauncher.resumeLaunch(for: CodexAdapter()).command,
                       "codex --dangerously-bypass-hook-trust --custom",
                       "a resume must launch the command the user configured")
    }

    /// The specific regression: never a bare binary.
    func testACodexResumeIsNotABareBinary() {
        XCTAssertNotEqual(SessionLauncher.resumeLaunch(for: CodexAdapter()).command, "codex",
                          "resume dropped the settings' flags, which is the 28 Aug hooks-review hang")
    }

    /// The default a machine that has configured nothing gets, which is the
    /// case this actually broke in.
    func testTheUnconfiguredDefaultStillCarriesHookTrust() {
        XCTAssertTrue(
            SessionLauncher.resumeLaunch(for: CodexAdapter()).command
                .contains("--dangerously-bypass-hook-trust"),
            "Codex will not run TB's hooks without this, and says nothing when it declines")
    }

    /// Same rule, other harness: the seam is per-harness, not a Codex special case.
    func testAClaudeCodeResumeAlsoTakesItsConfiguredCommand() {
        AgentDefaults.save("claude --dangerously-skip-permissions --custom", for: claude)
        XCTAssertEqual(SessionLauncher.resumeLaunch(for: ClaudeCodeAdapter()).command,
                       "claude --dangerously-skip-permissions --custom")
    }

    /// And the launch still names the right binary, so this cannot be "fixed"
    /// by handing one harness another's command.
    func testTheAdapterAndTheCommandStillAgree() {
        XCTAssertEqual(SessionLauncher.resumeLaunch(for: CodexAdapter()).adapter.id, codex)
        XCTAssertTrue(SessionLauncher.resumeLaunch(for: CodexAdapter()).command.hasPrefix("codex"))
    }
}
