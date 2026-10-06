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
    /// Which OpenCode this is talking to.
    public let api: API

    /// **OpenCode 2 is a different API, not a prefix.** Everything moved under
    /// `/api`, every response is wrapped in `data`, questions became
    /// session-scoped "forms", permissions became session-scoped, the async
    /// prompt route is gone (the one prompt route is async now), abort is
    /// `interrupt`, and the session list spans every directory the server has
    /// ever seen. Found 6 Oct 2026, when New Agent on a Mac that had upgraded
    /// to 2.0.23 got 405 from the web UI now served at `/session`.
    ///
    /// crobot stays `.v1`: its sandbox pins OpenCode 1.x.
    public enum API: Sendable, Equatable {
        case v1
        /// `directory` scopes the session list to the workspace, which 1.x
        /// did by itself and 2.x does only when asked.
        case v2(directory: String?)
    }

    public init(transport: any Transport, provider: String, api: API = .v1) {
        self.transport = transport
        self.provider = provider
        self.api = api
    }

    private var isV2: Bool { if case .v2 = api { return true } else { return false } }

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
        Set(try await listed().filter { $0.parentID != nil }.map(\.id))
    }

    public func sessions() async throws -> [AgentSession] {
        let list = try await listed()
        let busy = await busySessions()
        return list.map { $0.agentSession(provider: provider, busy: busy) }
    }

    /// The server's sessions, raw. On 2.x the newest 200 in this workspace:
    /// unscoped, a long-lived 2.x server lists every session it has from
    /// every directory (109 on this Mac on 6 Oct), most of them not ours.
    private func listed() async throws -> [Wire.Session] {
        guard case .v2(let directory) = api else {
            return decodeList(try await call("GET", "/session"), as: Wire.Session.self)
        }
        var path = "/api/session?order=desc&limit=200"
        if let directory { path += "&directory=" + query(directory) }
        return decodeList(try await call("GET", path), as: Wire.Session.self)
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
        if isV2 {
            // 2.x: `{ "data": { "<id>": { "type": "running" } } }`, and a
            // session absent from it is idle.
            guard let data = try? await call("GET", "/api/session/active"),
                  let map = try? JSONDecoder().decode(Wire.V2.One<[String: Wire.Status]>.self, from: data)
            else { return [] }
            return Set((map.data ?? [:]).compactMap { key, value in value.type == "idle" ? nil : key })
        }
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
        let data = try await call("POST", isV2 ? "/api/session" : "/session", body: Data("{}".utf8))
        let decoded = isV2
            ? (try? JSONDecoder().decode(Wire.V2.One<Wire.Session>.self, from: data))?.data
            : try? JSONDecoder().decode(Wire.Session.self, from: data)
        guard let wire = decoded else {
            throw ClientError.status(200, "session create returned no session")
        }
        return AgentSession.id(wire.id, provider: provider)
    }

    // MARK: - Transcript

    public func transcript(_ session: String) async throws -> [Turn] {
        if isV2 { return try await transcriptV2(session) }
        let data = try await call("GET", "/session/\(esc(session))/message")
        return decodeList(data, as: Wire.Message.self).compactMap { $0.turn() }
    }

    /// 2.x pages the timeline and defaults to NEWEST first, so read it
    /// oldest first, page by page. Bounded, because a cursor that never
    /// ends must not hold a poll for ever.
    private func transcriptV2(_ session: String) async throws -> [Turn] {
        let limit = 200
        var turns: [Turn] = []
        var cursor: String?
        for _ in 0..<50 {
            var path = "/api/session/\(esc(session))/message?order=asc&limit=\(limit)"
            if let cursor { path += "&cursor=" + query(cursor) }
            let page = try JSONDecoder().decode(Wire.V2.Page<Wire.V2.Message>.self,
                                                from: try await call("GET", path))
            let items = page.data ?? []
            turns += items.compactMap { $0.turn() }
            guard items.count == limit, let next = page.cursor?.next else { break }
            cursor = next
        }
        return turns
    }

    public func send(_ text: String, to session: String) async throws -> SendOutcome {
        let payload: [String: Any] = ["parts": [["type": "text", "text": text]]]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return .failed(reason: "could not encode the message")
        }
        if isV2 { return await promptV2(text, to: session) }
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
        if isV2 { return await promptV2(text, to: session) }
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

    /// 2.x has one prompt route, and it is the async one: it answers the
    /// moment the input is admitted to the session's inbox, and the turn's
    /// words arrive on the event stream. The body is `{ text }`, not parts.
    private func promptV2(_ text: String, to session: String) async -> SendOutcome {
        guard let body = try? JSONSerialization.data(withJSONObject: ["text": text]) else {
            return .failed(reason: "could not encode the message")
        }
        do {
            _ = try await call("POST", "/api/session/\(esc(session))/prompt", body: body)
            return .accepted
        } catch ClientError.asleep {
            return .busy
        } catch {
            return .failed(reason: String(describing: error))
        }
    }

    /// Stop the turn that is running, if one is.
    public func abort(_ session: String) async throws {
        _ = try await call("POST", isV2 ? "/api/session/\(esc(session))/interrupt"
                                         : "/session/\(esc(session))/abort")
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
        if isV2 {
            // Session-scoped on 2.x, where the scoped route is the real one.
            let data = try await call("GET", "/api/session/\(esc(session))/form")
            return decodeList(data, as: Wire.V2.Form.self)
                .compactMap { $0.pending(session: AgentSession.id(session, provider: provider)) }
        }
        let data = try await call("GET", "/question")
        return decodeList(data, as: Wire.Question.self)
            .filter { $0.sessionID == session }
            .compactMap { $0.pending(session: AgentSession.id(session, provider: provider)) }
    }

    func permissions(_ session: String) async throws -> [PendingRequest] {
        if isV2 {
            // `{id, sessionID, action, resources}`, which `Wire.Permission`
            // already reads as its first-draft spelling.
            let data = try await call("GET", "/api/session/\(esc(session))/permission")
            return decodeList(data, as: Wire.Permission.self)
                .map { $0.pending(session: AgentSession.id(session, provider: provider)) }
        }
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
        if isV2 { return await respondV2(to: request, kind: kind, session: session, with: response) }
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

    /// 2.x: both answered on routes under the session. A form is answered
    /// by field key, which the request we hand upward does not carry, so the
    /// form is read back first; a rejected form is deleted, which is how the
    /// TUI's own dismiss cancels it (`form.cancelled`).
    private func respondV2(to request: PendingRequest, kind: RequestKind,
                           session: String, with response: Response) async -> SendOutcome {
        let base = "/api/session/\(esc(session))"
        do {
            switch kind {
            case .question where response.isRejection:
                _ = try await call("DELETE", "\(base)/form/\(esc(request.id))")
            case .question:
                let data = try await call("GET", "\(base)/form/\(esc(request.id))")
                guard let form = (try? JSONDecoder().decode(Wire.V2.One<Wire.V2.Form>.self, from: data))?.data
                else { return .failed(reason: "the question could not be read back") }
                let body = try JSONSerialization.data(
                    withJSONObject: ["answer": form.answer(response.answers)])
                _ = try await call("POST", "\(base)/form/\(esc(request.id))/reply", body: body)
            case .permission:
                let body = try JSONSerialization.data(
                    withJSONObject: ["decision": permissionReply(response)])
                _ = try await call("POST", "\(base)/permission/\(esc(request.id))/reply", body: body)
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

    /// Percent-encode one query value.
    private func query(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(
            CharacterSet(charactersIn: "-._~"))) ?? s
    }

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
