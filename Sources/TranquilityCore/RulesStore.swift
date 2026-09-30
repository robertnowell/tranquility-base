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

    /// The fingerprint `current` points at, or nil when nothing is staged.
    public static func currentFingerprint(in root: URL = root) -> String? {
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
            if !fm.fileExists(atPath: target.appendingPathComponent(".complete").path) {
                let temp = versions.appendingPathComponent(".staging-\(fp)-\(getpid())", isDirectory: true)
                try? fm.removeItem(at: temp)
                try fm.createDirectory(at: temp, withIntermediateDirectories: true)
                for part in parts {
                    let from = resources.appendingPathComponent(part)
                    guard fm.fileExists(atPath: from.path) else { continue }
                    try fm.copyItem(at: from, to: temp.appendingPathComponent(part))
                }
                try fp.write(to: temp.appendingPathComponent(".fingerprint"), atomically: true, encoding: .utf8)
                try Data().write(to: temp.appendingPathComponent(".complete"))
                try? fm.removeItem(at: target)       // a half-staged leftover
                try fm.moveItem(at: temp, to: target)
            }
        } catch {
            return .unavailable("could not stage the rules: \(error.localizedDescription)")
        }

        let before = currentFingerprint(in: root)
        if before != fp {
            // Atomic switch: a new link beside `current`, renamed over it.
            let link = current(in: root)
            let fresh = root.appendingPathComponent(".current-\(getpid())")
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
        let others = names.filter { $0 != current && !$0.hasPrefix(".") }
            .map { versions.appendingPathComponent($0) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a > b
            }
        for stale in others.dropFirst(max(0, keep - 1)) { try? fm.removeItem(at: stale) }
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
