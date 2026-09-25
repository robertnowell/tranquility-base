import XCTest
@testable import TranquilityCore

/// The skills keep themselves linked, the way the hooks keep themselves
/// wired. Everything runs against a temp home: a source `skills/` with every
/// expected skill and shim, and target directories that stand in for
/// `~/.claude/skills` and friends.
final class SkillManifestTests: XCTestCase {
    var tmp: URL!
    var source: String!
    var record: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tb-skills-\(UUID().uuidString)", isDirectory: true)
        let src = tmp.appendingPathComponent("repo/skills", isDirectory: true)
        for skill in SkillManifest.expected {
            let dir = src.appendingPathComponent(skill.name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "---\nname: \(skill.name)\n---\n".write(to: dir.appendingPathComponent("SKILL.md"),
                                                        atomically: true, encoding: .utf8)
        }
        let bin = src.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for shim in SkillManifest.shims {
            let path = bin.appendingPathComponent(shim)
            try "#!/bin/sh\nexit 0\n".write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        source = src.path
        record = tmp.appendingPathComponent("skills-dir")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func target(_ name: String, legacy: [String] = []) -> SkillManifest.Target {
        SkillManifest.Target(id: name, label: name,
                             skillsDir: tmp.appendingPathComponent("\(name)/skills", isDirectory: true),
                             homeURL: tmp.appendingPathComponent(name, isDirectory: true),
                             legacyDirs: legacy.map { tmp.appendingPathComponent($0, isDirectory: true) })
    }

    func testAnEmptyDirectoryGetsEverySkillLinked() throws {
        let t = target("claude")
        XCTAssertEqual(SkillManifest.repair(target: t, source: source),
                       .repaired(linked: SkillManifest.expected.count, retired: 0))
        for skill in SkillManifest.expected {
            let at = t.skillsDir.appendingPathComponent(skill.name).path
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: at),
                           source + "/" + skill.name)
        }
        // The receipt is a re-audit, and a second repair touches nothing.
        XCTAssertNil(SkillManifest.problemSummary(dir: t.skillsDir, source: source))
        XCTAssertEqual(SkillManifest.repair(target: t, source: source), .healthy)
    }

    /// This Mac's `~/.claude/skills` holds real directories, hand-edited,
    /// with uncommitted work. They are moved aside, never deleted.
    func testAHandInstalledCopyIsRetiredNotDeleted() throws {
        let t = target("claude")
        let copy = t.skillsDir.appendingPathComponent("share-as-page", isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try "old words".write(to: copy.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SkillManifest.audit(dir: t.skillsDir, source: source)
                           .first { $0.skill.name == "share-as-page" }?.state, .foreign)
        XCTAssertEqual(SkillManifest.repair(target: t, source: source),
                       .repaired(linked: SkillManifest.expected.count, retired: 1))
        // OUT of the scanned directory: a copy parked beside ours under any
        // name is loaded by every harness as a second skill.
        let aside = URL(fileURLWithPath: t.skillsDir.path + ".before-tbase/share-as-page/SKILL.md")
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "old words")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: t.skillsDir.path)),
                       Set(SkillManifest.expected.map(\.name)))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: copy.path),
                       source + "/share-as-page")
    }

    /// A link into a checkout that moved is stale, and a link whose target
    /// is gone is broken; both are relinked. Only a link into the source is
    /// installed.
    func testStaleAndBrokenLinksAreRelinked() throws {
        let t = target("codex")
        try FileManager.default.createDirectory(at: t.skillsDir, withIntermediateDirectories: true)
        let elsewhere = tmp.appendingPathComponent("elsewhere/hub", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try "x".write(to: elsewhere.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: t.skillsDir.appendingPathComponent("hub").path,
                                                   withDestinationPath: elsewhere.path)
        try FileManager.default.createSymbolicLink(atPath: t.skillsDir.appendingPathComponent("research-hq").path,
                                                   withDestinationPath: tmp.appendingPathComponent("gone").path)
        let states = Dictionary(uniqueKeysWithValues:
            SkillManifest.audit(dir: t.skillsDir, source: source).map { ($0.skill.name, $0.state) })
        XCTAssertEqual(states["hub"], .stale(elsewhere.path))
        XCTAssertEqual(states["research-hq"], .brokenLink(tmp.appendingPathComponent("gone").path))
        XCTAssertEqual(states["share-as-page"], .missing)
        XCTAssertEqual(SkillManifest.repair(target: t, source: source),
                       .repaired(linked: 3, retired: 0))
        XCTAssertNil(SkillManifest.problemSummary(dir: t.skillsDir, source: source))
    }

    /// A copy in a directory the harness also reads loads beside ours as a
    /// second skill of the same name, so it is retired too.
    func testALegacyCopyIsRetired() throws {
        let t = target("codex", legacy: ["codex/old-skills"])
        let legacy = t.legacyDirs[0].appendingPathComponent("share-as-page", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        XCTAssertEqual(SkillManifest.repair(target: t, source: source),
                       .repaired(linked: 3, retired: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: t.legacyDirs[0].path + ".before-tbase/share-as-page"))
    }

    /// The first cut parked copies inside the scanned directory; a repair
    /// moves them out, and a second repair finds nothing to move.
    func testACopyParkedInsideTheScannedDirectoryIsMovedOut() throws {
        let t = target("claude")
        let parked = t.skillsDir.appendingPathComponent("hub.before-tbase", isDirectory: true)
        try FileManager.default.createDirectory(at: parked, withIntermediateDirectories: true)
        try "x".write(to: parked.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SkillManifest.repair(target: t, source: source), .repaired(linked: 3, retired: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: parked.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: t.skillsDir.path + ".before-tbase/hub.before-tbase/SKILL.md"))
        XCTAssertEqual(SkillManifest.repair(target: t, source: source), .healthy)
    }

    /// The source is learned from a link that already resolves, then the
    /// record, then the bundle; never guessed.
    func testTheSourceIsLearnedThenRecordedThenBundled() throws {
        let t = target("claude")
        XCTAssertNil(SkillManifest.source(for: [t.skillsDir], record: record, bundled: nil))
        try source.write(to: record, atomically: true, encoding: .utf8)
        XCTAssertEqual(SkillManifest.source(for: [t.skillsDir], record: record, bundled: nil), source)
        try FileManager.default.removeItem(at: record)
        XCTAssertEqual(SkillManifest.source(for: [t.skillsDir], record: record, bundled: source), source)
        // A recorded directory that no longer holds the set is skipped.
        try "/nowhere/skills".write(to: record, atomically: true, encoding: .utf8)
        XCTAssertEqual(SkillManifest.source(for: [t.skillsDir], record: record, bundled: source), source)
        // Once linked, the links themselves are the witness.
        _ = SkillManifest.repair(target: t, source: source)
        XCTAssertEqual(SkillManifest.source(for: [t.skillsDir], record: record, bundled: nil), source)
    }

    func testTheShimsLandOnPathAndAForeignFileIsRetired() throws {
        let bin = tmp.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\nold\n".write(to: bin.appendingPathComponent("hq-open"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SkillManifest.repairShims(bin: bin, source: source),
                       .repaired(linked: SkillManifest.shims.count, retired: 1))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: bin.appendingPathComponent("hq-open").path),
                       source + "/bin/hq-open")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bin.path + ".before-tbase/hq-open"))
        XCTAssertEqual(SkillManifest.repairShims(bin: bin, source: source), .healthy)
    }

    /// The repo's own skills/ holds every skill and every shim the manifest
    /// names, so a bundle built from it does too.
    func testTheRepoCarriesEverySkillAndShim() {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }   // Tests/TranquilityCoreTests/<file>
        let skills = dir.appendingPathComponent("skills").path
        XCTAssertTrue(SkillManifest.directoryHoldsEverySkill(skills), skills)
        for shim in SkillManifest.shims {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: skills + "/bin/" + shim), shim)
        }
    }
}
