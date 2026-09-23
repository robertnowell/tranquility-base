import Foundation

/// A hosted voice session bought from the Gateway.
///
/// The Gateway owns the money and the host: it reserves a block of minutes,
/// starts the bot on Pipecat Cloud, and hands back the socket to speak into.
/// The app never holds the host's key, and the bot never holds a bearer. One
/// reservation per block, and a block is a window, so a renewal opens the next
/// window where the last one ends rather than extending a reservation
/// (contracts/gateway/v1/VOICE.md).
/// What every metered session says about the money, whichever kind it is.
///
/// The meter really is shared -- a block is a block and a minute costs what a
/// minute costs -- so these fields are common by right, not by coincidence.
/// What is NOT shared is how you reach the thing you are paying for, and that
/// is why the two kinds are two types below rather than one type with
/// optional fields. See the note on `GatewayTranscriptSession`.
public protocol GatewayMeteredSession: Decodable, Sendable {
    var version: String { get }
    var accountId: String { get }
    var sessionId: String { get }
    var state: String { get }
    var blocks: Int { get }
    /// When the current block runs out. Renew before it; a few minutes early
    /// costs nothing, since the next window starts where this one ends.
    var renewBy: String? { get }
}

public extension GatewayMeteredSession {
    var isRunning: Bool { state == "running" }

    /// A formatter per call: ISO8601DateFormatter is not Sendable, and this
    /// is read once a session, not once a frame.
    var renewByDate: Date? {
        guard let renewBy else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: renewBy) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: renewBy)
    }

    /// The parts that are about the money and the account, never the endpoint.
    func meterIsValid(account: UUID, id: UUID) -> Bool {
        version == "1"
            && accountId == account.uuidString.lowercased()
            && sessionId == id.uuidString.lowercased()
            && blocks >= 0
    }
}

/// A hosted voice session bought from the Gateway.
///
/// The Gateway owns the money and the host: it reserves a block of minutes,
/// starts the bot on Pipecat Cloud, and hands back the address to speak into.
/// The app never holds the host's key, and the bot never holds a bearer. One
/// reservation per block, and a block is a window, so a renewal opens the next
/// window where the last one ends rather than extending a reservation
/// (contracts/gateway/v1/VOICE.md).
///
/// A voice session can be carried by a socket or by a peer connection, and it
/// says which. It is NOT "a session whose socket might be missing".
public struct GatewayVoiceSession: GatewayMeteredSession, Equatable {
    public let version: String
    public let accountId: String
    public let sessionId: String
    public let state: String
    public let startedAt: String
    public let endedAt: String?
    public let blocks: Int
    public let renewBy: String?
    public let chargedSeconds: String?
    public let pricebookVersion: String
    /// `websocket` or `webrtc`. Absent on older replies, which were all sockets.
    public let transport: String?
    /// Present on a websocket start: the socket, and its token.
    public let wsUrl: String?
    public let token: String?
    /// Present on a webrtc start: where the client POSTs its SDP offer and
    /// PATCHes its ICE candidates. Derived by the Gateway, not by us -- the
    /// convention lives in one place. VOICE.md.
    public let offerUrl: String?

    public var isWebRTC: Bool { transport == "webrtc" }

    /// A reply worth acting on: the right account and session, and an address
    /// of the kind this session claims to be. A start with neither is not a
    /// session.
    func isValid(account: UUID, id: UUID, expectEndpoint: Bool) -> Bool {
        guard meterIsValid(account: account, id: id) else { return false }
        guard expectEndpoint else { return true }
        if isWebRTC {
            guard let offerUrl, let url = URL(string: offerUrl),
                  url.scheme == "https", url.host != nil else { return false }
            return true
        }
        guard let wsUrl, let url = URL(string: wsUrl), url.scheme == "wss", url.host != nil,
              let token, !token.isEmpty else { return false }
        return true
    }
}

/// A live-transcript session bought from the Gateway.
///
/// Deliberately its own type, and deliberately strict where the voice one is
/// not: **a transcript is always a socket.** The vendor speaks one protocol
/// and it is not WebRTC.
///
/// The two share a start path on the server, which is exactly the hazard.
/// While both decoded one struct, the socket check was one shared guard, and
/// relaxing it so a WebRTC voice session could pass would have silently
/// relaxed it for the transcript too -- and a transcript with no socket fails
/// by opening a connection to nothing, quietly, on the paid path. Two types
/// means each keeps its own requirement and neither can lose it on the
/// other's behalf.
public struct GatewayTranscriptSession: GatewayMeteredSession, Equatable {
    public let version: String
    public let accountId: String
    public let sessionId: String
    public let state: String
    public let blocks: Int
    public let renewBy: String?
    public let pricebookVersion: String
    /// Not optional in practice and not optional in the guard: see above.
    public let wsUrl: String?
    public let token: String?

    func isValid(account: UUID, id: UUID, expectSocket: Bool) -> Bool {
        guard meterIsValid(account: account, id: id) else { return false }
        guard expectSocket else { return true }
        guard let wsUrl, let url = URL(string: wsUrl), url.scheme == "wss", url.host != nil,
              let token, !token.isEmpty else { return false }
        return true
    }
}

/// The four calls a hands-free session makes. Nothing here decides when to
/// make them: the app does that from the socket's life (start on the chord,
/// renew before `renewBy`, end when the socket closes).
public struct ManagedVoiceClient: Sendable {
    public let accountId: UUID
    public let transport: any GatewayTransport

    public init(accountId: UUID, transport: any GatewayTransport) {
        self.accountId = accountId
        self.transport = transport
    }

    private func path(_ id: UUID, _ verb: String = "") -> String {
        "/v1/accounts/\(accountId.uuidString.lowercased())/voice/sessions/\(id.uuidString.lowercased())\(verb)"
    }

    /// Start, or pick up the one this id already named: PUT is idempotent, so
    /// a retry after a lost reply returns the same session and the same socket
    /// rather than reserving a second block.
    public func start(id: UUID, keyterms: [String] = []) async throws -> GatewayVoiceSession {
        var fields: [String: Any] = [:]
        if !keyterms.isEmpty { fields["keyterms"] = Array(keyterms.prefix(64)) }
        let body = fields.isEmpty ? nil : try JSONSerialization.data(withJSONObject: fields)
        return try await call("PUT", path(id), body: body, id: id, expectEndpoint: true)
    }

    public func renew(id: UUID) async throws -> GatewayVoiceSession {
        try await call("POST", path(id, "/renew"), body: nil, id: id, expectEndpoint: false)
    }

    /// End and settle by measured seconds. Calling it twice changes nothing.
    public func end(id: UUID) async throws -> GatewayVoiceSession {
        try await call("POST", path(id, "/end"), body: nil, id: id, expectEndpoint: false)
    }

    public func get(id: UUID) async throws -> GatewayVoiceSession {
        try await call("GET", path(id), body: nil, id: id, expectEndpoint: false)
    }

    private func call(_ method: String, _ path: String, body: Data?, id: UUID,
                      expectEndpoint: Bool) async throws -> GatewayVoiceSession {
        let response = try await transport.request(method: method, path: path, body: body)
        guard response.status == 200 else {
            // 402 is the credit standing the panel already shows; 503 is
            // "hands-free unavailable", never a sign-out.
            struct Envelope: Decodable { struct E: Decodable { let code: String }; let error: E }
            let code = (try? JSONDecoder().decode(Envelope.self, from: response.body))?.error.code
                ?? "service_unavailable"
            throw ManagedSummaryFailure.refused(code: code, operationId: nil)
        }
        let session = try JSONDecoder().decode(GatewayVoiceSession.self, from: response.body)
        guard session.isValid(account: accountId, id: id, expectEndpoint: expectEndpoint) else {
            throw ManagedSummaryFailure.invalidResponse
        }
        return session
    }
}
