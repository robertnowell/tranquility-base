import XCTest
@testable import TranquilityCore

/// The hooks keep themselves wired.
///
/// A hook's contract is to exit 0 whatever happens — right for a hook, and it
/// means a dead one is indistinguishable from a healthy one from the outside.
/// The manifest made drift VISIBLE (noticing was the missing act); `repair`
/// makes it self-healing, because "run `tbase install-hooks`" was advice
/// nobody follows (Robert, 12 Aug: "nobody ever wants to run a command").
///
/// Everything here runs against a temp settings.json and a temp hooks dir —
/// repair takes both as parameters precisely so this file can exist.
final class HookRepairTests: XCTestCase {
    var tmpDir: URL!
    var settings: URL!
    var record: URL!
    var hooksDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        settings = tmpDir.appendingPathComponent("settings.json")
        record = tmpDir.appendingPathComponent("hooks-dir")
        hooksDir = tmpDir.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        for script in Set(HookManifest.expected.map(\.script)) {
            let path = hooksDir.appendingPathComponent(script)
            try "#!/bin/bash\nexit 0\n".write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func write(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [])
        try data.write(to: settings)
    }

    private func entry(_ command: String, matcher: String? = nil) -> [String: Any] {
        var e: [String: Any] = [
            "hooks": [["type": "command", "command": command, "timeout": 5]]]
        if let matcher { e["matcher"] = matcher }
        return e
    }

    /// A full healthy install, as install-hooks would write it into THIS test's dirs.
    private func healthyHooks() -> [String: Any] {
        var hooks: [String: Any] = [:]
        for hook in HookManifest.expected {
            var entries = hooks[hook.event] as? [[String: Any]] ?? []
            entries.append(entry(hooksDir.appendingPathComponent(hook.script).path,
                                 matcher: hook.matcher))
            hooks[hook.event] = entries
        }
        return hooks
    }

    func testHealthyIsUntouched() throws {
        try write(["hooks": healthyHooks()])
        let before = try Data(contentsOf: settings)
        XCTAssertEqual(HookManifest.repair(settings: settings, record: record), .healthy)
        XCTAssertEqual(try Data(contentsOf: settings), before,
                       "healthy: the file must not be rewritten")
    }

    /// The moved-repo case with a healthy anchor: one entry still resolves, so
    /// the repair learns the directory from it and rewires the broken sibling.
    func testBrokenPathIsRewiredFromAHealthySibling() throws {
        var hooks = healthyHooks()
        hooks["PostToolUse"] = [entry("/gone/away/hooks/artifact-hook.sh", matcher: "Write")]
        try write(["hooks": hooks])

        let outcome = HookManifest.repair(settings: settings, record: record)
        XCTAssertEqual(outcome, .repaired(rewired: 1, added: 0))
        XCTAssertNil(HookManifest.problemSummary(settings: settings),
                     "the receipt is a clean re-audit")
    }

    /// The shipped-but-never-installed case (issue 35's shape): the hook is
    /// added, and artifact-hook keeps its Write matcher — matcherless it would
    /// be thousands of no-op subprocesses a day.
    func testMissingHookIsAddedWithItsMatcher() throws {
        var hooks = healthyHooks()
        hooks["PostToolUse"] = nil
        try write(["hooks": hooks])

        XCTAssertEqual(HookManifest.repair(settings: settings, record: record),
                       .repaired(rewired: 0, added: 1))
        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: settings)) as? [String: Any]
        let post = (root?["hooks"] as? [String: Any])?["PostToolUse"] as? [[String: Any]]
        XCTAssertEqual(post?.first?["matcher"] as? String, HookManifest.expected
            .first { $0.marker == "artifact-hook" }?.matcher)
    }

    /// The whole repo moved: every path broke at once, so no healthy entry can
    /// teach the directory — the recorded one (written by the last sync) does.
    func testAllBrokenRepairsFromTheRecordedDirectory() throws {
        var hooks: [String: Any] = [:]
        for hook in HookManifest.expected {
            var entries = hooks[hook.event] as? [[String: Any]] ?? []
            entries.append(entry("/gone/away/hooks/\(hook.script)", matcher: hook.matcher))
            hooks[hook.event] = entries
        }
        try write(["hooks": hooks])
        try hooksDir.path.write(to: record, atomically: true, encoding: .utf8)

        guard case .repaired(let rewired, _) =
            HookManifest.repair(settings: settings, record: record) else {
            return XCTFail("recorded directory must be enough to repair from")
        }
        XCTAssertEqual(rewired, HookManifest.expected.count)
        XCTAssertNil(HookManifest.problemSummary(settings: settings))
    }

    /// No anchor, no record: repair must refuse rather than guess — rewiring
    /// hooks to invented paths would REINSTALL the silent death the manifest
    /// exists to catch.
    func testNowhereToLearnFromRefusesAndTouchesNothing() throws {
        try write(["hooks": ["Stop": [entry("/gone/away/hooks/tbase-hook.sh")]]])
        let before = try Data(contentsOf: settings)
        guard case .unavailable = HookManifest.repair(settings: settings, record: record) else {
            return XCTFail("no source of truth: must refuse")
        }
        XCTAssertEqual(try Data(contentsOf: settings), before)
    }

    /// Someone else's hooks survive the rewrite byte-for-byte in content: only
    /// entries carrying our markers are touched.
    func testForeignHooksArePreserved() throws {
        var hooks = healthyHooks()
        var stop = hooks["Stop"] as? [[String: Any]] ?? []
        stop.append(entry("/usr/local/bin/somebody-elses-hook.sh"))
        hooks["Stop"] = stop
        hooks["PreToolUse"] = [entry("/opt/other/tool-guard.sh", matcher: "Bash")]
        // Break one of ours so a rewrite actually happens.
        hooks["PostToolUse"] = [entry("/gone/away/hooks/artifact-hook.sh", matcher: "Write")]
        try write(["hooks": hooks])

        XCTAssertEqual(HookManifest.repair(settings: settings, record: record),
                       .repaired(rewired: 1, added: 0))
        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: settings)) as? [String: Any]
        let after = root?["hooks"] as? [String: Any]
        let stopAfter = after?["Stop"] as? [[String: Any]] ?? []
        XCTAssertTrue(stopAfter.contains { e in
            ((e["hooks"] as? [[String: Any]]) ?? [])
                .contains { ($0["command"] as? String) == "/usr/local/bin/somebody-elses-hook.sh" }
        }, "a foreign Stop hook must survive")
        XCTAssertNotNil(after?["PreToolUse"], "a foreign event must survive")
    }

    /// Unreadable settings: refuse loudly, never "repair" a file that might be
    /// someone's half-saved edit.
    func testInvalidJSONRefuses() throws {
        try "{not json".write(to: settings, atomically: true, encoding: .utf8)
        guard case .unavailable = HookManifest.repair(settings: settings, record: record) else {
            return XCTFail("invalid JSON must refuse")
        }
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{not json")
    }

    /// Run twice: the second pass is a no-op that reports healthy. Idempotence
    /// is what makes repair-at-every-launch safe.
    func testRepairIsIdempotent() throws {
        var hooks = healthyHooks()
        hooks["PostToolUse"] = nil
        try write(["hooks": hooks])
        XCTAssertEqual(HookManifest.repair(settings: settings, record: record),
                       .repaired(rewired: 0, added: 1))
        XCTAssertEqual(HookManifest.repair(settings: settings, record: record), .healthy)
    }
}
