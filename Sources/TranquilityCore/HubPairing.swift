import CryptoKit
import Foundation

/// Connecting this Mac to the hub.
///
/// The Mac has no credential yet, so it cannot be told anything: the hub
/// cannot push it a token, and nothing in the browser is allowed to hand one
/// over. A URL scheme is open to the whole web, which is why the connect deep
/// link carries NOTHING (see `DeepLink.Action.connect`). A page that could put
/// a token and a host into a link could point this archive at a machine
/// somebody else owns.
///
/// So the Mac starts it, and it starts it with a secret of its own:
///
///  1. It invents 32 random bytes, keeps them in memory, and shows nobody.
///  2. It derives a six-character PHRASE from them and puts it on the Setup
///     row, next to the button you just pressed.
///  3. It opens `/connect?code=…&device=…` in the browser. The hub signs you
///     in with its own front door and shows the same phrase, computed from
///     the code it was handed, and asks you to compare the two.
///  4. You press Connect. The hub writes a ten-minute approval, not a token.
///  5. The Mac, which has been polling `/api/devices/claim` with the code all
///     along, collects the token exactly once, and only then does a live
///     credential exist anywhere.
///
/// The phrase is the load-bearing part, not decoration. Without it, anybody
/// could mail a signed-in person a `/connect` link carrying THEIR code and a
/// plausible machine name, and one click would pair the sender's computer to
/// the reader's account. RFC 8628 section 5.4 names this exact trade: once
/// the code travels in the link instead of being typed, the flow has to prove
/// the device is in the user's possession some other way, and showing the
/// same value in both places is the way it recommends.
///
/// Everything here is injectable (the transport, the wait, the clock), so the
/// whole flow is tested without a socket and without ten real minutes.
public final class HubPairing: @unchecked Sendable {

    // MARK: - The unauthenticated seam

    /// The hub's one route a stranger can reach, so it sends no credential.
    /// Same protocol as the mirror's transport, because it is the same shape
    /// of call and tests can fake either with one stub.
    public struct Anonymous: HubMirror.Transport {
        public let base: URL
        public var session: URLSession = .shared
        public init(base: URL, session: URLSession = .shared) {
            self.base = base; self.session = session
        }
        public func post(_ path: String, json: [String: Any]) async throws -> (status: Int, body: Data) {
            var req = URLRequest(url: base.appendingPathComponent(path))
            req.httpMethod = "POST"
            req.timeoutInterval = 20
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            let (data, response) = try await session.data(for: req)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
    }

    // MARK: - Shapes

    /// One attempt: the secret, what to show the person, where to send them.
    public struct Session: Equatable, Sendable {
        public let code: String
        public let phrase: String
        public let url: URL
    }

    public enum Outcome: Equatable, Sendable {
        /// The only way a token ever arrives.
        case connected(token: String, device: String)
        /// The hub says this code is spent: expired, or already collected.
        /// Both answer identically on purpose, so polling cannot be used to
        /// learn whether a code was ever real.
        case expired
        /// The hub refused the request itself (a malformed code, or a status
        /// this version does not understand).
        case refused(String)
        /// Nobody pressed Connect inside the window.
        case timedOut
        /// The network never came back.
        case failed(String)
    }

    // MARK: - Making one

    /// 32 bytes, base64url, exactly the shape the hub validates.
    public static func newCode() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// What both sides show. Derived from the code, never transmitted, so a
    /// page handed a different code shows a different phrase. Must agree
    /// character for character with the hub's `phraseFor` in lib/pairing.ts.
    public static func phrase(for code: String) -> String {
        let hex = SHA256.hash(data: Data(code.utf8))
            .map { String(format: "%02X", $0) }.joined().prefix(6)
        let s = String(hex)
        return String(s.prefix(3)) + "-" + String(s.suffix(3))
    }

    /// Where the person goes. The base is this app's own (hq.json, else the
    /// compiled-in default) and NEVER something a link supplied.
    public static func connectURL(base: URL, code: String, device: String) -> URL? {
        var parts = URLComponents(url: base.appendingPathComponent("connect"),
                                  resolvingAgainstBaseURL: false)
        parts?.queryItems = [URLQueryItem(name: "code", value: code),
                             URLQueryItem(name: "device", value: device)]
        return parts?.url
    }

    // MARK: - Live

    public let base: URL
    public let device: String
    let transport: HubMirror.Transport
    /// Injectable so a test spends no real seconds.
    var wait: @Sendable (TimeInterval) async -> Void = {
        try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000))
    }
    /// Injectable so a test can reach the deadline in three polls.
    var now: @Sendable () -> Date = { Date() }

    public init(base: URL, device: String = HubMirror.deviceName(),
                transport: HubMirror.Transport? = nil) {
        self.base = base
        self.device = device
        self.transport = transport ?? Anonymous(base: base)
    }

    /// The Mac's half: a fresh secret and the address to send the person to.
    public func begin() -> Session? {
        let code = Self.newCode()
        guard let url = Self.connectURL(base: base, code: code, device: device) else { return nil }
        return Session(code: code, phrase: Self.phrase(for: code), url: url)
    }

    /// Poll until somebody approves it, the window closes, or the hub says no.
    ///
    /// The interval backs off only when the hub asks it to (429 `slow_down`,
    /// plus five seconds per RFC 8628). A network failure does NOT end the
    /// attempt, because a wifi blip in minute two should not cost somebody the
    /// whole pairing. Ten consecutive failures does end it, so a hub that has
    /// gone away is reported rather than polled for ten minutes.
    public func collect(_ session: Session,
                        every: TimeInterval = 2,
                        within: TimeInterval = 600) async -> Outcome {
        let deadline = now().addingTimeInterval(within)
        var interval = every
        var consecutiveFailures = 0
        var lastError = ""
        while now() < deadline {
            do {
                let (status, body) = try await transport.post(
                    "api/devices/claim", json: ["code": session.code])
                consecutiveFailures = 0
                switch status {
                case 200:
                    guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                          let token = obj["token"] as? String, !token.isEmpty else {
                        return .refused("the hub sent a reply this version cannot read")
                    }
                    let name = (obj["device_name"] as? String) ?? device
                    return .connected(token: token, device: name)
                case 202:
                    break                       // nobody has pressed Connect yet
                case 429:
                    interval += 5               // slow_down, exactly as asked
                case 410:
                    return .expired
                case 400:
                    return .refused("the hub did not recognise this request")
                default:
                    return .refused("the hub answered \(status)")
                }
            } catch {
                consecutiveFailures += 1
                lastError = error.localizedDescription
                if consecutiveFailures >= 10 { return .failed(lastError) }
            }
            await wait(interval)
        }
        return .timedOut
    }

    // MARK: - Keeping it

    /// What a collected token means for this machine: it is the credential,
    /// and the hub it came from is the hub this Mac mirrors to.
    ///
    /// The address is written first. A token stored against an address that
    /// was never written is a Mac that looks connected and mirrors nowhere,
    /// which is the state this row exists to make impossible.
    public static func adopt(token: String, base: URL,
                             config: URL = HubApp.configPath) throws {
        try HubApp.setBaseURL(base, config: config)
        try Secrets.write(.hubToken, value: token)
    }
}
