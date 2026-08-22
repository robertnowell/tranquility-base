import Foundation

/// How this machine starts an agent, in one place: the command and the
/// directory.
///
/// Ruled 12 Aug, after the revival feature shipped a second launch path and the
/// two disagreed: a session started from the panel ran unattended, and the same
/// session REVIVED from the panel stopped at every tool call, because only the
/// first carried `--dangerously-skip-permissions`. Robert: "any new or revived
/// session gets launched under the same parameters."
///
/// So the command is a setting rather than a constant, and both paths read it.
/// The shape follows Vibe Kanban's, which solves the same problem: the user
/// configures how their agent is launched — `claude`, `codex`, with or without
/// the flag that lets it work without asking — and everything that starts an
/// agent obeys it.
///
/// Resume is not a second setting. `--resume <id>` is appended to whatever this
/// says, so a session brought back is the same kind of agent as a session
/// started, by construction rather than by two constants agreeing.
public enum AgentDefaults {

    /// What this machine used before the setting existed, and still the default:
    /// the away channel is the product, and an agent that stops to ask is an
    /// agent you have to go back to the terminal for.
    public static let fallback = "claude --dangerously-skip-permissions"

    /// Where a new agent starts when you have not said otherwise. The home
    /// directory, as it always was — ruled 15 Aug that this becomes a setting
    /// alongside the command, global for now: "we could just make that a
    /// global setting for now and see if we need more granular later."
    ///
    /// A REVIVED agent ignores this entirely and uses the directory its own
    /// transcript records, because resuming a conversation somewhere it never
    /// ran is not the same session in any sense that matters.
    public static var fallbackDirectory: String { NSHomeDirectory() }

    /// Overridable for tests; the app always uses the support directory. The
    /// filename is the old one so a machine that has already set a command
    /// keeps it across this change.
    nonisolated(unsafe) public static var fileURL: URL =
        QueueStore.supportDirectory.appendingPathComponent("agent-command.json")

    private struct Stored: Codable {
        var command: String
        /// Absent in files written before 15 Aug, which read as "unset".
        var directory: String?
        // A `tmux: Bool?` opt-in lived here 19 Aug through 21 Aug — new
        // launches keep loading files written during that window fine
        // (Decodable ignores unknown keys), they just never read the field
        // again. Ruled 21 Aug: no flags, tmux is simply how a launch works;
        // an old machine's stored `true`/`false` is inert, not honored.
    }

    /// The configured command, or the fallback when nothing has been set.
    ///
    /// A stored EMPTY string is treated as unset rather than honored — unlike
    /// the voice roster, where emptying it is a meaningful choice. There is no
    /// useful meaning for "launch agents with no command", and a blank field
    /// saved by accident would otherwise break every launch on the machine.
    private static func stored() -> Stored? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    private static func write(_ value: Stored) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: fileURL)
    }

    public static func load() -> String {
        guard let stored = stored(),
              !stored.command.trimmingCharacters(in: .whitespaces).isEmpty
        else { return fallback }
        return stored.command
    }

    public static func save(_ command: String) {
        let old = stored()
        write(Stored(command: command, directory: old?.directory))
    }

    /// The configured start directory, or home when nothing is set.
    ///
    /// A path that does not EXIST falls back rather than being honoured: the
    /// setting is typed by hand, a typo is one keystroke away, and a launch
    /// into a directory that is not there fails in Terminal where the panel
    /// cannot see it. Home always exists.
    public static func directory() -> String {
        guard let path = stored()?.directory?.trimmingCharacters(in: .whitespaces),
              !path.isEmpty else { return fallbackDirectory }
        let expanded = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
              isDir.boolValue else { return fallbackDirectory }
        return expanded
    }

    /// What the settings pane shows: what was typed, not what it resolved to,
    /// so a path that has gone missing is visible as itself rather than
    /// silently replaced by home in the field the user is editing.
    public static func directoryAsTyped() -> String { stored()?.directory ?? "" }

    public static func save(directory: String) {
        let old = stored()
        write(Stored(command: old?.command ?? fallback, directory: directory))
    }
}
