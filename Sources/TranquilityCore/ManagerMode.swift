import Foundation

/// Manager mode (19 Sep 2026): the hands-free manager as a stdio child of the app.
///
/// The manager (tb-voice) listens all day, decides with Jev whether it was
/// addressed, and drives the fleet through the doors the app already has:
/// `tbase send`, `tbase new`, and the speak-only deep links. What the app owes
/// it is a place to stand: the app spawns it exactly the way it spawns an ACP
/// agent, reads one JSON line per event from its stdout, and paints the orb
/// and the state label from those lines. The child never learns anything
/// about the app's audio path, and the app never parses the child's speech.
///
/// `ManagerEvent` is the contract. A native manager written in Core later
/// emits the same lines, and the orb does not know the difference.
public struct ManagerEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// The user started speaking; nothing decided yet.
        case hearing
        /// A finished turn the manager heard and stayed silent on.
        case listening
        /// A finished turn the manager was addressed by; `intent` says what.
        case addressed
        /// The manager, or a session on its behalf, is about to speak.
        case speaking
        /// The manager's own voice stopped.
        case quiet
        /// A session took the stage.
        case stage
        /// The manager asks the app to play a cue by name.
        case earcon
        /// A door the manager walked through: `tbase send`, `open …://hear`.
        case tool
        /// Something failed, with its reason; the manager said a fixed line.
        case error
    }
    public var event: Kind
    public var t: Double?
    public var p: Double?
    public var intent: String?
    public var text: String?
    public var session: String?
    public var goal: String?
    public var project: String?
    public var name: String?
    public var voice: String?
    public var rung: String?
    public var ms: Int?
    public var meaning: String?
    public var reason: String?

    public static func parse(_ line: Data) -> ManagerEvent? {
        try? JSONDecoder().decode(ManagerEvent.self, from: line)
    }
}

public enum ManagerConfig {
    /// The command that starts the manager, from `~/.claude/hq.json`
    /// (`manager.command`, an argv array) or the default checkout beside the
    /// app's own. A path in config is a path the user typed; nothing here
    /// invents one.
    public static func command(config: URL = HubApp.configPath) -> [String] {
        if let data = try? Data(contentsOf: config),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let manager = obj["manager"] as? [String: Any],
           let argv = manager["command"] as? [String], !argv.isEmpty {
            return argv
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/Projects/voice-controlled-coding-agents/tb-voice/server/run.sh"]
    }

    /// The child's environment: the user's, plus the marker that tells the
    /// bot the app is hosting it (so the app plays the cues, not the bot) and
    /// a PATH that can find `uv`, `open`, and `tbase`.
    public static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["TB_HOST"] = "app"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        env["PATH"] = (extra + (env["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
        return env
    }
}
