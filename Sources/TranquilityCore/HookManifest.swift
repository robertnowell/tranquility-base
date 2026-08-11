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
    }

    /// Must mirror `tbase install-hooks`. Kept here rather than there so the app can
    /// read it without shelling out, and so the two can be diffed in a test.
    public static let expected: [Hook] = [
        .init(event: "Stop", marker: "tbase-hook", script: "tbase-hook.sh",
              purpose: "hear a turn when it lands"),
        .init(event: "Notification", marker: "tbase-hook", script: "tbase-hook.sh",
              purpose: "hear a session asking for you"),
        .init(event: "UserPromptSubmit", marker: "tbase-hook", script: "tbase-hook.sh",
              purpose: "retire a turn you answered yourself"),
        .init(event: "SessionStart", marker: "visual-output-hook", script: "visual-output-hook.sh",
              purpose: "show visual output in a browser, not the tab"),
        .init(event: "PostToolUse", marker: "artifact-hook", script: "artifact-hook.sh",
              purpose: "collect artifacts a session writes"),
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
        return "hooks: " + parts.joined(separator: ", ") + " — run `tbase install-hooks`"
    }
}
