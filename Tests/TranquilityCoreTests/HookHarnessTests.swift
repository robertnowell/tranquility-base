import XCTest
@testable import TranquilityCore

/// The manifest describes every harness on the machine, not just Claude Code.
///
/// Until 28 Aug it described one, and the absence was invisible because
/// everything it said was true: the launch repair ran, the onboarding row went
/// green, `tbase install-hooks` reported success, and all of it was about
/// `~/.claude/settings.json`. Codex sessions had no hooks at all, so they never
/// received the SessionStart instruction that turns a visual into an openable
/// HTML file, never announced a finished turn, and never had a page they wrote
/// collected. The symptom Robert reported was the last of those three.
///
/// These tests pin the two halves that make the fix real: that the Codex
/// manifest carries the hooks the symptom was about, and that repair actually
/// writes a Codex-shaped file.
final class HookHarnessTests: XCTestCase {
    var tmpDir: URL!
    var hooksDir: URL!
    var record: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-harness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        hooksDir = tmpDir.appendingPathComponent("hooks", isDirectory: true)
        record = tmpDir.appendingPathComponent("hooks-dir")
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        // Every script BOTH harnesses name, which is the set repair now checks.
        for script in HookManifest.allScripts() {
            let path = hooksDir.appendingPathComponent(script)
            try "#!/bin/bash\nexit 0\n".write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        try hooksDir.path.write(to: record, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - What the Codex manifest promises

    /// The two hooks the reported symptom was actually about. A Codex manifest
    /// carrying only the three lifecycle hooks would fix the lamps and leave
    /// "Codex never writes HTML pages" exactly as it was.
    func testCodexCarriesTheVisualOutputAndArtifactHooks() {
        // `first(where:)`, not a marker-keyed dictionary: three hooks share the
        // `tbase-hook` marker, and uniqueKeysWithValues TRAPS on that. The same
        // hazard `sessionRowsNow` documents for the agents probe.
        func hook(_ marker: String) -> HookManifest.Hook? {
            HookManifest.codex.expected.first { $0.marker == marker }
        }

        XCTAssertEqual(hook("visual-output-hook")?.event, "SessionStart")
        XCTAssertEqual(hook("visual-output-hook")?.script, "visual-output-hook.sh")

        XCTAssertEqual(hook("artifact-hook")?.event, "PostToolUse")
        XCTAssertEqual(hook("artifact-hook")?.matcher, "Write|Edit|Bash",
                       "the same matcher Claude Code carries, for the same reason")
    }

    /// Codex has no Notification event. Its name for "this session is asking
    /// you" is PermissionRequest, and `hooks/tbase-hook.sh` renames it inward
    /// so nothing downstream learns a second vocabulary.
    func testCodexAsksWithPermissionRequestNotNotification() {
        let events = Set(HookManifest.codex.expected.map(\.event))
        XCTAssertTrue(events.contains("PermissionRequest"))
        XCTAssertFalse(events.contains("Notification"))

        let claude = Set(HookManifest.claudeCode.expected.map(\.event))
        XCTAssertTrue(claude.contains("Notification"))
        XCTAssertFalse(claude.contains("PermissionRequest"))
    }

    /// Both harnesses run the SAME three scripts out of one directory. If that
    /// ever stops being true, `directoryHoldsEveryScript` is checking the wrong
    /// set and a half-populated directory passes.
    func testBothHarnessesShareOneScriptSet() {
        XCTAssertEqual(HookManifest.allScripts(),
                       ["tbase-hook.sh", "visual-output-hook.sh", "artifact-hook.sh"])
    }

    func testTheTwoHarnessesWriteToDifferentFiles() {
        XCTAssertTrue(HookManifest.claudeCode.settingsURL.path.hasSuffix(
            ".claude/settings.json"))
        XCTAssertTrue(HookManifest.codex.settingsURL.path.hasSuffix(".codex/hooks.json"))
    }

    // MARK: - Repair against a Codex-shaped file

    /// The whole point: an absent `~/.codex/hooks.json` becomes a complete one.
    func testRepairWiresACodexFileFromNothing() throws {
        let file = tmpDir.appendingPathComponent("hooks.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        guard case .repaired(let rewired, let added) = HookManifest.repair(
            settings: file, record: record, expecting: HookManifest.codex.expected)
        else { return XCTFail("expected a repair") }

        XCTAssertEqual(rewired, 0)
        XCTAssertEqual(added, HookManifest.codex.expected.count)
        XCTAssertNil(HookManifest.problemSummary(
            settings: file, expecting: HookManifest.codex.expected))

        // And it is the shape Codex actually reads, verified against a real
        // hooks.json accepted by codex-cli 0.150.1 on 28 Aug.
        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: file)) as? [String: Any]
        let hooks = try XCTUnwrap(root?["hooks"] as? [String: Any])
        let start = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        let inner = try XCTUnwrap(start.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(inner.first?["type"] as? String, "command")
        XCTAssertTrue((inner.first?["command"] as? String ?? "")
            .hasSuffix("visual-output-hook.sh"))
    }

    /// Repairing one harness must not be able to touch the other's file.
    func testRepairingCodexLeavesAClaudeFileAlone() throws {
        let claudeFile = tmpDir.appendingPathComponent("settings.json")
        try Data("{\"unrelated\":true}".utf8).write(to: claudeFile)
        let codexFile = tmpDir.appendingPathComponent("hooks.json")

        _ = HookManifest.repair(settings: codexFile, record: record,
                                expecting: HookManifest.codex.expected)

        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: claudeFile)) as? [String: Any]
        XCTAssertEqual(root?["unrelated"] as? Bool, true)
        XCTAssertNil(root?["hooks"])
    }

    /// A foreign hook in Codex's own file survives, same guarantee Claude
    /// Code's file already had. Codex users have plugin hooks there: this
    /// machine's `~/.codex/config.toml` carries four trusted ones.
    func testForeignCodexHooksArePreserved() throws {
        let file = tmpDir.appendingPathComponent("hooks.json")
        let foreign: [String: Any] = ["hooks": ["Stop": [[
            "hooks": [["type": "command", "command": "/opt/someone-else.sh"]]]]]]
        try JSONSerialization.data(withJSONObject: foreign).write(to: file)

        _ = HookManifest.repair(settings: file, record: record,
                                expecting: HookManifest.codex.expected)

        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: file)) as? [String: Any]
        let stop = try XCTUnwrap(
            (root?["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        let commands = stop.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        XCTAssertTrue(commands.contains("/opt/someone-else.sh"), "foreign hook dropped")
        XCTAssertTrue(commands.contains { $0.hasSuffix("tbase-hook.sh") })
    }

    // MARK: - Detection

    /// A harness the machine does not have is not audited, not repaired, and
    /// not reported broken. Nobody is told their Codex hooks are missing on a
    /// machine that has never run Codex.
    func testAnAbsentHarnessIsNotPresent() {
        let ghost = HookManifest.Harness(
            id: "ghost", label: "Ghost",
            settingsURL: tmpDir.appendingPathComponent("nope/hooks.json"),
            homeURL: tmpDir.appendingPathComponent("definitely-not-here"),
            approvalConfigURL: nil,
            expected: HookManifest.codex.expected)
        XCTAssertFalse(ghost.isPresent)
    }

    func testAPresentHarnessIsDetectedByItsDirectory() throws {
        let homeDir = tmpDir.appendingPathComponent("present-home", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        let real = HookManifest.Harness(
            id: "real", label: "Real",
            settingsURL: homeDir.appendingPathComponent("hooks.json"),
            homeURL: homeDir, approvalConfigURL: nil,
            expected: HookManifest.codex.expected)
        XCTAssertTrue(real.isPresent)
    }
}

/// The installer must not record a directory that dies with its branch.
///
/// Found by doing it: `tbase install-hooks` run from `.claude/worktrees/
/// codex-hooks` recorded that path as THE hooks directory (28 Aug). It is
/// repair's fallback when nothing healthy is left to learn from, so a stale
/// one takes both harnesses down at once, and it is failure mode 3 from
/// HookManifest's own header arriving by way of the tool meant to prevent it.
final class CheckoutKindTests: XCTestCase {

    func testAGitDirectoryIsTheMainCheckout() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("main-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(HookManifest.checkoutKind(at: root.path), .mainCheckout)
    }

    func testAGitFileIsALinkedWorktreeAndNamesItsMainCheckout() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "gitdir: /Users/x/Projects/repo/.git/worktrees/slug\n"
            .write(to: root.appendingPathComponent(".git"),
                   atomically: true, encoding: .utf8)

        XCTAssertEqual(HookManifest.checkoutKind(at: root.path),
                       .linkedWorktree(mainCheckout: "/Users/x/Projects/repo"))
    }

    func testSomewhereThatIsNotARepository() {
        XCTAssertEqual(HookManifest.checkoutKind(at: NSTemporaryDirectory()),
                       .notARepository)
    }

    /// The exact pointer this repo writes, verified against the real file.
    func testTheRealPointerShapeParses() {
        XCTAssertEqual(
            HookManifest.mainCheckout(fromGitFile:
                "gitdir: /Users/robertnowell/Projects/tranquility-base/.git/worktrees/codex-hooks"),
            "/Users/robertnowell/Projects/tranquility-base")
    }

    /// An unfamiliar pointer refuses to guess. The caller still declines to
    /// record; it just cannot say where to go instead, which is the honest
    /// outcome rather than a plausible wrong path.
    func testAnUnfamiliarPointerYieldsNoMainCheckout() {
        XCTAssertNil(HookManifest.mainCheckout(fromGitFile: "gitdir: /somewhere/else"))
        XCTAssertNil(HookManifest.mainCheckout(fromGitFile: ""))
        XCTAssertNil(HookManifest.mainCheckout(fromGitFile: "not a pointer at all"))
    }
}

/// Installed is not the same as running, and only one of those is visible in
/// the file we wrote.
///
/// Codex will not run a hooks file it has not had reviewed, and says nothing
/// when it declines: measured 28 Aug against codex-cli 0.150.1, an untrusted
/// hooks.json produces no hook, no warning, no log line. On 29 Aug that state
/// was live on this machine for hours while `tbase hooks` printed five green
/// ok's and the onboarding row said "wired 5". Both were true about the file
/// and wrong about the machine.
final class HookApprovalTests: XCTestCase {

    private let hooksPath = "/Users/x/.codex/hooks.json"

    private func config(_ entries: [String]) -> String {
        var out = ["model = \"gpt-5.6-sol\"", "", "[hooks.state]"]
        for e in entries {
            out.append("")
            out.append("[hooks.state.\"\(e)\"]")
            out.append("trusted_hash = \"sha256:deadbeef\"")
        }
        return out.joined(separator: "\n")
    }

    func testAnEntryForOurFileReadsAsGranted() {
        let text = config(["\(hooksPath):stop:0:0"])
        XCTAssertTrue(HookManifest.approvalGranted(inConfig: text, hooksPath: hooksPath))
    }

    /// The state this shipped in: a config carrying plugin approvals and none
    /// for ours. Reading "there is a hooks.state table" as approval would have
    /// called this granted, which is exactly the wrong answer.
    func testOtherPeoplesApprovalsAreNotOurs() {
        let text = config([
            "posthog@claude-plugins-official:hooks/hooks.json:pre_tool_use:0:0",
            "skill-tree-ai@skill-tree-marketplace:hooks/hooks.json:session_start:0:0",
        ])
        XCTAssertFalse(HookManifest.approvalGranted(inConfig: text, hooksPath: hooksPath))
    }

    func testNoHooksStateAtAllIsNotGranted() {
        XCTAssertFalse(HookManifest.approvalGranted(
            inConfig: "model = \"gpt-5.6-sol\"\n", hooksPath: hooksPath))
    }

    /// A path that merely CONTAINS ours must not count: a sibling file one
    /// directory deeper would otherwise vouch for us.
    func testASimilarButDifferentPathIsNotOurs() {
        let text = config(["/Users/x/.codex/other/hooks.json:stop:0:0"])
        XCTAssertFalse(HookManifest.approvalGranted(inConfig: text, hooksPath: hooksPath))
    }

    /// Any one entry is enough. The hash is an internal canonicalisation this
    /// repo could not reproduce, so per-event verification would mean guessing;
    /// a partial approval reading as granted is the safe direction, since Codex
    /// itself enforces the rest.
    func testOneEntryIsEnough() {
        let text = config(["\(hooksPath):post_tool_use:0:0"])
        XCTAssertTrue(HookManifest.approvalGranted(inConfig: text, hooksPath: hooksPath))
    }

    /// Claude Code has no gate at all, and must never be reported as owing one.
    func testClaudeCodeNeedsNoApproval() {
        XCTAssertEqual(HookManifest.approval(for: HookManifest.claudeCode), .notRequired)
        XCTAssertNil(HookManifest.claudeCode.approvalConfigURL)
    }

    func testCodexDeclaresWhereItsApprovalLives() {
        XCTAssertEqual(HookManifest.codex.approvalConfigURL?.lastPathComponent,
                       "config.toml")
    }

    /// An unreadable config is not a denial. Same discipline as `audit`
    /// returning nil rather than "nothing installed".
    func testAnAbsentConfigIsUnknownRatherThanPending() {
        let ghost = HookManifest.Harness(
            id: "ghost", label: "Ghost",
            settingsURL: URL(fileURLWithPath: "/nope/hooks.json"),
            homeURL: URL(fileURLWithPath: "/nope"),
            approvalConfigURL: URL(fileURLWithPath: "/nope/config.toml"),
            expected: HookManifest.codex.expected)
        XCTAssertEqual(HookManifest.approval(for: ghost), .unknown)
    }
}

/// A matcher is a TOOL NAME, and tool names belong to the harness.
///
/// The Codex manifest shipped with Claude Code's `Write|Edit|Bash`, so its
/// artifact hook listened for tools that do not exist there and never fired.
/// The symptom arrived from the far end on 31 Aug: a page a Codex session
/// wrote had no agent footer and never reached a hub, leaving no way back from
/// the page to the agent.
final class HookMatcherVocabularyTests: XCTestCase {

    private func matcher(_ harness: HookManifest.Harness, _ event: String) -> String? {
        harness.expected.first { $0.event == event }?.matcher
    }

    /// Measured across every August rollout on this machine: Codex writes
    /// files through `exec` and nothing else.
    func testCodexMatchesItsOwnToolName() {
        XCTAssertEqual(matcher(HookManifest.codex, "PostToolUse"), "exec")
    }

    func testClaudeCodeKeepsItsThree() {
        XCTAssertEqual(matcher(HookManifest.claudeCode, "PostToolUse"), "Write|Edit|Bash")
    }

    /// The assertion that would have caught it: the two harnesses must not be
    /// assumed to share a tool vocabulary. If a future harness is added by
    /// copying this manifest, this fails until someone measures.
    func testNoTwoHarnessesShareAToolMatcher() {
        let matchers = HookManifest.harnesses.compactMap { matcher($0, "PostToolUse") }
        XCTAssertEqual(Set(matchers).count, matchers.count,
                       "two harnesses claim the same PostToolUse tool names; "
                       + "one of them was copied rather than measured")
    }
}
