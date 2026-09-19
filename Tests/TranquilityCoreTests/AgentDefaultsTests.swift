import Foundation
import XCTest
@testable import TranquilityCore

/// Per-harness launch settings (App-lane, default launcher, 25 Aug): each
/// harness gets its own command and directory, one of them is the default,
/// and a file written before this shape existed still reads correctly.
/// A trace sink the Sendable checker accepts: the closure is nonisolated
/// and must not mutate a captured var.
private final class SaidLines: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String] = []
    func add(_ line: String) { lock.lock(); store.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return store }
}

final class AgentDefaultsTests: XCTestCase {

    private var savedURL: URL!
    private let claude = ClaudeCodeAdapter().id
    private let codex = CodexAdapter().id

    private var savedRoot: URL?
    private var scratch: URL!

    override func setUp() {
        super.setUp()
        savedURL = AgentDefaults.fileURL
        AgentDefaults.fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-defaults-\(UUID().uuidString).json")
        // The fallback directory is a sibling of the agents root; point the
        // root at scratch so the test makes its workspace there, not beside
        // the real ~/Documents/agents.
        savedRoot = HomeBase.rootOverride
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-defaults-root-\(UUID().uuidString)", isDirectory: true)
        HomeBase.rootOverride = scratch.appendingPathComponent("agents", isDirectory: true)
    }

    override func tearDown() {
        AgentDefaults.fileURL = savedURL
        HomeBase.rootOverride = savedRoot
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    // MARK: - Where an agent starts

    /// 14 Sep 2026, a new Mac: agents started in `~` and every glance at
    /// Desktop, Downloads or Documents was another permission dialog. The
    /// fallback is a folder beside the agents folder, made on first use,
    /// and never home.
    func testTheFallbackDirectoryIsAFolderBesideTheAgentsFolder() {
        let expected = scratch.appendingPathComponent("tranquility-base").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: expected))
        XCTAssertEqual(AgentDefaults.fallbackDirectory, expected)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertNotEqual(AgentDefaults.fallbackDirectory, NSHomeDirectory())
        // Beside the pages, not among them: the hub mirrors the agents root.
        XCTAssertFalse(expected.hasPrefix(HomeBase.root.path))
    }

    /// Nothing configured, and a typo'd setting, both land in the folder.
    func testAnUnsetOrMissingDirectoryLandsInTheFolder() {
        let workspace = scratch.appendingPathComponent("tranquility-base").path
        XCTAssertEqual(AgentDefaults.directory(for: claude), workspace)
        AgentDefaults.save(directory: scratch.appendingPathComponent("not-there").path, for: claude)
        XCTAssertEqual(AgentDefaults.directory(for: claude), workspace)
    }

    /// The card's label is the directory's last path component, so the word
    /// a new agent wears is the folder's name (ruled 15 Sep).
    func testTheFolderIsNamedForTheApp() {
        XCTAssertEqual((AgentDefaults.fallbackDirectory as NSString).lastPathComponent, "tranquility-base")
        XCTAssertEqual(AgentDefaults.workspaceName, "tranquility-base")
    }

    // MARK: - Every way the folder can fail lands at home, never in a launch that cannot start

    /// Documents itself missing: the whole chain is created, not refused.
    func testAMissingParentIsCreatedWithIt() {
        let deep = scratch.appendingPathComponent("Documents/tranquility-base", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("Documents").path))
        XCTAssertEqual(AgentDefaults.usableDirectory(deep), deep.path)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: deep.path, isDirectory: &isDir) && isDir.boolValue)
    }

    /// A FILE where the folder should be: `cd` into it would fail inside a
    /// detached tmux pane nobody can see. Home instead, and a line says why.
    func testAFileInTheWayFallsBackToHome() {
        let path = scratch.appendingPathComponent("tranquility-base")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path.path, contents: Data("x".utf8))
        let said = SaidLines()
        let saved = Track.trace; defer { Track.trace = saved }
        Track.trace = { said.add($0) }
        XCTAssertNil(AgentDefaults.usableDirectory(path))
        XCTAssertEqual(AgentDefaults.fallbackDirectory, NSHomeDirectory())
        XCTAssertTrue(said.lines.contains { $0.contains("not a directory") }, "\(said.lines)")
    }

    /// A parent that cannot be written to: creation fails, home, and a line.
    func testAnUnwritableParentFallsBackToHome() throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let locked = scratch.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        // root ignores mode bits; the case is only meaningful for a user.
        try XCTSkipIf(getuid() == 0)
        let said = SaidLines()
        let saved = Track.trace; defer { Track.trace = saved }
        Track.trace = { said.add($0) }
        XCTAssertNil(AgentDefaults.usableDirectory(locked.appendingPathComponent("tranquility-base")))
        XCTAssertTrue(said.lines.contains { $0.contains("could not create") }, "\(said.lines)")
    }

    /// An existing folder that has been made read-only: exists, is a
    /// directory, and still cannot hold a build. Home.
    func testAReadOnlyFolderFallsBackToHome() throws {
        let ro = scratch.appendingPathComponent("tranquility-base", isDirectory: true)
        try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: ro.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ro.path) }
        try XCTSkipIf(getuid() == 0)
        XCTAssertNil(AgentDefaults.usableDirectory(ro))
        XCTAssertEqual(AgentDefaults.fallbackDirectory, NSHomeDirectory())
    }

    /// Second call finds the folder already there and does not recreate or
    /// touch it: a file inside survives.
    func testAnExistingFolderIsLeftAlone() throws {
        let first = AgentDefaults.fallbackDirectory
        let marker = URL(fileURLWithPath: first).appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        XCTAssertEqual(AgentDefaults.fallbackDirectory, first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
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

    // MARK: - The update-check upgrade (11 Sep)

    /// The 28 Aug default, verbatim, is a machine that inherited it, and it
    /// lands on the current default: with Codex's start-up update check off.
    /// This is the machine that lost a session on 11 Sep: `codex resume`
    /// stopped on the update chooser, the revive adopted the waiting process
    /// as RESUMED, and the next dictation's Return chose "Update now".
    func testThe28AugCodexDefaultGainsTheUpdateCheckSwitch() throws {
        let stored = """
        {"byHarness":{"codex":{"command":"\(AgentDefaults.codexFallbackBeforeUpdateCheck)"}},\
        "defaultHarness":"codex"}
        """
        try stored.write(to: AgentDefaults.fileURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(AgentDefaults.load(for: codex), AgentDefaults.codexFallback)
        XCTAssertTrue(AgentDefaults.load(for: codex).contains("-c check_for_update_on_startup=false"))
    }

    /// The current default itself carries the switch, so a fresh machine never
    /// meets the chooser either. Pinned as text because it IS text: the
    /// command string is what a pane's shell runs.
    func testTheCodexDefaultSwitchesOffTheStartupUpdateCheck() {
        XCTAssertTrue(AgentDefaults.codexFallback.hasSuffix("-c check_for_update_on_startup=false"))
        XCTAssertTrue(AgentDefaults.codexFallback.contains("--dangerously-bypass-hook-trust"),
                      "the update switch is added to the 28 Aug default, not in place of it")
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
