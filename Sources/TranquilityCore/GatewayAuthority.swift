import Foundation

/// This Mac's key, kept across launches.
///
/// One key per installation, made once at pairing and used for every request
/// that spends afterwards. The enclave's own wrapped blob is what gets stored:
/// it is useless on any other machine, because the private half never existed
/// outside this one's Secure Enclave and cannot be extracted from the blob.
///
/// The software fallback stores a real private key, which is worth saying out
/// loud. On the one Mac that runs Sonoma without a Secure Enclave, the 2019
/// iMac, the guarantee drops from "cannot be copied" to "is a 0600 file like
/// every other secret here". That is a real difference and it is the honest
/// best available on that hardware.
public enum DeviceKeyStore {

    /// What was found, so a caller can say which guarantee it got rather than
    /// assume the stronger one.
    public struct Resolved {
        public let signer: DeviceKey.Signer
        public let created: Bool
    }

    /// The signer for this installation, made on first use.
    ///
    /// `load` and `save` are injected because a test cannot create an enclave
    /// key at all: that needs a signed application with entitlements, and an
    /// unsigned test binary is neither. Tests therefore drive the software
    /// path, which means a green test here is evidence about this logic and
    /// says nothing about the enclave. The enclave is the in-app drill's job.
    public static func resolve(
        load: () -> String? = { Secrets.read(.deviceKey) },
        save: (String) throws -> Void = { try Secrets.write(.deviceKey, value: $0) },
        makeEnclave: (Data?) -> DeviceKey.Signer? = { DeviceKey.EnclaveSigner(representation: $0) },
        makeSoftware: () -> DeviceKey.Signer = { DeviceKey.SoftwareSigner() }
    ) throws -> Resolved {
        if let stored = load(), let data = Data(base64Encoded: stored) {
            // An existing key is reused whatever it is. Making a new one would
            // silently orphan the thumbprint the hub recorded at pairing, and
            // the symptom would be every request refused with a valid key.
            if let enclave = makeEnclave(data) {
                return Resolved(signer: enclave, created: false)
            }
            if let software = DeviceKey.SoftwareSigner(storedRepresentation: data) {
                return Resolved(signer: software, created: false)
            }
        }
        if let enclave = makeEnclave(nil) as? DeviceKey.EnclaveSigner {
            try save(enclave.persistable.base64EncodedString())
            return Resolved(signer: enclave, created: true)
        }
        let software = makeSoftware()
        if let s = software as? DeviceKey.SoftwareSigner {
            try save(s.persistable.base64EncodedString())
        }
        return Resolved(signer: software, created: true)
    }
}

/// Authority to spend, fetched silently and never asked of the person.
///
/// The person signed in once, in a browser, and approved this Mac. Everything
/// after that happens here: the device token says which Mac, a proof signed by
/// the enclave key says the Mac is really here, and the hub returns a bearer
/// good for at most fifteen minutes. There is no second login, no token field,
/// and nothing for anyone to paste. See contracts/gateway/v1/AUTHORIZATION.md.
///
/// Held in memory only. A credential that spends is not written to disk when
/// re-obtaining it costs one silent request.
public actor GatewayAuthority {

    public enum Failure: Error, Equatable {
        /// No device token: this Mac is not connected to a hub at all.
        case notConnected
        /// The hub refused the device token. The person must connect again.
        case connectionRejected
        /// Paired before key binding. Connect again to enrol a key.
        case rebindingRequired
        /// The hub could not mint. NOT a sign-out, and must never be shown as
        /// one: managed work waits, the app stays signed in.
        case temporarilyUnavailable

        /// The refusal's name on the managed path, in the vocabulary the
        /// contract's error codes already use.
        public var code: String {
            switch self {
            case .notConnected: return "not_connected"
            case .connectionRejected: return "connection_rejected"
            case .rebindingRequired: return "rebinding_required"
            case .temporarilyUnavailable: return "service_unavailable"
            }
        }
    }

    /// One fetched bearer and when it stops being usable.
    private struct Grant {
        let token: String
        let expiresAt: Date
    }

    public typealias Exchange = @Sendable (_ proof: String, _ deviceToken: String)
        async throws -> (status: Int, body: Data)

    private let signer: DeviceKey.Signer
    private let tokenURL: URL
    private let deviceToken: @Sendable () -> String?
    private let exchange: Exchange
    private let now: () -> Date

    private var grant: Grant?
    /// The refresh currently in flight, so ten callers produce one request.
    private var inFlight: Task<String, Error>?

    /// Refreshed this far before expiry, so a request never starts with a
    /// token that dies mid-flight.
    private let margin: TimeInterval = 60

    public init(signer: DeviceKey.Signer, hubBase: URL,
                deviceToken: @escaping @Sendable () -> String? = { Secrets.read(.hubToken) },
                exchange: @escaping Exchange,
                now: @escaping () -> Date = { Date() }) {
        self.signer = signer
        self.tokenURL = hubBase.appendingPathComponent("api/gateway/token")
        self.deviceToken = deviceToken
        self.exchange = exchange
        self.now = now
    }

    /// A usable bearer, from cache when possible.
    public func bearer() async throws -> String {
        if let grant, grant.expiresAt.timeIntervalSince(now()) > margin {
            return grant.token
        }
        if let inFlight { return try await inFlight.value }
        let task = Task { try await fetch() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    /// What one request to the Gateway carries: the bound token, presented as
    /// DPoP and never as Bearer, and a proof made for exactly this method and
    /// URL that also names the token (`ath`), so a proof captured beside one
    /// token cannot be replayed with another. RFC 9449 sections 4.1 and 7.1.
    public struct Credential: Sendable, Equatable {
        public let authorization: String
        public let proof: String
    }

    public func credential(method: String, url: String) async throws -> Credential {
        let token = try await bearer()
        let proof = try DeviceKey.proof(
            signer: signer, method: method, url: url, accessToken: token, now: now())
        return Credential(authorization: "DPoP \(token)", proof: proof)
    }

    /// The real exchange: one POST to the hub's mint, carrying the device token
    /// as the hub's own Bearer and the proof in the DPoP header. Ephemeral
    /// session, no cookies, no cache, no redirects: a credential that spends
    /// goes to the route it was signed for and nowhere else.
    public static func httpExchange(tokenURL: URL) -> Exchange {
        final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
            func urlSession(_ session: URLSession, task: URLSessionTask,
                            willPerformHTTPRedirection response: HTTPURLResponse,
                            newRequest request: URLRequest,
                            completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
                completionHandler(nil)
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        return { proof, deviceToken in
            var request = URLRequest(url: tokenURL)
            request.httpMethod = "POST"
            request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
            request.setValue(proof, forHTTPHeaderField: "DPoP")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.temporarilyUnavailable }
            return (http.statusCode, data)
        }
    }

    /// Forget everything. Called on sign-out and on an account change.
    ///
    /// Cancelling the in-flight refresh matters as much as dropping the
    /// grant: a refresh begun as one account must not be allowed to install
    /// its result after the switch, which is how A's credential ends up
    /// serving B.
    public func clear() {
        grant = nil
        inFlight?.cancel()
        inFlight = nil
    }

    /// The proof the mint requires, and the request that carries it.
    private func fetch() async throws -> String {
        guard let token = deviceToken(), !token.isEmpty else { throw Failure.notConnected }
        // No access token yet, so the proof carries no `ath`: this IS the
        // request that asks for one.
        let proof = try DeviceKey.proof(
            signer: signer, method: "POST", url: tokenURL.absoluteString,
            accessToken: nil, now: now())

        let (status, body) = try await exchange(proof, token)
        try Task.checkCancellation()

        switch status {
        case 200:
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let access = json["access_token"] as? String, !access.isEmpty,
                  let expires = json["expires_in"] as? Int
            else { throw Failure.temporarilyUnavailable }
            grant = Grant(token: access,
                          expiresAt: now().addingTimeInterval(TimeInterval(expires)))
            return access
        case 401:
            // The device token itself is no good: revoked, or this Mac was
            // disconnected. That is the one case that sends someone back to a
            // browser, and it is deliberately narrow.
            throw Failure.connectionRejected
        case 403:
            let code = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String
            throw code == "rebinding_required" ? Failure.rebindingRequired : Failure.connectionRejected
        default:
            // Including 503. An outage is not a sign-out.
            throw Failure.temporarilyUnavailable
        }
    }
}
