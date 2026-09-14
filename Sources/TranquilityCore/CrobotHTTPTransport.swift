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

    private func request(_ method: String, _ path: String, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer " + key, forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        // Short: this runs on a 20 second beat and a poll that hangs has
        // already failed at its job even if it eventually answers.
        request.timeoutInterval = 15
        return request
    }

    private func call<T: Decodable>(_ method: String, _ path: String,
                                    body: Data? = nil, as: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request(method, path, body: body))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw Gateway.status(status, String(String(data: data, encoding: .utf8)?.prefix(200)
                ?? ""))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    public func tasks(limit: Int) async throws -> [CrobotTask] {
        struct Envelope: Decodable { var tasks: [CrobotTask]? }
        return try await call("GET", "api/v1/tasks?limit=\(limit)", as: Envelope.self).tasks ?? []
    }

    public func task(_ id: String) async throws -> CrobotTask {
        try await call("GET", "api/v1/tasks/\(esc(id))", as: CrobotTask.self)
    }

    public func prompt(_ id: String, text: String) async throws -> SendOutcome {
        let body = try JSONSerialization.data(withJSONObject: ["prompt": text])
        do {
            struct Reply: Decodable { var answered: Bool? }
            _ = try await call("POST", "api/v1/tasks/\(esc(id))/prompt", body: body,
                               as: Reply.self)
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

    public enum Gateway: Error, Equatable {
        case status(Int, String)
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
