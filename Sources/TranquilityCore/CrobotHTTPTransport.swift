import Foundation

/// The crobot gateway over HTTPS, beside its protocol like
/// `HubMirror.URLSessionTransport` sits beside its own.
public struct CrobotHTTPTransport: CrobotTransport {
    public let base: URL
    /// A Jarvis API key (`jrv_…`). The gateway resolves it into a user by
    /// calling Jarvis `/api/auth/me` itself; no scope is consulted anywhere on
    /// this path, which is why the key needs none.
    public let key: String
    public var session: URLSession

    public init(base: URL, key: String, session: URLSession = .shared) {
        self.base = base; self.key = key; self.session = session
    }

    /// A path, and a QUERY THAT CANNOT GO THROUGH `appendingPathComponent`.
    ///
    /// That method percent-encodes everything it is given, `?` included, so
    /// `appendingPathComponent("api/v1/tasks?limit=200")` produces
    /// `/api/v1/tasks%3Flimit=200`. Measured against the live gateway,
    /// 14 Sep: that URL matches no route, falls through to the single page
    /// app, and returns **200 with HTML**, which then fails JSON decoding with
    /// "Unexpected character '<'". The provider read as permanently
    /// unreachable while the credential and the routes were both perfect.
    ///
    ///     /api/v1/tasks%3Flimit=200  -> 200  <!doctype html>...
    ///     /api/v1/tasks?limit=200    -> 200  {"tasks":[...
    ///
    /// Third time in one day that this gateway's SPA fallback has turned a
    /// wrong URL into a successful-looking response, so the query is built
    /// with `URLComponents` and never by string append.
    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        let joined = base.appendingPathComponent(path)
        guard !query.isEmpty,
              var parts = URLComponents(url: joined, resolvingAgainstBaseURL: false)
        else { return joined }
        parts.queryItems = query
        return parts.url ?? joined
    }

    /// A poll runs on a 20 second beat, so a read that hangs has already
    /// failed at its job even if it eventually answers.
    static let readTimeout: TimeInterval = 15

    /// **Waking a sandbox is not a read.** crobot releases a task's disk when
    /// it goes quiet, so the first write to a cold task attaches a volume and
    /// starts a pod before anything is delivered. Measured 14 Sep against a
    /// real idle task: 15 seconds was not close, and the send came back as
    /// `NSURLErrorTimedOut` while the gateway was still doing the work.
    ///
    /// The old code used one constant for every call, which is the actual
    /// defect: the number was right for the calls it was written for and
    /// wrong for the one nobody re-read it against.
    static let wakeTimeout: TimeInterval = 150

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [],
                         body: Data? = nil,
                         timeout: TimeInterval = CrobotHTTPTransport.readTimeout) -> URLRequest {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer " + key, forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        request.timeoutInterval = timeout
        return request
    }

    private func call<T: Decodable>(_ method: String, _ path: String,
                                    query: [URLQueryItem] = [],
                                    body: Data? = nil, as: T.Type,
                                    timeout: TimeInterval = CrobotHTTPTransport.readTimeout)
        async throws -> T {
        let (data, response) = try await session.data(
            for: request(method, path, query: query, body: body, timeout: timeout))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw Gateway.status(status, String(String(data: data, encoding: .utf8)?.prefix(200)
                ?? ""))
        }
        // A 200 CARRYING HTML IS NOT SUCCESS, and on this gateway it is the
        // normal shape of a wrong URL rather than an exotic failure: anything
        // it does not route falls through to the single page app. Saying so
        // here beats a JSON decoding error about an unexpected '<', which
        // describes the symptom and hides the cause.
        if let type = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "content-type"), type.contains("text/html") {
            throw Gateway.servedThePage(path)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Who this key belongs to, from the gateway's own identity route.
    ///
    /// Needed because `listIsCallerScoped` is false and the filter is
    /// client-side: without an identity there is nothing to filter ON, and the
    /// list is everybody's. Measured 14 Sep against the live gateway: **115
    /// tasks visible, 7 created by this user.** A registry that passed nil here
    /// would have put 108 other people's agents on the panel.
    public func identity() async throws -> String? {
        struct Me: Decodable { var email: String? }
        return try await call("GET", "api/v1/me", as: Me.self).email
    }

    public func tasks(limit: Int) async throws -> [CrobotTask] {
        struct Envelope: Decodable { var tasks: [CrobotTask]? }
        return try await call("GET", "api/v1/tasks",
                              query: [URLQueryItem(name: "limit", value: String(limit))],
                              as: Envelope.self).tasks ?? []
    }

    public func task(_ id: String) async throws -> CrobotTask {
        try await call("GET", "api/v1/tasks/\(esc(id))", as: CrobotTask.self)
    }

    public func prompt(_ id: String, text: String) async throws -> SendOutcome {
        let body = try JSONSerialization.data(withJSONObject: ["prompt": text])
        do {
            struct Reply: Decodable { var answered: Bool? }
            _ = try await call("POST", "api/v1/tasks/\(esc(id))/prompt", body: body,
                               as: Reply.self, timeout: Self.wakeTimeout)
            return .accepted
        } catch Gateway.status(409, _) {
            // The sandbox could not be woken, or a turn is running. Retryable,
            // and the user is told to wait rather than seeing silence.
            return .busy
        } catch {
            return .failed(reason: String(describing: error))
        }
    }

    public func create(repo: String, prompt: String, baseBranch: String?) async throws -> String {
        var payload: [String: Any] = ["repo": repo, "prompt": prompt]
        if let baseBranch { payload["baseBranch"] = baseBranch }
        let body = try JSONSerialization.data(withJSONObject: payload)
        struct Created: Decodable { var id: String? }
        guard let id = try await call("POST", "api/v1/tasks", body: body, as: Created.self).id
        else { throw Gateway.status(200, "task create returned no id") }
        return id
    }

    public func taskURL(_ id: String) -> URL? {
        base.appendingPathComponent("tasks").appendingPathComponent(id)
    }

    /// crobot's own New Task page — its repo picker, its prompt box. The place
    /// you go to begin a crobot task and answer its first question, which is
    /// where the tenth would be answered too. `?repo=` pre-selects when the
    /// caller already knows one; otherwise crobot picks the org's default.
    public func composeURL(repo: String?) -> URL? {
        var c = URLComponents(url: base.appendingPathComponent("new"),
                              resolvingAgainstBaseURL: false)
        if let repo, !repo.isEmpty { c?.queryItems = [URLQueryItem(name: "repo", value: repo)] }
        return c?.url
    }

    /// The proxy IS an OpenCode server, so the shared client talks to it with
    /// the same bearer token and a base URL one level deeper.
    public func opencode(_ id: String) -> any OpenCodeClient.Transport {
        Proxy(base: base.appendingPathComponent("api/v1/tasks/\(esc(id))/opencode"),
              key: key, session: session)
    }

    private func esc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(
            CharacterSet(charactersIn: "-._~"))) ?? s
    }

    public enum Gateway: Error, CustomStringConvertible, Equatable {
        case status(Int, String)
        /// The gateway answered with its web page, which means the URL matched
        /// no route. Named as itself so the log says "wrong URL" rather than
        /// "unexpected character '<'".
        case servedThePage(String)

        public var description: String {
            switch self {
            case .status(let code, let body):
                return body.isEmpty ? "crobot -> \(code)" : "crobot \(code): \(body)"
            case .servedThePage(let path):
                return "crobot served its web page for \(path): the URL matched no route"
            }
        }
    }

    /// The OpenCode half, through the gateway's proxy.
    struct Proxy: OpenCodeClient.Transport {
        let base: URL
        let key: String
        let session: URLSession

        func send(method: String, path: String, body: Data?) async throws
            -> (status: Int, body: Data) {
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.httpMethod = method
            request.httpBody = body
            request.setValue("Bearer " + key, forHTTPHeaderField: "authorization")
            if body != nil {
                request.setValue("application/json", forHTTPHeaderField: "content-type")
            }
            request.timeoutInterval = 15
            let (data, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }

        /// **nil, deliberately.** The gateway does have an SSE stream per task,
        /// but a stream per task is not a stream over the task LIST, and
        /// subscribing to one sandbox at a time would mean opening a
        /// connection per row and still polling to learn the rows exist.
        /// crobot is polled; see `CrobotProvider.changes`.
        func events() -> AsyncStream<Data>? { nil }
    }
}
