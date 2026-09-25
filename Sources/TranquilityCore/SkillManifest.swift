import Foundation

/// The skills the app carries, and where each harness reads them from.
///
/// The hooks have had a manifest since August: the app bundles `hooks/*.sh`,
/// and `HookManifest` wires every harness on this Mac to that directory at
/// launch, nondestructively, and reports what it did. The skills a session
/// relies on to write a page the hub can show (`share-as-page`,
/// `research-hq` with its `hq-open`, and the `hub` skill's `hq` command) had
/// no such courier. They lived in `~/.claude/skills`, edited by hand on one
/// Mac, a local-only git repo since 6 Aug with no remote.
///
/// So the 12 Sep ruling that sessions open the hub and never a local file
/// shipped everywhere the app ships, and nowhere the skills live: on 24 Sep
/// the other Mac's session opened its report as `file://` through the
/// `hq-open` it still had, which predates the ruling. Nothing had failed.
/// There was no step.
///
/// Ruled 25 Sep: the app carries the skills, like hooks, to every harness.
/// A plugin marketplace was rejected as Claude-specific; the skills must reach
/// Codex and OpenCode too. This type is the courier's manifest: the same
/// shape as `HookManifest` (a table, a per-harness target, an audit, a
/// bounded repair, a receipt), because the shape is what made the hooks
/// self-healing and it is the shape the skills were missing.
///
/// Symlinks, not copies (ruled 25 Sep, recommended and unopposed): one
/// source of truth, and a Sparkle update replaces the bundle at the same
/// path, so every link moves with it. A developer's checkout, recorded by
/// `tbase install-skills`, outranks the bundle for the same reason it does
/// for hooks: an edit to `skills/` must take effect without a rebuild.
public enum SkillManifest {

    public struct Skill: Sendable, Equatable {
        public let name: String
        public let purpose: String
    }

    /// THE table. `tbase install-skills`, the launch repair and the bundle
    /// check all read this list, so nothing can drift from it.
    public static let expected: [Skill] = [
        .init(name: "share-as-page", purpose: "turn a report into an on-brand page the hub can show"),
        .init(name: "research-hq", purpose: "index, open and publish pages; hq-open, hq-theme, hq-tags"),
        .init(name: "hub", purpose: "search and read what every agent on this account has written"),
    ]

    /// The commands a skill's prose names, put on PATH beside the skills.
    /// `hq` was a symlink into a repo the other Macs do not have; every shim
    /// resolves its own directory, so a link into any source works.
    public static let shims: [String] = ["hq", "hq-open", "hq-publish", "hq-theme", "hq-tags", "hq-root"]

    // MARK: - Targets

    /// One harness's skills directory, and how to tell whether this Mac has
    /// that harness at all. The presence test is the harness's config
    /// directory, exactly as `HookManifest.Harness.isPresent`: a Mac that
    /// has never run Codex is not told its Codex skills are missing, and we
    /// do not create `~/.agents` on a Mac that has no agent reading it.
    public struct Target: Sendable, Equatable {
        public let id: String
        public let label: String
        /// Where this harness reads `<name>/SKILL.md` from.
        public let skillsDir: URL
        public let homeURL: URL
        /// Directories this harness reads, or used to read, where a stale
        /// hand-made copy of one of our skills would load beside ours as a
        /// second skill of the same name. Retired by the repair, never
        /// deleted: renamed aside once.
        public let legacyDirs: [URL]

        public var isPresent: Bool {
            FileManager.default.fileExists(atPath: homeURL.path)
        }
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Claude Code reads `~/.claude/skills`. So does OpenCode, for
    /// compatibility (its docs list it beside its own directory).
    public static var claudeCode: Target {
        Target(id: ClaudeCodeAdapter().id, label: "Claude Code",
               skillsDir: home.appendingPathComponent(".claude/skills", isDirectory: true),
               homeURL: home.appendingPathComponent(".claude"),
               legacyDirs: [])
    }

    /// Codex reads `~/.agents/skills` (its documented user-level location,
    /// and it follows symlinked skill folders). `~/.codex/skills` is where
    /// hand-made copies were put on this Mac before the manifest existed;
    /// a copy left there loads as a second skill of the same name.
    public static var codex: Target {
        Target(id: CodexAdapter().id, label: "Codex",
               skillsDir: home.appendingPathComponent(".agents/skills", isDirectory: true),
               homeURL: home.appendingPathComponent(".codex"),
               legacyDirs: [home.appendingPathComponent(".codex/skills", isDirectory: true)])
    }

    /// OpenCode reads `~/.config/opencode/skills`, plus `~/.claude/skills`
    /// and `~/.agents/skills`. Its own directory is linked so an OpenCode-
    /// only Mac has the skills too; on a Mac with Claude Code or Codex it
    /// would find them either way.
    public static var openCode: Target {
        Target(id: "opencode", label: "OpenCode",
               skillsDir: home.appendingPathComponent(".config/opencode/skills", isDirectory: true),
               homeURL: home.appendingPathComponent(".config/opencode"),
               legacyDirs: [])
    }

    public static var targets: [Target] { [claudeCode, codex, openCode] }

    /// The harnesses this Mac actually has. Stable order, so a report reads
    /// the same way twice.
    public static func detected() -> [Target] { targets.filter(\.isPresent) }

    // MARK: - Audit

    public enum State: Sendable, Equatable {
        /// A symlink at the skill's name, pointing at the source.
        case installed
        /// A symlink pointing somewhere else that still holds a SKILL.md: an
        /// older source, or a checkout that moved.
        case stale(String)
        /// A symlink whose target is gone: the silent-death case, a skill the
        /// harness lists and cannot read.
        case brokenLink(String)
        /// A real directory (or file) at the name that the app did not make:
        /// a hand-installed copy. Retired aside by the repair, never deleted.
        case foreign
        case missing
    }

    public struct Status: Sendable, Equatable {
        public let skill: Skill
        public let state: State
    }

    /// What is at each expected name under `dir`. `source` is the directory
    /// the links should point into; nil means "any resolving link counts",
    /// which is the audit a caller can run before it knows the source.
    public static func audit(dir: URL, source: String?,
                             expecting wanted: [Skill] = expected) -> [Status] {
        wanted.map { skill in
            let at = dir.appendingPathComponent(skill.name).path
            guard let kind = try? FileManager.default.attributesOfItem(atPath: at)[.type] as? FileAttributeType
            else { return Status(skill: skill, state: .missing) }
            guard kind == .typeSymbolicLink else { return Status(skill: skill, state: .foreign) }
            let target = resolvedLink(at)
            guard holdsSkill(target) else { return Status(skill: skill, state: .brokenLink(target)) }
            if let source, target != source + "/" + skill.name,
               target != (source as NSString).appendingPathComponent(skill.name) {
                return Status(skill: skill, state: .stale(target))
            }
            return Status(skill: skill, state: .installed)
        }
    }

    /// One line for a log, or nil when every skill is linked and readable.
    public static func problemSummary(dir: URL, source: String?,
                                      expecting wanted: [Skill] = expected) -> String? {
        let statuses = audit(dir: dir, source: source, expecting: wanted)
        var parts: [String] = []
        let missing = statuses.filter { $0.state == .missing }.count
        let foreign = statuses.filter { $0.state == .foreign }.count
        let broken = statuses.filter { if case .brokenLink = $0.state { return true } else { return false } }.count
        let stale = statuses.filter { if case .stale = $0.state { return true } else { return false } }.count
        if missing > 0 { parts.append("\(missing) not installed") }
        if foreign > 0 { parts.append("\(foreign) hand-installed copy") }
        if broken > 0 { parts.append("\(broken) pointing at a missing directory") }
        if stale > 0 { parts.append("\(stale) pointing at an old copy") }
        return parts.isEmpty ? nil : "skills: " + parts.joined(separator: ", ")
    }

    // MARK: - Where the skills come from

    /// Where the last successful install found `skills/`. Written by
    /// `tbase install-skills` and by a repair, read by the next repair when
    /// no healthy link is left to learn from.
    public static var recordedDirectoryURL: URL {
        QueueStore.supportDirectory.appendingPathComponent("skills-dir")
    }

    /// The skills carried INSIDE the .app, if this build has them. Last in
    /// the candidate order, for the reason `HookManifest.bundledDirectory`
    /// gives: a developer's recorded checkout must keep winning, or every
    /// debug build would repoint the links at a frozen copy.
    public static var bundledDirectory: String? {
        guard let resources = Bundle.main.resourceURL?
            .appendingPathComponent("skills", isDirectory: true).path,
              directoryHoldsEverySkill(resources)
        else { return nil }
        return resources
    }

    /// The source, learned and never guessed: from any link that already
    /// resolves into a directory holding every skill, else the recorded
    /// directory, else the bundle. Nil when none of them holds the set,
    /// which is the case a repair must refuse rather than link into.
    public static func source(for dirs: [URL], record recordURL: URL = recordedDirectoryURL,
                              bundled: String? = bundledDirectory) -> String? {
        var candidates: [String] = []
        for dir in dirs {
            for status in audit(dir: dir, source: nil) {
                switch status.state {
                case .installed, .stale:
                    let target = resolvedLink(dir.appendingPathComponent(status.skill.name).path)
                    candidates.append((target as NSString).deletingLastPathComponent)
                default: continue
                }
            }
        }
        if let recorded = try? String(contentsOf: recordURL, encoding: .utf8) {
            candidates.append(recorded.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let bundled { candidates.append(bundled) }
        return candidates.first(where: directoryHoldsEverySkill)
    }

    // MARK: - Repair

    public enum RepairOutcome: Sendable, Equatable {
        case healthy
        /// `linked` names now point at the source; `retired` copies were
        /// renamed aside (never deleted).
        case repaired(linked: Int, retired: Int)
        case unavailable(String)
    }

    /// Make one harness's skills directory carry every expected skill as a
    /// link into `source`, nondestructively.
    ///
    /// A real directory at a skill's name is a hand-installed copy, and this
    /// Mac's `~/.claude/skills` was the hand that made every one of them: it
    /// is moved to `<skillsDir>.before-tbase/<name>` (with a stamp if that
    /// exists) and left there. Nothing is deleted. The receipt is a re-audit.
    public static func repair(target: Target, source: String,
                              expecting wanted: [Skill] = expected) -> RepairOutcome {
        guard directoryHoldsEverySkill(source) else {
            return .unavailable("no skills at \(source)")
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: target.skillsDir, withIntermediateDirectories: true)
        } catch {
            return .unavailable("could not create \(target.skillsDir.path): \(error.localizedDescription)")
        }
        var linked = 0, retired = 0
        for status in audit(dir: target.skillsDir, source: source, expecting: wanted) {
            let at = target.skillsDir.appendingPathComponent(status.skill.name).path
            let want = source + "/" + status.skill.name
            switch status.state {
            case .installed:
                continue
            case .foreign:
                guard retire(at) else { return .unavailable("could not move aside \(at)") }
                retired += 1
            case .stale, .brokenLink:
                try? fm.removeItem(atPath: at)
            case .missing:
                break
            }
            do {
                try fm.createSymbolicLink(atPath: at, withDestinationPath: want)
                linked += 1
            } catch {
                return .unavailable("could not link \(at): \(error.localizedDescription)")
            }
        }
        retired += sweepParkedCopies(in: target.skillsDir, expecting: wanted)
        // A copy in a directory the harness also reads loads beside ours.
        for legacy in target.legacyDirs {
            retired += sweepParkedCopies(in: legacy, expecting: wanted)
            for skill in wanted {
                let at = legacy.appendingPathComponent(skill.name).path
                guard let kind = try? fm.attributesOfItem(atPath: at)[.type] as? FileAttributeType
                else { continue }
                if kind == .typeSymbolicLink, resolvedLink(at) == source + "/" + skill.name { continue }
                if retire(at) { retired += 1 }
            }
        }
        guard linked + retired > 0 else { return .healthy }
        guard problemSummary(dir: target.skillsDir, source: source, expecting: wanted) == nil else {
            return .unavailable("linked and the audit still fails at \(target.skillsDir.path)")
        }
        return .repaired(linked: linked, retired: retired)
    }

    /// Every harness on this Mac, from one source, plus the record of where
    /// the source was so the next launch can find it with no healthy link.
    public static func repairAll(record recordURL: URL = recordedDirectoryURL,
                                 bundled: String? = bundledDirectory)
        -> [(target: Target, outcome: RepairOutcome)] {
        let present = detected()
        guard !present.isEmpty else { return [] }
        guard let source = source(for: present.map(\.skillsDir), record: recordURL, bundled: bundled) else {
            return present.map { ($0, .unavailable("cannot locate the skills directory")) }
        }
        let outcomes = present.map { ($0, repair(target: $0, source: source)) }
        try? source.write(to: recordURL, atomically: true, encoding: .utf8)
        return outcomes
    }

    // MARK: - The commands on PATH

    /// `~/.local/bin` is where the shims have always lived on this Mac and
    /// is on the PATH every harness inherits here. A shim that is already a
    /// link to ours is left alone; anything else at the name is retired
    /// aside, never deleted, then linked.
    public static var binDirectory: URL {
        home.appendingPathComponent(".local/bin", isDirectory: true)
    }

    public static func repairShims(bin: URL = binDirectory, source: String,
                                   shims: [String] = shims) -> RepairOutcome {
        let fm = FileManager.default
        let from = source + "/bin"
        guard shims.allSatisfy({ fm.isExecutableFile(atPath: from + "/" + $0) }) else {
            return .unavailable("no bin/ with every shim at \(source)")
        }
        do { try fm.createDirectory(at: bin, withIntermediateDirectories: true) }
        catch { return .unavailable("could not create \(bin.path)") }
        var linked = 0, retired = 0
        // Shims the first cut parked as `<shim>.before-tbase` beside the live
        // ones: harmless on PATH, and still not where retirement puts them.
        if let names = try? fm.contentsOfDirectory(atPath: bin.path) {
            for name in names where shims.contains(where: { name.hasPrefix($0 + ".before-tbase") }) {
                if retire(bin.appendingPathComponent(name).path) { retired += 1 }
            }
        }
        for shim in shims {
            let at = bin.appendingPathComponent(shim).path
            let want = from + "/" + shim
            if let kind = try? fm.attributesOfItem(atPath: at)[.type] as? FileAttributeType {
                if kind == .typeSymbolicLink, resolvedLink(at) == want { continue }
                if kind == .typeSymbolicLink { try? fm.removeItem(atPath: at) }
                else {
                    guard retire(at) else { return .unavailable("could not move aside \(at)") }
                    retired += 1
                }
            }
            do { try fm.createSymbolicLink(atPath: at, withDestinationPath: want); linked += 1 }
            catch { return .unavailable("could not link \(at): \(error.localizedDescription)") }
        }
        return linked + retired > 0 ? .repaired(linked: linked, retired: retired) : .healthy
    }

    // MARK: - Helpers

    /// Where a link points, as a path the source can be compared against.
    /// The destination is read literally and made absolute against the
    /// link's own directory; symlinks along the way are NOT resolved, so a
    /// link into a checkout that is itself reached through a symlink still
    /// compares equal to the source it was made from.
    static func resolvedLink(_ path: String) -> String {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
        else { return path }
        if dest.hasPrefix("/") { return (dest as NSString).standardizingPath }
        return (((path as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(dest) as NSString).standardizingPath
    }

    static func holdsSkill(_ directory: String) -> Bool {
        FileManager.default.fileExists(atPath: directory + "/SKILL.md")
    }

    public static func directoryHoldsEverySkill(_ directory: String) -> Bool {
        !directory.isEmpty && expected.allSatisfy { holdsSkill(directory + "/" + $0.name) }
    }

    /// `<dir>/x` -> `<dir>.before-tbase/x` (with a stamp when that name is
    /// taken). A move, never a removal: a hand-installed copy may hold edits
    /// nobody committed.
    ///
    /// OUT of the scanned directory, not renamed inside it. The first cut
    /// renamed `share-as-page` to `share-as-page.before-tbase` in place, and
    /// the harness listed "share-as-page.before-tbase" as a skill the same
    /// minute: every harness loads every subdirectory holding a SKILL.md,
    /// whatever it is called, so a copy parked beside ours is a second skill
    /// with a stranger name, which is the duplicate the retirement exists to
    /// end. `<dir>.before-tbase` is a sibling nobody scans.
    static func retire(_ path: String) -> Bool {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let holding = dir + ".before-tbase"
        try? fm.createDirectory(atPath: holding, withIntermediateDirectories: true)
        var aside = holding + "/" + name
        if fm.fileExists(atPath: aside) {
            aside += "-\(Int(Date().timeIntervalSince1970))"
        }
        return (try? fm.moveItem(atPath: path, toPath: aside)) != nil
    }

    /// Copies the first cut parked INSIDE a scanned directory
    /// (`<name>.before-tbase*`), moved out to where retirement puts them
    /// now. Idempotent; a directory with none is untouched.
    static func sweepParkedCopies(in dir: URL, expecting wanted: [Skill]) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var moved = 0
        for name in names where wanted.contains(where: { name.hasPrefix($0.name + ".before-tbase") }) {
            if retire(dir.appendingPathComponent(name).path) { moved += 1 }
        }
        return moved
    }
}
