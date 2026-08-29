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
            expected: HookManifest.codex.expected)
        XCTAssertFalse(ghost.isPresent)
    }

    func testAPresentHarnessIsDetectedByItsDirectory() throws {
        let homeDir = tmpDir.appendingPathComponent("present-home", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        let real = HookManifest.Harness(
            id: "real", label: "Real",
            settingsURL: homeDir.appendingPathComponent("hooks.json"),
            homeURL: homeDir, expected: HookManifest.codex.expected)
        XCTAssertTrue(real.isPresent)
    }
}
