import Foundation

/// A hosted voice session bought from the Gateway.
///
/// The Gateway owns the money and the host: it reserves a block of minutes,
/// starts the bot on Pipecat Cloud, and hands back the socket to speak into.
/// The app never holds the host's key, and the bot never holds a bearer. One
/// reservation per block, and a block is a window, so a renewal opens the next
/// window where the last one ends rather than extending a reservation
/// (contracts/gateway/v1/VOICE.md).
public struct GatewayVoiceSession: Decodable, Sendable, Equatable {
    public let version: String
    public let accountId: String
    public let sessionId: String
    public let state: String
    public let startedAt: String
    public let endedAt: String?
    public let blocks: Int
    /// When the current block runs out. Renew before it; a few minutes early
    /// costs nothing, since the next window starts where this one ends.
    public let renewBy: String?
    public let chargedSeconds: String?
    public let pricebookVersion: String
    /// Present on start: the socket the app speaks into, and its token.
    public let wsUrl: String?
    public let token: String?

    public var isRunning: Bool { state == "running" }

    /// A formatter per call: ISO8601DateFormatter is not Sendable, and this
    /// is read once a session, not once a frame.
    public var renewByDate: Date? {
        guard let renewBy else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: renewBy) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: renewBy)
    }

    /// A reply worth acting on: the right shape, this account, this session,
    /// and a socket that is a socket. A start without a URL is not a session.
    func isValid(account: UUID, id: UUID, expectSocket: Bool) -> Bool {
        guard version == "1",
              accountId == account.uuidString.lowercased(),
              sessionId == id.uuidString.lowercased(),
              blocks >= 0 else { return false }
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
        var body: Data?
        if !keyterms.isEmpty {
            body = try JSONSerialization.data(withJSONObject: ["keyterms": Array(keyterms.prefix(64))])
        }
        return try await call("PUT", path(id), body: body, id: id, expectSocket: true)
    }

    public func renew(id: UUID) async throws -> GatewayVoiceSession {
        try await call("POST", path(id, "/renew"), body: nil, id: id, expectSocket: false)
    }

    /// End and settle by measured seconds. Calling it twice changes nothing.
    public func end(id: UUID) async throws -> GatewayVoiceSession {
        try await call("POST", path(id, "/end"), body: nil, id: id, expectSocket: false)
    }

    public func get(id: UUID) async throws -> GatewayVoiceSession {
        try await call("GET", path(id), body: nil, id: id, expectSocket: false)
    }

    private func call(_ method: String, _ path: String, body: Data?, id: UUID,
                      expectSocket: Bool) async throws -> GatewayVoiceSession {
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
        guard session.isValid(account: accountId, id: id, expectSocket: expectSocket) else {
            throw ManagedSummaryFailure.invalidResponse
        }
        return session
    }
}
