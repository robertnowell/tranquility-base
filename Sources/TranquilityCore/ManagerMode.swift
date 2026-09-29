import Foundation

/// Manager mode: the hands-free manager (tb-voice), hosted, reached over a
/// WebRTC peer (ManagerPeer). It listens all day, decides with Jev whether it
/// was addressed, and acts on this Mac only through the wire v1 tools the app
/// offers (docs/wire-v1.md). It sends one JSON line per event, and the app
/// paints the orb and the state label from those lines.
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
    /// The `tbase` a hosted bot's door requests run: `manager.tbase` in
    /// `hq.json`, else the default checkout's debug build beside the app's own.
    public static func tbasePath(config: URL = HubApp.configPath) -> String {
        if let data = try? Data(contentsOf: config),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let manager = obj["manager"] as? [String: Any],
           let path = manager["tbase"] as? String, !path.isEmpty {
            return (path as NSString).expandingTildeInPath
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Projects/voice-controlled-coding-agents/.build/arm64-apple-macosx/debug/tbase"
    }

    /// What HANDS-FREE would do if pressed.
    ///
    /// A signed-in Mac buys a session from the Gateway, which is the path
    /// every user has; `manager.webrtc` in hq.json (checked before this) is
    /// the dev shim that starts a session on a bot of the developer's own,
    /// hosted or on `localhost`. With neither, the placard reads SET UP
    /// HANDS-FREE and a press says why.
    ///
    /// There was a third until 29 Sep: `.local`, the bot as a stdio child of
    /// the app (`run.sh`, or `manager.command`). It duplicated the hosted
    /// manager with a second copy of every door, and 16 of 16 starts in the
    /// two days before it went bought a Gateway session (hf-24).
    public enum Availability: Equatable, Sendable { case managed, unset }

    public static func availability(
        signedIn: () -> Bool = { HubApp.baseURL != nil && !(Secrets.read(.hubToken) ?? "").isEmpty }
    ) -> Availability {
        signedIn() ? .managed : .unset
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
}
