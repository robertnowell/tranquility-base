import Foundation

/// How this machine starts an agent, in one place.
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
public enum AgentCommand {

    /// What this machine used before the setting existed, and still the default:
    /// the away channel is the product, and an agent that stops to ask is an
    /// agent you have to go back to the terminal for.
    public static let fallback = "claude --dangerously-skip-permissions"

    /// Overridable for tests; the app always uses the support directory.
    nonisolated(unsafe) public static var fileURL: URL =
        QueueStore.supportDirectory.appendingPathComponent("agent-command.json")

    private struct Stored: Codable { var command: String }

    /// The configured command, or the fallback when nothing has been set.
    ///
    /// A stored EMPTY string is treated as unset rather than honored — unlike
    /// the voice roster, where emptying it is a meaningful choice. There is no
    /// useful meaning for "launch agents with no command", and a blank field
    /// saved by accident would otherwise break every launch on the machine.
    public static func load() -> String {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              !stored.command.trimmingCharacters(in: .whitespaces).isEmpty
        else { return fallback }
        return stored.command
    }

    public static func save(_ command: String) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Stored(command: command)) else { return }
        try? data.write(to: fileURL)
    }

    /// The same command, pointed at a conversation that already exists.
    ///
    /// The id is appended as a separate argument by the caller rather than
    /// interpolated here, so nothing about a session id can reach a shell as
    /// syntax. It comes from a transcript filename and cannot contain a space
    /// today, which is a property of this Claude Code and not of this function.
    public static func resumeSuffix() -> String { "--resume" }
}
