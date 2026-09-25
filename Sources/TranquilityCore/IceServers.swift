import Foundation

/// Where a hands-free session is allowed to route its audio.
///
/// Until now this was one hardcoded line — Google's public STUN server and
/// nothing else. STUN only tells a client its own public address; it does not
/// carry a byte of audio. That is enough on a home network, where the two ends
/// can reach each other directly once they know where they are. It is not
/// enough behind a symmetric NAT or a firewall that blocks UDP, and there the
/// session simply never connects: no error worth reading, no fallback, nothing
/// to try. That is most corporate networks, and we have users now.
///
/// A TURN server is the relay that makes those cases work, and the reason it
/// cannot be a constant like the STUN line is that it needs credentials. They
/// are short-lived on purpose — an open relay is somebody else's bandwidth
/// bill — so they arrive with the session rather than living in the binary.
///
/// Cloudflare's own instruction, and the shape of this type: "You should keep
/// your TURN key on the server side (don't share it with the browser/app)."
/// The long-term key belongs to whoever issues sessions; the app only ever
/// sees the minted result.
public struct IceServer: Sendable, Equatable, Codable {
    public let urls: [String]
    public let username: String?
    public let credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }

    /// Both spellings, because two sources produce these: a relay API answers
    /// with `urls` as a list, and a hand-written config is likelier to carry
    /// one `url`. Neither is worth a second type.
    public init?(json: [String: Any]) {
        let urls = (json["urls"] as? [String])
            ?? (json["urls"] as? String).map { [$0] }
            ?? (json["url"] as? String).map { [$0] }
        guard let urls, !urls.isEmpty else { return nil }
        self.urls = urls
        self.username = json["username"] as? String
        self.credential = json["credential"] as? String
    }

    /// True when this entry can actually relay, rather than only reflect. The
    /// distinction is the whole point of the change, so it is named.
    public var relays: Bool {
        urls.contains { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") }
    }
}

public enum IceServers {
    /// What we shipped before there was anywhere to get credentials from, and
    /// what a session falls back to when none arrive. Reflection only: it will
    /// connect on an ordinary home network and fail on a hostile one.
    public static let stunOnly = [IceServer(urls: ["stun:stun.l.google.com:19302"])]

    /// Parse whatever the session or the config handed us; empty means "use
    /// the fallback", never "route nowhere".
    public static func parse(_ any: Any?) -> [IceServer] {
        guard let list = any as? [[String: Any]] else { return [] }
        return list.compactMap(IceServer.init(json:))
    }

    /// One line for the log, because a session that cannot connect should not
    /// require guessing whether it had a relay to try.
    public static func describe(_ servers: [IceServer]) -> String {
        let relays = servers.filter(\.relays).count
        return "\(servers.count) ice server(s), \(relays) that can relay"
    }
}
