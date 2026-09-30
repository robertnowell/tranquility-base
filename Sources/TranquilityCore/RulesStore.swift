import CryptoKit
import Foundation

/// The one place on this Mac the agent rules are read from.
///
/// Ruled 30 Sep 2026 (Robert, after a MacBook's agents wrote fourteen reports
/// into a folder nothing uploaded, in a page design two months old): "this is
/// not a one off issue... it is a fundamental system reliability risk." The
/// research behind this file (agents/8592f355…/2026-09-30-agent-rules-durable-
/// delivery) found the courier already existed and failed on four properties:
/// it ran only when something else was broken, it called any old file healthy,
/// the rule texts disagreed, and nothing reported. This type answers the first
/// two by giving every harness ONE stable address to read from.
///
/// Layout, under the app's support directory:
///
///     rules/versions/<fingerprint>/hooks/*.sh
///     rules/versions/<fingerprint>/skills/<name>/…
///     rules/versions/<fingerprint>/opencode/*.js
///     rules/current -> versions/<fingerprint>
///
/// Every skill link and every hook command points at `rules/current/...`,
/// never into the .app, for four reasons the research established:
///
/// - A freshly downloaded app runs from a random translocated copy on its
///   first launch; a link into that path breaks at quit (VS Code #209356).
///   Copying FROM it is harmless.
/// - Moving, renaming or deleting the .app would break links into it.
/// - Dev and Prod are two bundles; with links into bundles, whichever edition
///   wired a harness first kept it. Here the running app stages its own rules.
/// - Codex trusts a hook by the hash of its definition; a command path that
///   changed with every update would need re-approval every update. This path
///   never changes.
///
/// `current` is switched with an atomic rename, so a hook or skill read in the
/// middle of an update sees the old tree or the new one, never half of each.
public enum RulesStore {

    public static var root: URL {
        QueueStore.supportDirectory.appendingPathComponent("rules", isDirectory: true)
    }

    /// The stable address. Never resolved before being written anywhere.
    public static func current(in root: URL = root) -> URL {
        root.appendingPathComponent("current", isDirectory: true)
    }
    public static func hooksDirectory(in root: URL = root) -> String {
        current(in: root).appendingPathComponent("hooks").path
    }
    public static func skillsDirectory(in root: URL = root) -> String {
        current(in: root).appendingPathComponent("skills").path
    }
    public static func openCodeDirectory(in root: URL = root) -> String {
        current(in: root).appendingPathComponent("opencode").path
    }

    /// The parts of the app's resources that are rules, in the layout the
    /// hooks expect (they find `../skills` beside their own directory).
    static let parts = ["hooks", "skills", "opencode"]

    // MARK: - Fingerprint

    /// A content fingerprint of the rules: every file's relative path and
    /// bytes, in a fixed order. Identical rules give the identical
    /// fingerprint whichever edition or build carries them, so Dev and Prod
    /// with the same rules share one version directory and never fight.
    public static func fingerprint(of resources: URL) -> String? {
        let fm = FileManager.default
        var files: [(String, URL)] = []
        for part in parts {
            let base = resources.appendingPathComponent(part)
            guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                if url.pathComponents.contains("__pycache__") { continue }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { continue }
                let rel = part + "/" + url.path.dropFirst(base.path.count + 1)
                files.append((rel, url))
            }
        }
        guard !files.isEmpty else { return nil }
        var hasher = SHA256()
        for (rel, url) in files.sorted(by: { $0.0 < $1.0 }) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            hasher.update(data: Data(rel.utf8)); hasher.update(data: Data([0]))
            hasher.update(data: Data(String(data.count).utf8)); hasher.update(data: Data([0]))
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
    }

    /// A staged version every harness can use: finished, and its hooks
    /// executable through a traversable directory.
    static func usable(_ version: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: version.appendingPathComponent(".complete").path) else { return false }
        return Set(HookManifest.expected.map(\.script)).allSatisfy {
            fm.isExecutableFile(atPath: version.appendingPathComponent("hooks/" + $0).path)
        }
    }

    /// Give the owner back read, write and search on a tree (so it can be
    /// removed), without following links out of it.
    static func unlock(_ root: URL) {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for case let url as URL in walker {
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink == true { continue }
            try? fm.setAttributes([.posixPermissions: v?.isDirectory == true ? 0o755 : 0o644], ofItemAtPath: url.path)
        }
    }

    /// The fingerprint `current` points at, or nil when nothing is staged.
    public static func currentFingerprint(in root: URL = root) -> String? {
        guard usable(current(in: root)) else { return nil }
        let f = current(in: root).appendingPathComponent(".fingerprint")
        return (try? String(contentsOf: f, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Staging

    public enum StageOutcome: Sendable, Equatable {
        /// `current` already pointed at these rules.
        case unchanged(String)
        /// `current` now points at these rules (a new version, or a switch).
        case switched(from: String?, to: String)
        case unavailable(String)
    }

    /// Copy the rules out of `resources` (the app's own) into a version
    /// directory named by their fingerprint, and point `current` at it.
    ///
    /// Idempotent: a version already staged is reused, not re-copied. The copy
    /// lands under a temporary name and is renamed into place only once whole
    /// (a `.complete` marker is the proof), so a crash mid-copy never leaves a
    /// version that looks finished. Older versions beyond `keep` are pruned,
    /// never the one `current` names.
    public static func stage(from resources: URL, root: URL = root, keep: Int = 3) -> StageOutcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: resources.appendingPathComponent("hooks").path),
              fm.fileExists(atPath: resources.appendingPathComponent("skills").path)
        else { return .unavailable("no rules in \(resources.path)") }
        guard let fp = fingerprint(of: resources) else {
            return .unavailable("could not read the rules in \(resources.path)")
        }
        let versions = root.appendingPathComponent("versions", isDirectory: true)
        let target = versions.appendingPathComponent(fp, isDirectory: true)
        do {
            try fm.createDirectory(at: versions, withIntermediateDirectories: true)
            // A version whose scripts cannot be run (the 30 Sep permissions
            // walk left one 0600) is not a version: open it back up to remove
            // it, and stage it again.
            if fm.fileExists(atPath: target.path), !usable(target) {
                unlock(target)
                try? fm.removeItem(at: target)
            }
            if !fm.fileExists(atPath: target.appendingPathComponent(".complete").path) {
                let temp = versions.appendingPathComponent(".staging-\(fp)-\(UUID().uuidString)", isDirectory: true)
                try? fm.removeItem(at: temp)
                try fm.createDirectory(at: temp, withIntermediateDirectories: true)
                for part in parts {
                    let from = resources.appendingPathComponent(part)
                    guard fm.fileExists(atPath: from.path) else { continue }
                    try fm.copyItem(at: from, to: temp.appendingPathComponent(part))
                }
                try fp.write(to: temp.appendingPathComponent(".fingerprint"), atomically: true, encoding: .utf8)
                try Data().write(to: temp.appendingPathComponent(".complete"))
                // No "half-staged leftover" removal here: a version only ever
                // arrives whole, by one rename of a finished copy, so an
                // existing target is either complete or locked (handled
                // above). Removing it raced a second instance that had just
                // finished (30 Sep, found by the concurrency test).
                do {
                    try fm.moveItem(at: temp, to: target)
                } catch {
                    // Two instances launched together (the delivery's
                    // self-test run and the app itself did, 30 Sep) stage the
                    // same fingerprint at once. If the other one finished,
                    // its copy is identical by construction: use it.
                    try? fm.removeItem(at: temp)
                    guard fm.fileExists(atPath: target.appendingPathComponent(".complete").path) else { throw error }
                }
            }
        } catch {
            return .unavailable("could not stage the rules: \(error.localizedDescription)")
        }

        let before = currentFingerprint(in: root)
        if before != fp {
            // Atomic switch: a new link beside `current`, renamed over it.
            let link = current(in: root)
            let fresh = root.appendingPathComponent(".current-\(UUID().uuidString)")
            try? fm.removeItem(at: fresh)
            do {
                try fm.createSymbolicLink(atPath: fresh.path, withDestinationPath: "versions/" + fp)
                if rename(fresh.path, link.path) != 0 {
                    // `current` is a real directory (never made by us): refuse
                    // rather than delete something we did not make.
                    try? fm.removeItem(at: fresh)
                    return .unavailable("\(link.path) exists and is not our link")
                }
            } catch {
                return .unavailable("could not switch current: \(error.localizedDescription)")
            }
        }
        prune(versions: versions, keeping: fp, keep: keep)
        return before == fp ? .unchanged(fp) : .switched(from: before, to: fp)
    }

    /// Keep the current version and the `keep - 1` most recent others. A
    /// session that resolved a path moments before a switch still finds its
    /// file for as long as that version is kept.
    static func prune(versions: URL, keeping current: String, keep: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: versions.path) else { return }
        // Staging leftovers from a run that died mid-copy, after an hour.
        for name in names where name.hasPrefix(".staging-") {
            let url = versions.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < Date().addingTimeInterval(-3600) { unlock(url); try? fm.removeItem(at: url) }
        }
        let others = names.filter { $0 != current && !$0.hasPrefix(".") }
            .map { versions.appendingPathComponent($0) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a > b
            }
        for stale in others.dropFirst(max(0, keep - 1)) { try? fm.removeItem(at: stale) }
    }

    // MARK: - Which app staged the rules

    /// Record the running app, so a script in the store can reach ITS Hub
    /// window (hq-open used to find the .app around itself, which a script
    /// in the store does not have: every page opened in the browser, 30 Sep).
    /// A translocated path is never recorded; the bundle id always is.
    public static func recordApp(bundleID: String?, bundlePath: String?, root: URL = root) {
        guard let bundleID, !bundleID.isEmpty else { return }
        var app: [String: String] = ["bundle_id": bundleID]
        if let bundlePath, bundlePath.hasSuffix(".app"), !bundlePath.contains("/AppTranslocation/") {
            app["path"] = bundlePath
        }
        guard let data = try? JSONSerialization.data(withJSONObject: app, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: root.appendingPathComponent("app.json"), options: .atomic)
    }

    // MARK: - Rules that were retired

    /// Phrases from rules that were retired, which no text an agent reads may
    /// carry. One list, read by the consistency test (for what ships) and by
    /// the reconcile (for skills a person installed themselves), so the two
    /// cannot disagree about what "stale" means.
    public static let retiredPhrases = [
        "first 8 characters", "first eight characters of your session",
        "first dash-separated piece", "agents/SHORT", "data-tb-agent=\"SHORT\"",
    ]

    /// Skills in these folders that are NOT ours and still state a retired
    /// rule. Reported, never rewritten: a person's own skill is theirs.
    public static func skillsStatingRetiredRules(in dirs: [URL], ours: Set<String>) -> [String] {
        let fm = FileManager.default
        var hits: [String] = []
        for dir in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names.sorted() where !ours.contains(name) && !name.hasPrefix(".") {
                let skill = dir.appendingPathComponent(name).appendingPathComponent("SKILL.md")
                guard let text = try? String(contentsOf: skill, encoding: .utf8) else { continue }
                if retiredPhrases.contains(where: { text.range(of: $0, options: .caseInsensitive) != nil }) {
                    hits.append(dir.appendingPathComponent(name).path)
                }
            }
        }
        return hits
    }

    // MARK: - Pages that will not work

    /// Report pages the page hook found broken in the last `window` (no house
    /// stylesheet, or outside the agent folder), newest first, as
    /// (session, kinds, path). The hook logs one line per case; the hourly
    /// report counts them so a Mac whose agents keep doing it is seen.
    public static func recentPageProblems(root: URL = root, window: TimeInterval = 86_400,
                                          now: Date = Date()) -> [(session: String, kinds: String, path: String)] {
        guard let text = try? String(contentsOf: root.appendingPathComponent("page-problems.log"), encoding: .utf8)
        else { return [] }
        let oldest = Int64((now.timeIntervalSince1970 - window) * 1000)
        var seen = Set<String>()
        var out: [(String, String, String)] = []
        for line in text.split(separator: "\n").reversed() {
            let parts = line.split(separator: "\t", maxSplits: 3).map(String.init)
            guard parts.count == 4, let ms = Int64(parts[0]), ms >= oldest, seen.insert(parts[3]).inserted else { continue }
            out.append((parts[1], parts[2], parts[3]))
        }
        return out
    }

    // MARK: - Per-session records

    /// Where visual-output-hook.sh records which rules version each session
    /// was given, so tbase-hook can refresh a running session when it changes.
    public static func seenDirectory(in root: URL = root) -> URL {
        root.appendingPathComponent("seen", isDirectory: true)
    }

    /// Drop records for sessions untouched for `days`. Tiny files, but one per
    /// session forever is still forever.
    public static func pruneSeen(in root: URL = root, olderThan days: Double = 30) {
        let fm = FileManager.default
        let dir = seenDirectory(in: root)
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let cutoff = Date().addingTimeInterval(-days * 86_400)
        for name in names {
            let url = dir.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fm.removeItem(at: url) }
        }
    }

    // MARK: - A developer's checkout

    /// Where `tbase install-hooks` / `install-skills` record a checkout that
    /// should be read instead of the staged rules, so edits show up live.
    public static func devSourceURL(in root: URL = root) -> URL {
        root.appendingPathComponent("dev-source")
    }

    /// The recorded checkout, if it may still win.
    ///
    /// A checkout wins only while it CONTAINS the running app's own build:
    /// on 30 Sep this Mac's Codex hooks ran from a checkout 96 commits behind
    /// the installed app and the audit called them healthy, because a
    /// developer's checkout had been ranked first unconditionally. A checkout
    /// that is behind the app is the app's older self, and never wins. When
    /// the answer cannot be established (no git, no commit in the build, the
    /// commit not fetched there) the staged rules win: the safe default is the
    /// rules the running app ships.
    public static func devSource(root: URL = root, appCommit: String?,
                                 contains: (_ checkout: String, _ commit: String) -> Bool = gitContains)
        -> String? {
        guard let recorded = (try? String(contentsOf: devSourceURL(in: root), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines), !recorded.isEmpty,
              let commit = appCommit, !commit.isEmpty,
              FileManager.default.fileExists(atPath: recorded + "/hooks"),
              FileManager.default.fileExists(atPath: recorded + "/skills")
        else { return nil }
        return contains(recorded, commit) ? recorded : nil
    }

    /// `git merge-base --is-ancestor <commit> HEAD` in the checkout.
    public static func gitContains(_ checkout: String, _ commit: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", checkout, "merge-base", "--is-ancestor", commit, "HEAD"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// The running app's source commit, from its Info.plist.
    public static var appCommit: String? {
        Bundle.main.object(forInfoDictionaryKey: "TBSourceCommit") as? String
    }

    // MARK: - What every harness should read

    /// The directories the reconcile links every harness to: a developer
    /// checkout that may still win, else the staged rules. Nil only when
    /// nothing is staged and no checkout qualifies, which the reconcile must
    /// treat as "cannot repair", never as "link somewhere else".
    public struct Desired: Sendable, Equatable {
        public let hooks: String
        public let skills: String
        public let openCode: String?
        public let fingerprint: String?
        public let fromCheckout: Bool
    }

    public static func desired(root: URL = root, appCommit: String? = appCommit,
                               contains: (_ checkout: String, _ commit: String) -> Bool = gitContains)
        -> Desired? {
        if let checkout = devSource(root: root, appCommit: appCommit, contains: contains) {
            let oc = checkout + "/opencode"
            return Desired(hooks: checkout + "/hooks", skills: checkout + "/skills",
                           openCode: FileManager.default.fileExists(atPath: oc) ? oc : nil,
                           fingerprint: nil, fromCheckout: true)
        }
        guard let fp = currentFingerprint(in: root) else { return nil }
        let oc = openCodeDirectory(in: root)
        return Desired(hooks: hooksDirectory(in: root), skills: skillsDirectory(in: root),
                       openCode: FileManager.default.fileExists(atPath: oc) ? oc : nil,
                       fingerprint: fp, fromCheckout: false)
    }
}
