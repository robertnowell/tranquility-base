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
        /// The pipeline is up and the microphone is open: listening for real.
        case ready
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
        /// The child's source changed; it is about to exit 75 for a restart.
        case reloading
        /// A session took the stage.
        case stage
        /// The manager asks the app to play a cue by name.
        case earcon
        /// A door the manager walked through: `tbase send`, `open …://hear`.
        case tool
        /// Something failed, with its reason; the manager said a fixed line.
        case error
        /// Hosted: nobody spoke for `secs`; the bot is ending the session itself.
        case idle
        /// Hosted: the session's life (`secs`) is up; the bot ends it with
        /// nothing open, and the app opens a fresh one.
        case rotate
        /// One line of the exchange, whole, with its role and kind (hf-20,
        /// hf-26). The ledger records it; the orb has nothing to show for it.
        case said
        /// How far through the line the voice has got, as a character count of
        /// what has been spoken. The card has highlighted words as they are
        /// said since long before hands-free; this is the same fact arriving
        /// from the bot instead of from a synthesiser on this Mac.
        case spoke
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
    public var secs: Int?
    /// `spoke`: characters of `text` said so far.
    public var upTo: Int?
    /// `spoke`: when this word is MEANT to be heard, in seconds on the bot's
    /// own clock. Not when the event arrived, which is the distinction that
    /// matters: ElevenLabs returns a whole utterance's alignment with the
    /// audio, so every word event lands in the same tick and painting them on
    /// arrival lights the line in one flash and then waits three seconds for
    /// the voice to catch up (reported 28 Sep). Absent from an older bot, in
    /// which case the panel paints on arrival as it used to.
    public var at: Double?

    public static func parse(_ line: Data) -> ManagerEvent? {
        try? JSONDecoder().decode(ManagerEvent.self, from: line)
    }
}

public enum ManagerConfig {
    /// The command that starts the manager, from `~/.claude/hq.json`
    /// (`manager.command`, an argv array) or the default checkout beside the
    /// app's own. A path in config is a path the user typed; nothing here
    /// invents one.
    /// A command the user typed into `hq.json`, or nil. Distinct from
    /// `command()`, which falls back to the default checkout: a hosted
    /// manager is chosen only when nothing local was asked for.
    public static func explicitCommand(config: URL = HubApp.configPath) -> [String]? {
        if let data = try? Data(contentsOf: config),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let manager = obj["manager"] as? [String: Any],
           let argv = manager["command"] as? [String], !argv.isEmpty {
            return argv
        }
        return nil
    }

    /// The `tbase` a hosted bot's door requests run: `manager.tbase` in
    /// `hq.json`, else the default checkout's debug build beside the app's own.
    /// Where the app finds `tbase`, the helper it executes for every question
    /// the manager asks about the fleet.
    ///
    /// **The bundled copy is the answer, and it was missing until 29 Sep.**
    /// Before this the order was: a path in hq.json, else a hardcoded path
    /// inside a source checkout. Both are a file somebody has to build by hand,
    /// and nothing in any deploy builds it -- so a merged fix to `Sources/tbase`
    /// passed CI, merged, installed, and did not run. Measured 28 Sep: the
    /// binary the app was executing had been built on the 21st, seven days and
    /// five shipped fixes earlier, and was still answering `status --json` with
    /// 200 rows while the fixed source answered with 15.
    ///
    /// Worse for anyone who is not the developer: that fallback points into a
    /// checkout of this repository. On a Mac without one there is no `tbase` at
    /// all, and every fleet question the manager asks fails.
    ///
    /// So: the override first, because a developer pointing at a local build is
    /// doing it deliberately and must keep winning. Then the copy inside the
    /// app, which an install updates like everything else. The old checkout
    /// path stays last, for a build running out of a checkout with no bundle
    /// around it.
    public static func tbasePath(config: URL = HubApp.configPath,
                                 bundled: String? = Self.bundledTbase) -> String {
        if let data = try? Data(contentsOf: config),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let manager = obj["manager"] as? [String: Any],
           let path = manager["tbase"] as? String, !path.isEmpty {
            return (path as NSString).expandingTildeInPath
        }
        if let bundled { return bundled }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Projects/voice-controlled-coding-agents/.build/arm64-apple-macosx/debug/tbase"
    }

    /// `tbase` as shipped inside the app, or nil when there is no bundle around
    /// us -- a unit test, or the CLI itself asking.
    public static var bundledTbase: String? {
        guard let url = Bundle.main.url(forResource: "tbase", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url.path
    }

    /// What HANDS-FREE would do if pressed.
    ///
    /// In order: a `manager.command` in hq.json is the developer's own bot and
    /// always wins; a signed-in Mac buys a session from the Gateway, which is
    /// the path every other user has; `manager.webrtc` is the dev shim that
    /// starts a Cloud session with a public key on this Mac; the default
    /// checkout's `run.sh` on disk is a local manager; and with none of them
    /// the placard reads SET UP HANDS-FREE and a press says why.
    ///
    /// `manager.hosted` was a fourth, and went with the WebSocket on 25 Sep.
    public enum Availability: Equatable, Sendable { case local, managed, unset }

    public static func availability(
        config: URL = HubApp.configPath,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        signedIn: () -> Bool = { HubApp.baseURL != nil && !(Secrets.read(.hubToken) ?? "").isEmpty }
    ) -> Availability {
        if explicitCommand(config: config) != nil { return .local }
        if signedIn() { return .managed }
        return fileExists(command(config: config)[0]) ? .local : .unset
    }

    /// The WebRTC media path, the one that lets the manager be interrupted
    /// while it speaks. `manager.webrtc` in hq.json, with the offer URL of a
    /// bot that speaks SmallWebRTC; absent, hands-free uses the WebSocket it
    /// always has. Nothing else about the panel changes: both transports show
    /// the same event lines and answer the same doors.
    public struct WebRTCManager: Sendable, Equatable {
        /// Where a session is started (`POST /start` on the hosted agent).
        public let start: URL
        /// The public key for that agent, until the Gateway issues these too.
        public let key: String
        /// Where this session may route audio. Empty means reflection only,
        /// which is a home network and nothing harder. See IceServers.swift.
        public let iceServers: [IceServer]

        public init(start: URL, key: String, iceServers: [IceServer] = []) {
            self.start = start
            self.key = key
            self.iceServers = iceServers
        }
    }

    public static func webrtc(config: URL = HubApp.configPath) -> WebRTCManager? {
        guard let data = try? Data(contentsOf: config),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let manager = obj["manager"] as? [String: Any],
              let rtc = manager["webrtc"] as? [String: Any],
              let start = (rtc["start"] as? String).flatMap(URL.init(string:)),
              let key = rtc["key"] as? String, !key.isEmpty else { return nil }
        return WebRTCManager(start: start, key: key,
                             iceServers: IceServers.parse(rtc["iceServers"]))
    }

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
