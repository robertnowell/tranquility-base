import Foundation

/// Reading one page back out of the hub, as this Mac.
///
/// The hub is behind a sign-in, which is the point of it: `/d/<id>` answers
/// 401 to anyone without a session. A fresh agent started from a hub page is
/// handed that address and nothing else, so without this it opens the
/// conversation by reporting that it could not read the thing it was started
/// for. The Mac already holds the credential the mirror uses to WRITE, and
/// the hub already accepts it as a Bearer token on the read path, so nothing
/// new is minted here: this is the same token, pointed the other way.
///
/// The whole reason the logic is here and not in `tbase` is `resolve`. A
/// bearer token must go to exactly one host, and the argument arrives from a
/// URL a web page put in front of the app. Sending the hub's credential to
/// `https://evil.example/d/x` because someone linked it is the failure this
/// exists to make impossible, and it is a pure function so it can be tested
/// without a network.
public enum HubRead {

    public enum Failure: Error, Equatable {
        /// Not an address this token may be sent to.
        case notTheHub(String)
        /// No hub configured, or no token: this Mac is not connected.
        case notConnected
        case http(Int)
        case transport(String)
    }

    static let uuid = try! NSRegularExpression(
        pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
        options: .caseInsensitive)

    /// The address to fetch, or nil if the token must not be sent there.
    ///
    /// Accepts three shapes, because all three are things a person or an agent
    /// actually has in hand: a full hub URL (what the Discuss button carries),
    /// a bare document id (what a log line carries), and a session id with a
    /// slug (what a page footer carries). Everything else, including a
    /// different host, plain http, or a URL carrying credentials, is refused
    /// by returning nothing.
    public static func resolve(_ arg: String, base: URL?) -> URL? {
        guard let base, let baseHost = base.host?.lowercased(), !baseHost.isEmpty else { return nil }
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2048 else { return nil }

        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if Self.uuid.firstMatch(in: trimmed, range: range) != nil {
            return base.appendingPathComponent("d").appendingPathComponent(trimmed)
        }

        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { return nil }
        // Scheme and host both, and the host EXACTLY: a suffix check would
        // hand the token to `hq.tranquilitybase.dev.evil.example`.
        guard url.scheme?.lowercased() == "https", host == baseHost,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// How many hops a read will follow. `/open?session=&slug=` is one
    /// redirect to `/d/<id>`; anything past a couple is a loop.
    static let maxHops = 5

    /// Fetch it as this Mac. `send` is injectable so a test never opens a socket.
    ///
    /// Redirects are followed HERE rather than by URLSession, for two reasons
    /// and one of them was measured. URLSession strips `Authorization` when it
    /// follows a redirect, so `/open?session=&slug=` — the address every page
    /// footer in the archive carries — answered 401 while `/d/<id>` answered
    /// 200. And following it ourselves means `resolve` runs again on every
    /// hop, so a redirect that leaves the hub cannot carry the token with it.
    public static func fetch(
        _ arg: String,
        base: URL? = HubApp.baseURL,
        token: String? = Secrets.read(.hubToken),
        send: (URLRequest) async throws -> (Data, URLResponse) = { try await NoRedirect.send($0) }
    ) async -> Result<String, Failure> {
        guard let base, let token, !token.isEmpty else { return .failure(.notConnected) }
        guard var url = resolve(arg, base: base) else { return .failure(.notTheHub(arg)) }
        for _ in 0..<maxHops {
            var req = URLRequest(url: url)
            req.timeoutInterval = 30
            req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
            let data: Data, response: URLResponse
            do { (data, response) = try await send(req) }
            catch { return .failure(.transport(error.localizedDescription)) }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if (300..<400).contains(status) {
                guard let location = http?.value(forHTTPHeaderField: "location"),
                      let next = URL(string: location, relativeTo: url)?.absoluteURL,
                      let checked = resolve(next.absoluteString, base: base)
                else { return .failure(.notTheHub(http?.value(forHTTPHeaderField: "location") ?? "")) }
                url = checked
                continue
            }
            guard (200..<300).contains(status) else { return .failure(.http(status)) }
            return .success(String(decoding: data, as: UTF8.self))
        }
        return .failure(.http(310))
    }

    /// A session that hands every redirect back rather than following it.
    /// Its whole job is to stop URLSession dropping the credential mid-chain.
    public final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        public static let shared = NoRedirect()
        public static func send(_ req: URLRequest) async throws -> (Data, URLResponse) {
            try await URLSession.shared.data(for: req, delegate: shared)
        }
        public func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// The page with its markup taken off, for a caller that wants the prose.
    ///
    /// Not the default. A report's links ARE its content -- the sibling it
    /// points at, the evidence file it cites -- and an agent handed only the
    /// prose cannot follow any of them.
    public static func text(_ html: String) -> String {
        var s = html
        for pattern in ["<(style|script|head)[^>]*>[\\s\\S]*?</\\1>", "<!--[\\s\\S]*?-->"] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "</(p|div|li|tr|h[1-6]|section|header|footer)>",
                                   with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                               ("&#39;", "'"), ("&rsquo;", "\u{2019}"), ("&ldquo;", "\u{201C}"),
                               ("&rdquo;", "\u{201D}"), ("&middot;", "\u{00B7}"), ("&nbsp;", " "),
                               ("&larr;", "\u{2190}"), ("&rarr;", "\u{2192}"),
                               ("&hellip;", "\u{2026}"), ("&mdash;", "\u{2014}"),
                               ("&ndash;", "\u{2013}")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
