import Foundation

/// What the app expects to be wired into Claude Code, and what actually is.
///
/// There was no manifest at all. `install-hooks` held the list inline, ran once, and
/// nothing ever compared it against reality again — so three failures were invisible
/// by construction:
///
///   1. A hook whose file was renamed still "succeeds". The script's contract is to
///      exit 0 whatever happens, which is right for a hook and means a MISSING script
///      is indistinguishable from a healthy one. The rename from voice-dispatch-hook
///      to tbase-hook left settings.json pointing at a file that no longer existed;
///      events stopped for 37 minutes during active use and the only symptom was
///      session lamps that would not turn green.
///   2. A hook added to the repo after someone last ran install-hooks is simply never
///      installed, and nothing mentions it. `artifact-hook` shipped and was absent on
///      this machine when the manifest was written.
///   3. Paths are absolute and derived from the working directory at install time, so
///      moving the repo silently breaks every one of them.
///
/// This type is the comparison those three needed. It does not install anything —
/// noticing and repairing are separate acts, and the first is what was missing.
public enum HookManifest {

    public struct Hook: Sendable, Equatable {
        public let event: String
        /// Substring that identifies this hook's command, independent of where the
        /// repo lives. Matching on the marker rather than the full path is what lets a
        /// moved repo be recognised as "installed but stale" instead of "absent".
        public let marker: String
        public let script: String
        public let purpose: String
        /// Claude Code matcher, for hooks that must not run on every tool call.
        /// Only artifact-hook carries one: it fires after Write rather than at a
        /// turn boundary, and matcherless it would be thousands of no-op
        /// subprocesses a day.
        public let matcher: String?
    }

    /// THE wiring table — `tbase install-hooks` reads this same list, so the two
    /// cannot drift ("must mirror" was the old contract, and mirrors drift; the
    /// settings pose taught that the same week).
    public static let expected: [Hook] = [
        .init(event: "Stop", marker: "tbase-hook", script: "tbase-hook.sh",
              purpose: "hear a turn when it lands", matcher: nil),
        .init(event: "Notification", marker: "tbase-hook", script: "tbase-hook.sh",
              purpose: "hear a session asking for you", matcher: nil),
        .init(event: "UserPromptSubmit", marker: "tbase-hook", script: "tbase-hook.sh",
              purpose: "retire a turn you answered yourself", matcher: nil),
        .init(event: "SessionStart", marker: "visual-output-hook", script: "visual-output-hook.sh",
              purpose: "show visual output in a browser, not the tab", matcher: nil),
        // Write|Edit|Bash, not Write alone. Keying the record to ONE tool made
        // authorship depend on how a file happened to be written: a page built
        // by a heredoc, a python one-liner, or an Edit was invisible to the
        // hub, which is how a session's own research report failed to appear
        // on its page while the session was still looking at it (16 Aug).
        .init(event: "PostToolUse", marker: "artifact-hook", script: "artifact-hook.sh",
              purpose: "collect artifacts a session writes", matcher: "Write|Edit|Bash"),
    ]

    public enum State: Sendable, Equatable {
        case installed
        /// Wired, but the command it names is not on disk — the silent-death case.
        case brokenPath(String)
        case missing
    }

    public struct Status: Sendable, Equatable {
        public let hook: Hook
        public let state: State
    }

    public static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// Compare expectation against `~/.claude/settings.json`.
    ///
    /// Returns `nil` rather than an empty result when settings cannot be read at all:
    /// "no hooks installed" and "I could not tell" are different answers, and only one
    /// of them should make an app shout at you.
    public static func audit(settings url: URL = settingsURL) -> [Status]? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let hooks = root["hooks"] as? [String: Any] ?? [:]

        return expected.map { hook in
            let entries = hooks[hook.event] as? [[String: Any]] ?? []
            let commands = entries.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
                .compactMap { $0["command"] as? String }
            guard let command = commands.first(where: { $0.contains(hook.marker) }) else {
                return Status(hook: hook, state: .missing)
            }
            // The path is what rots — a rename, a moved repo, a deleted checkout. The
            // marker being present proves only that someone once installed it.
            let executable = command.split(separator: " ").first.map(String.init) ?? command
            return FileManager.default.fileExists(atPath: executable)
                ? Status(hook: hook, state: .installed)
                : Status(hook: hook, state: .brokenPath(executable))
        }
    }

    /// One line for a menu or a log: nil when everything is wired and reachable.
    public static func problemSummary(settings url: URL = settingsURL) -> String? {
        guard let statuses = audit(settings: url) else { return "hooks: settings unreadable" }
        let broken = statuses.filter { if case .brokenPath = $0.state { return true } else { return false } }
        let missing = statuses.filter { $0.state == .missing }
        if broken.isEmpty, missing.isEmpty { return nil }
        var parts: [String] = []
        if !broken.isEmpty { parts.append("\(broken.count) pointing at a missing file") }
        if !missing.isEmpty { parts.append("\(missing.count) not installed") }
        return "hooks: " + parts.joined(separator: ", ")
    }

    // MARK: - Repair

    /// Where the last successful sync found the hook scripts. Written by `sync`,
    /// read by `repair` when no healthy entry is left to learn the directory
    /// from — the case where the repo moved and every path broke at once.
    public static var recordedDirectoryURL: URL {
        QueueStore.supportDirectory.appendingPathComponent("hooks-dir")
    }

    public enum RepairOutcome: Sendable, Equatable {
        /// Nothing was wrong; nothing was touched.
        case healthy
        /// Something was wrong and is now fixed; settings were rewritten.
        case repaired(rewired: Int, added: Int)
        /// Could not repair, with the reason. Noticing remains the floor: the
        /// caller should say this out loud, because a hook's own contract (exit
        /// 0 whatever happens) means nothing else ever will.
        case unavailable(String)
    }

    /// Make `~/.claude/settings.json` match `expected`, nondestructively.
    ///
    /// Nobody runs a command (Robert, 12 Aug): the app repairs at launch and
    /// says what it did. The write is bounded exactly like `tbase
    /// install-hooks` always was — only entries carrying our markers are
    /// touched, everything else in the file is preserved byte-for-byte through
    /// the JSON round-trip, and the previous file is kept at
    /// settings.json.tbase-backup.
    ///
    /// The scripts' directory is learned, never guessed: from any expected
    /// entry whose command still resolves (a healthy tbase-hook knows where
    /// artifact-hook.sh lives), else from the directory the last sync
    /// recorded. If neither yields a directory that actually holds every
    /// expected script executable, this returns `.unavailable` and touches
    /// nothing — repairing hooks to paths that do not exist is how the silent
    /// death this manifest exists to catch would be REINSTALLED.
    public static func repair(settings url: URL = settingsURL,
                              record recordURL: URL = recordedDirectoryURL) -> RepairOutcome {
        guard let statuses = audit(settings: url) else {
            return .unavailable("settings unreadable")
        }
        if statuses.allSatisfy({ $0.state == .installed }) { return .healthy }

        // Learn the directory.
        var candidates: [String] = []
        guard let data = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unavailable("settings unreadable") }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for status in statuses where status.state == .installed {
            if let command = installedCommand(for: status.hook, in: hooks) {
                candidates.append((command as NSString).deletingLastPathComponent)
            }
        }
        if let recorded = try? String(contentsOf: recordURL, encoding: .utf8) {
            candidates.append(recorded.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let directory = candidates.first(where: directoryHoldsEveryScript) else {
            return .unavailable("cannot locate the hooks directory — "
                + "run `tbase install-hooks` from the repo once")
        }

        var rewired = 0, added = 0
        for hook in expected {
            let path = directory + "/" + hook.script
            var entries = hooks[hook.event] as? [[String: Any]] ?? []
            var matched = false
            for (i, entry) in entries.enumerated() {
                guard var inner = entry["hooks"] as? [[String: Any]],
                      let j = inner.firstIndex(where: {
                          ($0["command"] as? String)?.contains(hook.marker) == true })
                else { continue }
                matched = true
                if (inner[j]["command"] as? String) != path {
                    inner[j]["command"] = path
                    var updated = entry
                    updated["hooks"] = inner
                    entries[i] = updated
                    rewired += 1
                }
            }
            if !matched {
                var entry: [String: Any] = [
                    "hooks": [["type": "command", "command": path, "timeout": 5]]]
                if let matcher = hook.matcher { entry["matcher"] = matcher }
                entries.append(entry)
                added += 1
            }
            hooks[hook.event] = entries
        }
        guard rewired + added > 0 else {
            // Audited unhealthy yet nothing changed: the broken command exists
            // and already points where it should — the script itself is gone.
            return .unavailable("scripts missing at \(directory)")
        }

        root["hooks"] = hooks
        guard let out = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        else { return .unavailable("could not serialize settings") }
        try? data.write(to: url.appendingPathExtension("tbase-backup"))
        do { try out.write(to: url, options: .atomic) }
        catch { return .unavailable("could not write settings: \(error)") }
        try? directory.write(to: recordURL, atomically: true, encoding: .utf8)

        // The receipt is a re-audit, not the absence of a throw.
        guard problemSummary(settings: url) == nil else {
            return .unavailable("rewrote settings and the audit still fails — "
                + "backup at settings.json.tbase-backup")
        }
        return .repaired(rewired: rewired, added: added)
    }

    private static func installedCommand(for hook: Hook, in hooks: [String: Any]) -> String? {
        let entries = hooks[hook.event] as? [[String: Any]] ?? []
        return entries.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
            .first { $0.contains(hook.marker) }
    }

    private static func directoryHoldsEveryScript(_ directory: String) -> Bool {
        !directory.isEmpty && Set(expected.map(\.script)).allSatisfy {
            FileManager.default.isExecutableFile(atPath: directory + "/" + $0)
        }
    }
}
