import Foundation

/// One OpenCode server, whoever is hosting it.
///
/// **crobot is OpenCode behind a reverse proxy, and not loosely.** The gateway
/// mounts `api.all("/tasks/:id/opencode/*")` as a proxy of the sandbox's own
/// OpenCode server (`gateway/src/routes.ts:1038`), and crobot's own web client
/// drives it with OpenCode's published SDK pinned at 1.18.29. So the expensive
/// half of a crobot provider and the whole of a local OpenCode provider are the
/// same API against different base URLs, and writing crobot as one monolith
/// would have buried that and made the second provider cost what the first did.
///
/// What is in here: sessions, messages, the event stream, questions and
/// permissions. What is deliberately NOT: tasks, repositories, pull requests,
/// sleeping, waking, org scope. All of that is crobot's lifecycle wrapper and
/// none of it exists for a local server. That split is the point.
///
/// Nothing above this file sees an OpenCode type. Everything decodes into the
/// #367 model, so a second host costs a base URL and a header rather than a
/// vocabulary.
public struct OpenCodeClient: Sendable {

    // MARK: - Transport

    /// One seam for the network, so a test never opens a socket. The same shape
    /// as `HubMirror.Transport`, for the same reason.
    ///
    /// It carries headers rather than a token because **the two hosts
    /// authenticate differently**, and that is a fact about them rather than a
    /// detail: a local server takes HTTP Basic (`opencode:<password>`, which is
    /// what the gateway itself sets when it proxies), while crobot takes the
    /// Jarvis bearer token plus `x-crobot-org`. A transport that assumed either
    /// would need a special case for the other within a week.
    public protocol Transport: Sendable {
        func send(method: String, path: String, body: Data?) async throws
            -> (status: Int, body: Data)
        /// The server's event stream, or nil for a host that cannot stream.
        func events() -> AsyncStream<Data>?
    }

    public let transport: any Transport
    /// `AgentProvider.id` of whoever owns this client, stamped onto every
    /// session and event so a row knows where it came from.
    public let provider: String

    public init(transport: any Transport, provider: String) {
        self.transport = transport
        self.provider = provider
    }

    public enum ClientError: Error, CustomStringConvertible, Equatable {
        /// The sandbox is asleep. **Normal, and not an error to log as one**:
        /// the gateway answers reads with 409 rather than waking a task, so an
        /// idle crobot task returns this on every poll.
        case asleep
        case status(Int, String)

        public var description: String {
            switch self {
            case .asleep: return "the sandbox is asleep"
            case .status(let code, let text):
                return text.isEmpty ? "opencode -> \(code)" : "opencode \(code): \(text)"
            }
        }
    }

    private func call(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        let (status, data) = try await transport.send(method: method, path: path, body: body)
        if status == 409 { throw ClientError.asleep }
        guard (200...299).contains(status) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.status(status, String(text.prefix(200)))
        }
        return data
    }

    // MARK: - Sessions

    /// Every session this server holds.
    ///
    /// Caller-scoped by construction for a local server: it is your own
    /// process. For crobot the gateway has already scoped the proxy to one
    /// task, so this returns that task's sessions and nobody else's.
    /// The sessions that are somebody's subagent: OpenCode lists them beside
    /// their parents, with `parentID` set. A subagent is the parent's
    /// business, not a row (Claude Code's and Codex's never were).
    public func childSessionIDs() async throws -> Set<String> {
        let data = try await call("GET", "/session")
        return Set(decodeList(data, as: Wire.Session.self).filter { $0.parentID != nil }.map(\.id))
    }

    public func sessions() async throws -> [AgentSession] {
        let data = try await call("GET", "/session")
        let busy = await busySessions()
        return decodeList(data, as: Wire.Session.self)
            .map { $0.agentSession(provider: provider, busy: busy) }
    }

    /// The ids the server is working on right now. Empty when it is idle.
    ///
    /// Shaped from crobot's `busySessions`, which reads the same route against
    /// the same server: the payload is EITHER an array of `{sessionID, type}`
    /// OR an object keyed by session id, depending on the build, and anything
    /// whose `type` is not `idle` is busy. A live 1.18.30 returns `{}`.
    ///
    /// Failure is not fatal and is not `.unknown`: this route is an enrichment
    /// of a list that already succeeded, so losing it costs blue, never the
    /// row. The one thing it must not do is report everything busy.
    func busySessions() async -> Set<String> {
        guard let data = try? await call("GET", "/session/status") else { return [] }
        if let array = try? JSONDecoder().decode([Wire.Status].self, from: data) {
            return Set(array.filter { $0.type != "idle" }.compactMap { $0.sessionID ?? $0.id })
        }
        if let map = try? JSONDecoder().decode([String: Wire.Status?].self, from: data) {
            return Set(map.compactMap { key, value in
                (value.flatMap { $0 }?.type ?? "idle") != "idle" ? key : nil
            })
        }
        return []
    }

    public func start() async throws -> AgentSession.ID {
        let data = try await call("POST", "/session", body: Data("{}".utf8))
        guard let wire = try? JSONDecoder().decode(Wire.Session.self, from: data) else {
            throw ClientError.status(200, "session create returned no session")
        }
        return AgentSession.id(wire.id, provider: provider)
    }

    // MARK: - Transcript

    public func transcript(_ session: String) async throws -> [Turn] {
        let data = try await call("GET", "/session/\(esc(session))/message")
        return decodeList(data, as: Wire.Message.self).compactMap { $0.turn() }
    }

    public func send(_ text: String, to session: String) async throws -> SendOutcome {
        let payload: [String: Any] = ["parts": [["type": "text", "text": text]]]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return .failed(reason: "could not encode the message")
        }
        do {
            _ = try await call("POST", "/session/\(esc(session))/message", body: body)
            return .accepted
        } catch ClientError.asleep {
            // A write DOES wake a crobot sandbox (`ensureRunning`), so a 409 on
            // this path means it could not be woken, which is retryable.
            return .busy
        } catch {
            return .failed(reason: String(describing: error))
        }
    }

    // MARK: - The pending request

    /// What this session is blocked on, or nil while it is blocked on nothing.
    ///
    /// **Questions come from the UNSCOPED `/question` route and are filtered
    /// here.** The session-scoped v1 route exists and answers with
    /// `QuestionNotFoundError`, which is how a typed answer went nowhere in
    /// crobot (task ui-owxd968g5sbf, 11 Sep 2026). Their client carries that
    /// comment; this one inherits it rather than rediscovering it.
    ///
    /// **Permissions are unscoped too**, at `/permission`, and filtered here
    /// exactly like questions. The session-scoped `/api/session/{id}/permission`
    /// exists and answers `{"data":[]}` even while one is pending for that
    /// session; measured live on 14 Sep 2026 against 1.18.30, where an agent
    /// with `edit: ask` sat blocked for 240 s reading as `working` because
    /// this client asked the wrong route. Same for the reply: the scoped
    /// route answers PermissionNotFoundError, the unscoped one clears it.
    /// The prompt, accepted rather than finished: `POST .../prompt_async`
    /// answers 204 the moment the message is queued, where `/message` holds
    /// the connection for the whole turn. The turn's words arrive on the
    /// event stream, which is where a provider that owns the server reads
    /// them.
    public func sendAsync(_ text: String, to session: String) async throws -> SendOutcome {
        let payload: [String: Any] = ["parts": [["type": "text", "text": text]]]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return .failed(reason: "could not encode the message")
        }
        do {
            _ = try await call("POST", "/session/\(esc(session))/prompt_async", body: body)
            return .accepted
        } catch ClientError.asleep {
            return .busy
        } catch {
            return .failed(reason: String(describing: error))
        }
    }

    /// Stop the turn that is running, if one is.
    public func abort(_ session: String) async throws {
        _ = try await call("POST", "/session/\(esc(session))/abort")
    }

    /// One session, as the server has it now: the model's title lands here
    /// after the first turn.
    public func session(_ raw: String) async throws -> AgentSession? {
        try await sessions().first { $0.providerID == raw }
    }

    public func pendingRequest(_ session: String) async throws -> PendingRequest? {
        if let question = try await questions(session).first { return question }
        return try await permissions(session).first
    }

    func questions(_ session: String) async throws -> [PendingRequest] {
        let data = try await call("GET", "/question")
        return decodeList(data, as: Wire.Question.self)
            .filter { $0.sessionID == session }
            .compactMap { $0.pending(session: AgentSession.id(session, provider: provider)) }
    }

    func permissions(_ session: String) async throws -> [PendingRequest] {
        let data = try await call("GET", "/permission")
        return decodeList(data, as: Wire.Permission.self)
            .filter { $0.sessionID == session }
            .map { $0.pending(session: AgentSession.id(session, provider: provider)) }
    }

    /// Answer a request, by whichever route raised it.
    ///
    /// `kind` decides the route because the two are answered differently and a
    /// request does not say which it is on the wire. The caller holds the
    /// request it fetched, so it knows.
    public func respond(to request: PendingRequest, kind: RequestKind,
                        session: String, with response: Response) async throws -> SendOutcome {
        do {
            switch kind {
            case .question where response.isRejection:
                _ = try await call("POST", "/question/\(esc(request.id))/reject")
            case .question:
                let body = try JSONSerialization.data(
                    withJSONObject: ["answers": response.answers])
                _ = try await call("POST", "/question/\(esc(request.id))/reply", body: body)
            case .permission:
                let reply = permissionReply(response)
                let body = try JSONSerialization.data(withJSONObject: ["reply": reply])
                // Unscoped, like the read. `/api/session/{sid}/permission/{pid}/reply`
                // is 404 PermissionNotFoundError on a live server for a permission
                // that `/permission` lists; `/permission/{pid}/reply` returns true.
                _ = try await call("POST", "/permission/\(esc(request.id))/reply", body: body)
            }
            return .accepted
        } catch ClientError.asleep {
            return .busy
        } catch {
            return .failed(reason: String(describing: error))
        }
    }

    public enum RequestKind: Sendable, Equatable { case question, permission }

    /// OpenCode's three permission replies. Anything unrecognised rejects,
    /// which is the safe direction: a misread answer must never grant.
    func permissionReply(_ response: Response) -> String {
        guard let first = response.answers.first?.first else { return "reject" }
        switch first {
        case PendingRequest.Option.Kind.allowOnce.rawValue, "once": return "once"
        case PendingRequest.Option.Kind.allowAlways.rawValue, "always": return "always"
        default: return "reject"
        }
    }

    // MARK: - The stream

    /// The server's own event stream, decoded into `AgentEvent`, or nil when
    /// this host cannot stream. Returning nil IS the poll-or-push declaration
    /// the provider hands upward.
    public func events() -> AsyncStream<AgentEvent>? {
        guard let raw = transport.events() else { return nil }
        let provider = self.provider
        return AsyncStream { continuation in
            Task {
                for await chunk in raw {
                    guard let event = Wire.event(chunk, provider: provider) else { continue }
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    // MARK: -

    /// Percent-encode one path segment. A session id arrives from the server
    /// and a task id from a person, and neither is guaranteed path-safe.
    private func esc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(
            CharacterSet(charactersIn: "-._~"))) ?? s
    }

    /// OpenCode returns a bare array on some routes and `{ "data": [...] }` on
    /// others, and crobot's own client handles both on the question and
    /// permission routes. Accepting either here costs four lines and removes a
    /// whole class of empty-list bug.
    private func decodeList<T: Decodable>(_ data: Data, as: T.Type) -> [T] {
        let decoder = JSONDecoder()
        if let flat = try? decoder.decode([T].self, from: data) { return flat }
        return (try? decoder.decode(Envelope<T>.self, from: data))?.data ?? []
    }

    /// `{ "data": [...] }`, which some OpenCode routes return instead of a bare
    /// array. Declared here rather than inside the generic function, which
    /// Swift does not allow.
    private struct Envelope<U: Decodable>: Decodable { var data: [U]? }
}
