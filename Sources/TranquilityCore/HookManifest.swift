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

    // MARK: - Harnesses

    /// One harness's hook wiring: where its config lives, what belongs in it,
    /// and how to tell whether this machine has that harness at all.
    ///
    /// The manifest had no harness dimension until 28 Aug, and that absence
    /// was invisible for the usual reason: everything it described was true,
    /// it just described half the machine. `expected` was one flat list and
    /// `settingsURL` a single hardcoded path, so the launch-time repair, the
    /// onboarding row and `tbase install-hooks` were all wired, all working,
    /// and all Claude Code. A Codex session therefore never received the
    /// SessionStart instruction that turns a visual into an HTML file you can
    /// open, never announced a finished turn, and never had a page it wrote
    /// collected into the hub. Robert noticed it as "Codex agents don't make
    /// HTML reports", which is the symptom furthest downstream of the cause.
    ///
    /// The row in the onboarding checklist said "Claude Code hooks" the whole
    /// time. The app was telling us; nobody read it as a limit.
    public struct Harness: Sendable, Equatable {
        /// Matches `HarnessAdapter.id`, so this never becomes a second
        /// vocabulary for the same thing.
        public let id: String
        /// For the checklist row and the repair note. User-facing.
        public let label: String
        /// The file this harness reads its hooks from. Claude Code's is a
        /// SHARED settings file that happens to hold hooks among much else;
        /// Codex's is dedicated. Both are merged into rather than rewritten,
        /// so the distinction costs nothing here.
        public let settingsURL: URL
        /// Whether this harness is installed. Its config directory existing is
        /// the test, deliberately: a machine that has never run Codex should
        /// not be told its Codex hooks are broken, and writing a hooks file
        /// into a directory the user has not created would be installing
        /// ourselves somewhere we were not invited.
        public let homeURL: URL
        public let expected: [Hook]

        public var isPresent: Bool {
            FileManager.default.fileExists(atPath: homeURL.path)
        }
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    public static var claudeCode: Harness {
        Harness(id: ClaudeCodeAdapter().id, label: "Claude Code",
                settingsURL: home.appendingPathComponent(".claude/settings.json"),
                homeURL: home.appendingPathComponent(".claude"),
                expected: expected)
    }

    /// Codex's half, and the events are its own names for the same facts.
    ///
    /// `PermissionRequest` rather than a `Notification` matcher: Codex has no
    /// Notification event, and its PermissionRequest is the thing that means
    /// "this session is asking you". `hooks/tbase-hook.sh` renames it on the
    /// way in so nothing downstream learns a second vocabulary.
    ///
    /// SessionStart and PostToolUse carry the same two scripts as Claude
    /// Code's, unchanged. Measured 28 Aug against codex-cli 0.150.1: Codex
    /// honours `hookSpecificOutput.additionalContext` exactly as Claude Code
    /// does (a `systemMessage` in the same payload did NOT reach the model),
    /// so `visual-output-hook.sh` installs verbatim rather than needing a
    /// per-harness output shape.
    public static var codex: Harness {
        Harness(id: CodexAdapter().id, label: "Codex",
                settingsURL: home.appendingPathComponent(".codex/hooks.json"),
                homeURL: home.appendingPathComponent(".codex"),
                expected: [
                    .init(event: "Stop", marker: "tbase-hook", script: "tbase-hook.sh",
                          purpose: "hear a turn when it lands", matcher: nil),
                    .init(event: "PermissionRequest", marker: "tbase-hook",
                          script: "tbase-hook.sh",
                          purpose: "hear a session asking for you", matcher: nil),
                    .init(event: "UserPromptSubmit", marker: "tbase-hook",
                          script: "tbase-hook.sh",
                          purpose: "retire a turn you answered yourself", matcher: nil),
                    .init(event: "SessionStart", marker: "visual-output-hook",
                          script: "visual-output-hook.sh",
                          purpose: "show visual output in a browser, not the tab",
                          matcher: nil),
                    .init(event: "PostToolUse", marker: "artifact-hook",
                          script: "artifact-hook.sh",
                          purpose: "collect artifacts a session writes",
                          matcher: "Write|Edit|Bash"),
                ])
    }

    public static var harnesses: [Harness] { [claudeCode, codex] }

    /// The harnesses this machine actually has. Order is stable so a repair
    /// note reads the same way twice.
    public static func detected() -> [Harness] { harnesses.filter(\.isPresent) }

    public enum State: Sendable, Equatable {
        case installed
        /// Wired, but the command it names is not on disk — the silent-death case.
        case brokenPath(String)
        /// Wired and on disk, but firing on the wrong tools. The manifest is
        /// the contract; a matcher that drifts from it is a hook that runs at
        /// the wrong moments and reports itself healthy while doing so.
        case staleMatcher(found: String?)
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
    public static func audit(settings url: URL = settingsURL,
                             expecting wanted: [Hook] = expected) -> [Status]? {
        // ABSENT is not UNREADABLE, and conflating them cost a whole install
        // path. A user whose Claude Code has never written settings.json got
        // `nil` here, which `repair` turned into "settings unreadable" and
        // `tbase install-hooks` turned into exit 1 -- telling someone their
        // file could not be read when the honest answer is that they do not
        // have one yet, and that we are about to write it. A missing file is
        // the clearest possible statement that nothing is installed.
        if !FileManager.default.fileExists(atPath: url.path) {
            return wanted.map { Status(hook: $0, state: .missing) }
        }
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let hooks = root["hooks"] as? [String: Any] ?? [:]

        return wanted.map { hook in
            let entries = hooks[hook.event] as? [[String: Any]] ?? []
            let commands = entries.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
                .compactMap { $0["command"] as? String }
            guard let command = commands.first(where: { $0.contains(hook.marker) }) else {
                return Status(hook: hook, state: .missing)
            }
            // The path is what rots — a rename, a moved repo, a deleted checkout. The
            // marker being present proves only that someone once installed it.
            let executable = command.split(separator: " ").first.map(String.init) ?? command
            guard FileManager.default.fileExists(atPath: executable) else {
                return Status(hook: hook, state: .brokenPath(executable))
            }
            // The matcher is contract, not decoration: widening artifact-hook
            // to Write|Edit|Bash left the installed hook firing on Write while
            // the audit called it healthy (16 Aug).
            let owner = entries.first {
                (($0["hooks"] as? [[String: Any]]) ?? [])
                    .contains { ($0["command"] as? String)?.contains(hook.marker) == true }
            }
            let found = owner?["matcher"] as? String
            return found == hook.matcher
                ? Status(hook: hook, state: .installed)
                : Status(hook: hook, state: .staleMatcher(found: found))
        }
    }

    /// One line for a menu or a log: nil when everything is wired and reachable.
    public static func problemSummary(settings url: URL = settingsURL,
                                      expecting wanted: [Hook] = expected) -> String? {
        guard let statuses = audit(settings: url, expecting: wanted)
        else { return "hooks: settings unreadable" }
        let broken = statuses.filter { if case .brokenPath = $0.state { return true } else { return false } }
        let missing = statuses.filter { $0.state == .missing }
        let stale = statuses.filter {
            if case .staleMatcher = $0.state { return true } else { return false }
        }
        if broken.isEmpty, missing.isEmpty, stale.isEmpty { return nil }
        var parts: [String] = []
        if !broken.isEmpty { parts.append("\(broken.count) pointing at a missing file") }
        if !missing.isEmpty { parts.append("\(missing.count) not installed") }
        if !stale.isEmpty { parts.append("\(stale.count) firing on the wrong tools") }
        return "hooks: " + parts.joined(separator: ", ")
    }

    // MARK: - Repair

    /// Where the last successful sync found the hook scripts. Written by `sync`,
    /// read by `repair` when no healthy entry is left to learn the directory
    /// from — the case where the repo moved and every path broke at once.
    public static var recordedDirectoryURL: URL {
        QueueStore.supportDirectory.appendingPathComponent("hooks-dir")
    }

    /// The hooks carried INSIDE the .app, if this build has them.
    ///
    /// The last-resort source, and the one that makes a shipped binary work at
    /// all: a user handed a built app has no checkout for the recorded
    /// directory to point at, so before this every path in the file was a path
    /// into somebody else's Mac. A directory inside the bundle moves with the
    /// bundle, which also closes failure mode 3 (the moved repo) for good --
    /// there is nothing left to move away from.
    ///
    /// Deliberately LAST in the candidate order. A developer running from a
    /// checkout has a recorded directory pointing at that checkout, and their
    /// edits to hooks/*.sh must keep taking effect without a rebuild; if the
    /// bundle won, every debug build would silently repoint settings.json at a
    /// frozen copy under .build/ and the next edit would do nothing.
    ///
    /// nil when the app was not assembled by bundle.sh (a bare SwiftPM binary,
    /// or `tbase`, whose Bundle.main is a directory of executables) -- the
    /// every-script check below rejects those without a special case.
    public static var bundledDirectory: String? {
        guard let resources = Bundle.main.resourceURL?
            .appendingPathComponent("hooks", isDirectory: true).path,
              directoryHoldsEveryScript(resources)
        else { return nil }
        return resources
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
                              record recordURL: URL = recordedDirectoryURL,
                              expecting wanted: [Hook] = expected) -> RepairOutcome {
        guard let statuses = audit(settings: url, expecting: wanted) else {
            return .unavailable("settings unreadable")
        }
        if statuses.allSatisfy({ $0.state == .installed }) { return .healthy }

        // Learn the directory.
        var candidates: [String] = []
        // An absent file starts from `{}` rather than refusing: audit() has
        // already said every hook is missing, and the repair for "you have no
        // settings file" is to write one.
        let existed = FileManager.default.fileExists(atPath: url.path)
        let data = existed ? (try? Data(contentsOf: url)) : Data("{}".utf8)
        guard let data,
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unavailable("settings unreadable") }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        // A stale matcher still names a file that exists, so it is as good a
        // witness to the hooks directory as a fully healthy entry.
        for status in statuses where status.state == .installed
            || { if case .staleMatcher = status.state { return true } else { return false } }() {
            if let command = installedCommand(for: status.hook, in: hooks) {
                candidates.append((command as NSString).deletingLastPathComponent)
            }
        }
        if let recorded = try? String(contentsOf: recordURL, encoding: .utf8) {
            candidates.append(recorded.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // Last: our own bundle. See `bundledDirectory` for why it ranks here
        // and not first.
        if let bundled = bundledDirectory { candidates.append(bundled) }
        guard let directory = candidates.first(where: directoryHoldsEveryScript) else {
            return .unavailable("cannot locate the hooks directory — "
                + "run `tbase install-hooks` from the repo once")  // unreachable from a bundled build
        }

        var rewired = 0, added = 0
        for hook in wanted {
            let path = directory + "/" + hook.script
            var entries = hooks[hook.event] as? [[String: Any]] ?? []
            var matched = false
            for (i, entry) in entries.enumerated() {
                guard var inner = entry["hooks"] as? [[String: Any]],
                      let j = inner.firstIndex(where: {
                          ($0["command"] as? String)?.contains(hook.marker) == true })
                else { continue }
                matched = true
                var updated = entry
                var changed = false
                if (inner[j]["command"] as? String) != path {
                    inner[j]["command"] = path
                    updated["hooks"] = inner
                    changed = true
                }
                // The MATCHER is part of the contract too, and repair used to
                // reconcile only the path: widening artifact-hook to
                // Write|Edit|Bash changed the manifest, the installer reported
                // "nothing changed", and the hook kept firing on Write alone
                // (16 Aug). A manifest that is only half enforced is a
                // manifest that lies twice — once about the setting, once
                // about having checked.
                if (updated["matcher"] as? String) != hook.matcher {
                    if let matcher = hook.matcher { updated["matcher"] = matcher }
                    else { updated.removeValue(forKey: "matcher") }
                    changed = true
                }
                if changed { entries[i] = updated; rewired += 1 }
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
        if existed { try? data.write(to: url.appendingPathExtension("tbase-backup")) }
        // ~/.claude may not exist yet on a machine that has only ever run the app.
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try out.write(to: url, options: .atomic) }
        catch { return .unavailable("could not write settings: \(error)") }
        try? directory.write(to: recordURL, atomically: true, encoding: .utf8)

        // The receipt is a re-audit, not the absence of a throw.
        guard problemSummary(settings: url, expecting: wanted) == nil else {
            return .unavailable("rewrote settings and the audit still fails — "
                + "backup at settings.json.tbase-backup")
        }
        return .repaired(rewired: rewired, added: added)
    }

    // MARK: - Every harness on this machine

    /// Audit every harness this machine has, and repair what is wrong.
    ///
    /// This is what the launch path and the onboarding row call. Per-harness
    /// outcomes rather than one verdict, because "Claude Code fine, Codex
    /// rewired 5" is the true answer and a single line cannot say it without
    /// lying about one of them.
    ///
    /// A harness that is not installed is not in the list at all, so nobody is
    /// told their Codex hooks are broken on a machine that has never run
    /// Codex.
    public static func repairAll(
        record recordURL: URL = recordedDirectoryURL
    ) -> [(harness: Harness, outcome: RepairOutcome)] {
        detected().map { harness in
            (harness, repair(settings: harness.settingsURL, record: recordURL,
                             expecting: harness.expected))
        }
    }

    /// One line for the launch log and the HUD, across every detected harness,
    /// or nil when the whole machine is wired.
    ///
    /// Names the harness. The old single-harness note said "New Claude Code
    /// sessions pick them up automatically", which was accurate and, on a
    /// two-harness machine, was the app quietly telling us what it had not
    /// done. A summary that cannot name which harness is broken reproduces
    /// exactly that.
    public static func machineSummary() -> String? {
        let problems = detected().compactMap { harness -> String? in
            problemSummary(settings: harness.settingsURL,
                           expecting: harness.expected)
                .map { "\(harness.label): \($0.replacingOccurrences(of: "hooks: ", with: ""))" }
        }
        return problems.isEmpty ? nil : "hooks: " + problems.joined(separator: "; ")
    }

    private static func installedCommand(for hook: Hook, in hooks: [String: Any]) -> String? {
        let entries = hooks[hook.event] as? [[String: Any]] ?? []
        return entries.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
            .first { $0.contains(hook.marker) }
    }

    /// EVERY harness's scripts, not just the one being repaired. They all
    /// live in one directory, and a directory holding only half of them is
    /// a checkout mid-move, not a hooks directory.
    public static func allScripts() -> Set<String> {
        Set(harnesses.flatMap { $0.expected.map(\.script) })
    }

    private static func directoryHoldsEveryScript(_ directory: String) -> Bool {
        !directory.isEmpty && allScripts().allSatisfy {
            FileManager.default.isExecutableFile(atPath: directory + "/" + $0)
        }
    }
}
