import XCTest
@testable import TranquilityCore

/// Every agent reads the rules the running app ships (30 Sep 2026).
///
/// A clean-machine drill in miniature: every test builds its own resources,
/// store, settings and skills folders in a temp directory, so none of it
/// depends on this Mac's state, and CI runs it on every merge.
final class RulesStoreTests: XCTestCase {
    var tmp: URL!
    var resources: URL!
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-rules-\(UUID().uuidString)", isDirectory: true)
        // Staged from a path like the one Gatekeeper gives a freshly
        // downloaded app on first launch: copying out of it must work.
        resources = tmp.appendingPathComponent("AppTranslocation/X/Tranquility Base.app/Contents/Resources")
        root = tmp.appendingPathComponent("support/rules")
        try makeResources(at: resources, hookBody: "exit 0")
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    private func makeResources(at dir: URL, hookBody: String) throws {
        let hooks = dir.appendingPathComponent("hooks")
        try fm.createDirectory(at: hooks, withIntermediateDirectories: true)
        for script in Set(HookManifest.expected.map(\.script)) {
            let p = hooks.appendingPathComponent(script)
            try "#!/bin/bash\n\(hookBody)\n".write(to: p, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p.path)
        }
        for skill in SkillManifest.expected {
            let d = dir.appendingPathComponent("skills/\(skill.name)")
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            try "# \(skill.name)\n".write(to: d.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        let bin = dir.appendingPathComponent("skills/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        for shim in SkillManifest.shims {
            let p = bin.appendingPathComponent(shim)
            try "#!/bin/sh\n".write(to: p, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p.path)
        }
        let oc = dir.appendingPathComponent("opencode")
        try fm.createDirectory(at: oc, withIntermediateDirectories: true)
        try "export const X = 1;\n".write(to: oc.appendingPathComponent(SkillManifest.openCodePluginName),
                                          atomically: true, encoding: .utf8)
    }

    // MARK: - Staging

    func testStagingCopiesTheRulesAndPointsCurrentAtThem() throws {
        guard case .switched(nil, let fp) = RulesStore.stage(from: resources, root: root) else {
            return XCTFail("expected a first staging")
        }
        XCTAssertEqual(RulesStore.currentFingerprint(in: root), fp)
        let hook = RulesStore.hooksDirectory(in: root) + "/tbase-hook.sh"
        XCTAssertTrue(fm.isExecutableFile(atPath: hook), "executable bit survives the copy")
        XCTAssertTrue(fm.fileExists(atPath: RulesStore.skillsDirectory(in: root) + "/share-as-page/SKILL.md"))
        XCTAssertTrue(fm.fileExists(atPath: RulesStore.openCodeDirectory(in: root) + "/" + SkillManifest.openCodePluginName))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: RulesStore.current(in: root).path), "versions/" + fp)
    }

    func testTheSameRulesAgainChangeNothing() throws {
        _ = RulesStore.stage(from: resources, root: root)
        guard case .unchanged = RulesStore.stage(from: resources, root: root) else {
            return XCTFail("identical rules must not restage")
        }
    }

    func testTwoEditionsWithTheSameRulesShareOneVersion() throws {
        let other = tmp.appendingPathComponent("Applications/Tranquility Base Dev.app/Contents/Resources")
        try makeResources(at: other, hookBody: "exit 0")
        XCTAssertEqual(RulesStore.fingerprint(of: resources), RulesStore.fingerprint(of: other))
    }

    func testNewRulesSwitchCurrentAndKeepTheOldVersionForAWhile() throws {
        guard case .switched(_, let first) = RulesStore.stage(from: resources, root: root) else { return XCTFail() }
        try makeResources(at: resources, hookBody: "echo new; exit 0")
        guard case .switched(let from, let second) = RulesStore.stage(from: resources, root: root) else {
            return XCTFail("changed rules must switch")
        }
        XCTAssertEqual(from, first)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(fm.fileExists(atPath: root.path + "/versions/" + first), "previous version kept")
        let body = try String(contentsOfFile: RulesStore.hooksDirectory(in: root) + "/tbase-hook.sh", encoding: .utf8)
        XCTAssertTrue(body.contains("echo new"), "the stable address now serves the new rules")
    }

    func testOldVersionsBeyondTheLimitArePrunedButNeverCurrent() throws {
        for n in 0..<5 {
            try makeResources(at: resources, hookBody: "echo \(n)")
            _ = RulesStore.stage(from: resources, root: root, keep: 2)
            Thread.sleep(forTimeInterval: 0.02)
        }
        let versions = try fm.contentsOfDirectory(atPath: root.path + "/versions").filter { !$0.hasPrefix(".") }
        XCTAssertEqual(versions.count, 2)
        XCTAssertTrue(versions.contains(RulesStore.currentFingerprint(in: root)!))
    }

    func testARealDirectoryAtCurrentIsNeverReplaced() throws {
        try fm.createDirectory(at: RulesStore.current(in: root), withIntermediateDirectories: true)
        try "mine".write(to: RulesStore.current(in: root).appendingPathComponent("note"), atomically: true, encoding: .utf8)
        guard case .unavailable = RulesStore.stage(from: resources, root: root) else {
            return XCTFail("must refuse, not delete")
        }
        XCTAssertTrue(fm.fileExists(atPath: RulesStore.current(in: root).path + "/note"))
    }

    func testResourcesWithoutRulesAreRefused() {
        guard case .unavailable = RulesStore.stage(from: tmp.appendingPathComponent("empty"), root: root) else {
            return XCTFail()
        }
    }

    // MARK: - A developer's checkout

    func testACheckoutWinsOnlyWhileItContainsTheRunningBuild() throws {
        _ = RulesStore.stage(from: resources, root: root)
        let checkout = tmp.appendingPathComponent("checkout")
        try makeResources(at: checkout, hookBody: "exit 0")
        try checkout.path.write(to: RulesStore.devSourceURL(in: root), atomically: true, encoding: .utf8)

        let ahead = RulesStore.desired(root: root, appCommit: "abc", contains: { _, _ in true })
        XCTAssertEqual(ahead?.fromCheckout, true)
        XCTAssertEqual(ahead?.hooks, checkout.path + "/hooks")

        // 30 Sep: a checkout 96 commits behind the app must never win.
        let behind = RulesStore.desired(root: root, appCommit: "abc", contains: { _, _ in false })
        XCTAssertEqual(behind?.fromCheckout, false)
        XCTAssertEqual(behind?.hooks, RulesStore.hooksDirectory(in: root))

        // Cannot tell (no commit in the build): the shipped rules win.
        XCTAssertEqual(RulesStore.desired(root: root, appCommit: nil, contains: { _, _ in true })?.fromCheckout, false)
    }

    // MARK: - Hooks judged by identity, not existence

    func testAHookAtAnOldCopyIsNotHealthyAndIsRepointed() throws {
        _ = RulesStore.stage(from: resources, root: root)
        let desired = RulesStore.hooksDirectory(in: root)
        // Installed, runnable, correctly matched, at an old checkout.
        let old = tmp.appendingPathComponent("old-checkout")
        try makeResources(at: old, hookBody: "exit 0")
        let settings = tmp.appendingPathComponent("settings.json")
        var hooks: [String: Any] = [:]
        for hook in HookManifest.expected {
            var e: [String: Any] = ["hooks": [["type": "command",
                "command": HookManifest.command(forScript: old.path + "/hooks/" + hook.script), "timeout": 5]]]
            if let m = hook.matcher { e["matcher"] = m }
            hooks[hook.event] = ((hooks[hook.event] as? [[String: Any]]) ?? []) + [e]
        }
        try JSONSerialization.data(withJSONObject: ["hooks": hooks, "theirs": 1]).write(to: settings)

        XCTAssertNil(HookManifest.problemSummary(settings: settings), "the old test calls this healthy")
        XCTAssertNotNil(HookManifest.problemSummary(settings: settings, desired: desired))

        let record = tmp.appendingPathComponent("hooks-dir")
        guard case .repaired(let rewired, _) = HookManifest.repair(settings: settings, record: record, desired: desired) else {
            return XCTFail("expected a repair")
        }
        XCTAssertEqual(rewired, HookManifest.expected.count)
        XCTAssertNil(HookManifest.problemSummary(settings: settings, desired: desired))
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertEqual(root["theirs"] as? Int, 1, "the rest of the file is untouched")
        guard case .healthy = HookManifest.repair(settings: settings, record: record, desired: desired) else {
            return XCTFail("second run must be a read, not a write")
        }
    }

    func testADesiredDirectoryWithoutTheScriptsTouchesNothing() throws {
        let settings = tmp.appendingPathComponent("settings.json")
        try Data("{\"hooks\":{}}".utf8).write(to: settings)
        let before = try Data(contentsOf: settings)
        guard case .unavailable = HookManifest.repair(settings: settings, record: tmp.appendingPathComponent("r"),
                                                      desired: tmp.appendingPathComponent("nowhere").path) else {
            return XCTFail()
        }
        XCTAssertEqual(try Data(contentsOf: settings), before)
    }

    // MARK: - Skills and the OpenCode plugin

    func testASkillLinkedAtAnOldCopyIsRelinkedAndAHandCopyMovedAside() throws {
        _ = RulesStore.stage(from: resources, root: root)
        let desired = RulesStore.skillsDirectory(in: root)
        let dir = tmp.appendingPathComponent("home/.claude/skills")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = tmp.appendingPathComponent("august")
        try makeResources(at: old, hookBody: "exit 0")
        try fm.createSymbolicLink(atPath: dir.path + "/share-as-page", withDestinationPath: old.path + "/skills/share-as-page")
        try fm.createDirectory(atPath: dir.path + "/hub", withIntermediateDirectories: true)
        try "old".write(toFile: dir.path + "/hub/SKILL.md", atomically: true, encoding: .utf8)
        // Somebody's own skill, not ours: never touched.
        try fm.createDirectory(atPath: dir.path + "/deep-research", withIntermediateDirectories: true)

        let target = SkillManifest.Target(id: "claude-code", label: "Claude Code", skillsDir: dir,
                                          homeURL: tmp.appendingPathComponent("home/.claude"), legacyDirs: [])
        guard case .repaired = SkillManifest.repair(target: target, source: desired) else { return XCTFail() }
        XCTAssertEqual(SkillManifest.resolvedLink(dir.path + "/share-as-page"), desired + "/share-as-page")
        XCTAssertEqual(SkillManifest.resolvedLink(dir.path + "/hub"), desired + "/hub")
        XCTAssertTrue(fm.fileExists(atPath: dir.path + ".before-tbase/hub/SKILL.md"), "moved aside, not deleted")
        XCTAssertTrue(fm.fileExists(atPath: dir.path + "/deep-research"))
        XCTAssertNil(SkillManifest.problemSummary(dir: dir, source: desired))
    }

    func testTheOpenCodePluginIsLinkedOnlyWhereOpenCodeIsInstalled() throws {
        _ = RulesStore.stage(from: resources, root: root)
        let plugins = tmp.appendingPathComponent("home/.config/opencode/plugins")
        let source = RulesStore.openCodeDirectory(in: root)
        guard case .healthy = SkillManifest.repairOpenCodePlugin(source: source, plugins: plugins, present: false) else {
            return XCTFail()
        }
        XCTAssertFalse(fm.fileExists(atPath: plugins.path))

        try fm.createDirectory(at: plugins, withIntermediateDirectories: true)
        try "theirs".write(to: plugins.appendingPathComponent(SkillManifest.openCodePluginName), atomically: true, encoding: .utf8)
        guard case .repaired(1, 1) = SkillManifest.repairOpenCodePlugin(source: source, plugins: plugins, present: true) else {
            return XCTFail("link it, moving the foreign file aside")
        }
        XCTAssertEqual(SkillManifest.resolvedLink(plugins.path + "/" + SkillManifest.openCodePluginName),
                       source + "/" + SkillManifest.openCodePluginName)
        guard case .healthy = SkillManifest.repairOpenCodePlugin(source: source, plugins: plugins, present: true) else {
            return XCTFail("idempotent")
        }
    }

    /// The OpenCode plugin computes the app's id for a session in JavaScript;
    /// it must equal AgentSession.id byte for byte, or the agent's pages land
    /// in a folder nothing reads. The constant was computed by the plugin's
    /// own code (node, sha256("opencode\0ses_abc123")).
    func testTheOpenCodeSessionIdMatchesThePlugin() {
        XCTAssertEqual(AgentSession.id("ses_abc123", provider: "opencode"),
                       "70378cb81a0df72fe99c90b17a681e070f7e61965131ea5feff848885f3f73bf")
    }
}
