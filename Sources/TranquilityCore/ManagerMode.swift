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
        /// The developer talked over the manager: the line was cut where it
        /// was, and the rest of it will never be said.
        case interrupted
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
    /// `quiet` and `interrupted`: how long that line's voice ran, in seconds
    /// and fractions of one. NOT `secs`, which is whole seconds and belongs to
    /// the session's own life (`idle`, `rotate`). A fraction decoded into an
    /// Int fails the WHOLE event, and a `quiet` that does not decode is a card
    /// left half lit for ever -- which is what shipped on 29 Sep for the hour
    /// between the stop carrying a duration and this line existing.
    public var took: Double?
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
