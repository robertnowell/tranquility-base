import Foundation

/// One ACP agent, as an `AgentProvider`.
///
/// **It owns a child process and it is still not a harness.** The distinction
/// is the seam's whole point: a `HarnessAdapter` owns a TERMINAL and reads a
/// screen, so it types keystrokes and scrapes what comes back; this owns a
/// PIPE and reads a protocol, so it asks questions and gets answers. ACP ships
/// stdio only, which makes process ownership this provider's transport rather
/// than a second control plane. Ruled 14 Sep, and the reason OpenCode was never
/// allowed to become a keystroke-scraped terminal.
///
/// One instance per agent in the catalog. `id` is the catalog entry's id, so a
/// row's harness column names the vendor.
public actor ACPProvider: AgentProvider {

    public nonisolated let id: String
    private let client: ACPClient
    private let cwd: String
    private let start: @Sendable () throws -> Void

    /// What the agent declared at handshake, translated. `.none` until the
    /// handshake lands: a provider that claimed abilities before asking would
    /// be doing exactly what the catalog is written to avoid.
    private var declared: Capabilities?
    public nonisolated var can: Capabilities { capabilitiesBox.value }
    private nonisolated let capabilitiesBox = Box(Capabilities())

    /// Sessions this provider knows about, by the agent's own id.
    private var sessions: [String: AgentSession] = [:]
    /// Text accumulated per session from `agent_message_chunk`, which is the
    /// only transcript ACP gives without `session/load`.
    private var saidSoFar: [String: String] = [:]
    /// Permission prompts the agent is waiting on, keyed by our request id so
    /// `respond` can answer the right JSON-RPC call.
    private var asking: [AgentSession.ID: (rpcID: Int, request: PendingRequest)] = [:]

    private var eventContinuation: AsyncStream<AgentEvent>.Continuation?
    private var pump: Task<Void, Never>?

    public init(id: String, client: ACPClient, cwd: String,
                start: @escaping @Sendable () throws -> Void = {}) {
        self.id = id
        self.client = client
        self.cwd = cwd
        self.start = start
        // The stream is opened HERE, not in a separate async call, so a
        // synchronous registry can build the provider at launch and hand
        // `changes()` to the poller before any process exists. The continuation
        // is captured without touching `self`, which is what lets an actor do
        // this in its initialiser. `openEventStream()` remains as a no-op for
        // the callers that predate this.
        var continuation: AsyncStream<AgentEvent>.Continuation!
        let stream = AsyncStream<AgentEvent> { continuation = $0 }
        self.eventContinuation = continuation
        self.streamBox.value = stream
    }

    /// Whether `connect()` has succeeded. A registered provider sits here
    /// without a process until something is started on it: that is what makes
    /// listing every installed agent at launch cost nothing.
    private var connected = false

    /// Spawn on first use. `start`, `send` and `respond` all route through
    /// here, so a provider built by the registry and never touched never runs
    /// a binary, and one that is used runs it exactly once.
    private func connectIfNeeded() async throws {
        guard !connected else { return }
        try await connect()
        connected = true
    }

    /// Spawn, handshake, and begin translating. Separate from `init` because a
    /// failure here is a real answer the caller has to see, and an initialiser
    /// that throws on a missing binary would make the catalog un-listable.
    public func connect() async throws {
        try start()
        await client.start()
        let shook = try await client.initialize()
        connected = true
        declared = shook.capabilities
        handshakeCapabilities = shook.agentCapabilities
        capabilitiesBox.value = shook.capabilities
        pump = Task { [weak self] in
            guard let self else { return }
            for await message in await self.client.inbound {
                await self.translate(message)
            }
        }
    }

    // MARK: - Push, not poll

    /// **ACP pushes**, so `changes()` returns a stream and the poller leaves
    /// this provider alone between events. `AgentProvider` declares exactly
    /// that by letting this return nil for a provider that cannot stream; a
    /// capability that has to be branched on to function cannot go stale.
    public nonisolated func changes() -> AsyncStream<AgentEvent>? {
        streamBox.value
    }
    private nonisolated let streamBox = Box<AsyncStream<AgentEvent>?>(nil)

    /// Build the stream up front so `changes()` can stay non-isolated.
    public func openEventStream() {
        guard streamBox.value == nil else { return }
        streamBox.value = AsyncStream { continuation in
            self.eventContinuation = continuation
        }
    }

    /// One inbound message becomes zero or more events.
    private func translate(_ message: ACPWire.Message) {
        guard let method = message.method else { return }
        switch method {
        case "session/update":
            guard let update = message.params(ACPWire.SessionUpdate.self),
                  let raw = update.sessionId else { return }
            note(raw: raw, update: update)

        case "session/request_permission":
            guard let id = message.id,
                  let ask = message.params(ACPPermission.self),
                  let raw = ask.sessionId else { return }
            let session = seen(raw: raw, state: .inputRequired)
            let request = ask.pending(session: session.id)
            asking[session.id] = (id, request)
            emit(session.id, .asks(request))

        default:
            return
        }
    }

    private func note(raw: String, update: ACPWire.SessionUpdate) {
        let kind = update.update?.sessionUpdate
        // Anything at all from the agent means it is working. An update this
        // app cannot name is still evidence, which is why the default is
        // `.working` rather than a silent drop.
        let session = seen(raw: raw, state: .working)
        guard kind == ACPWire.UpdateKind.agentMessageChunk.rawValue,
              let text = update.update?.content?.text, !text.isEmpty
        else {
            emit(session.id, .changed(session))
            return
        }
        saidSoFar[raw, default: ""] += text
        emit(session.id, .said(Turn(id: "\(raw)-\(saidSoFar[raw]?.count ?? 0)",
                                    at: Date(), role: .agent, text: text)))
    }

    @discardableResult
    private func seen(raw: String, state: AgentSessionState) -> AgentSession {
        if var known = sessions[raw] {
            let changed = known.state != state
            known.state = state
            known.updatedAt = Date()
            sessions[raw] = known
            if changed { emit(known.id, .changed(known)) }
            return known
        }
        let fresh = AgentSession.of(raw, provider: id, state: state)
        sessions[raw] = fresh
        emit(fresh.id, .appeared(fresh))
        return fresh
    }

    private func emit(_ session: AgentSession.ID, _ kind: AgentEvent.Kind) {
        eventContinuation?.yield(AgentEvent(provider: id, session: session, kind: kind))
    }

    // MARK: - AgentProvider

    /// **The catch-up.** A push provider only ever hears what happens next, so
    /// without a list every session that existed before this client attached
    /// would be invisible for ever. That defect shipped once already, against
    /// local OpenCode over HTTP, and the conformance suite caught it here
    /// before it could ship twice.
    ///
    /// Gated on the agent's own declaration, then merged rather than replaced:
    /// a session this provider has been streaming knows more about its state
    /// than a list does, and a list that overwrote `.working` with `.completed`
    /// would put a green lamp on an agent mid-turn.
    public func mine() async throws -> [AgentSession] {
        guard supportsList else { return Array(sessions.values) }
        for item in (try? await client.listSessions()) ?? [] {
            if sessions[item.sessionId] == nil {
                let session = item.agentSession(provider: id)
                sessions[item.sessionId] = session
                emit(session.id, .appeared(session))
            } else if let title = item.title, !title.isEmpty {
                sessions[item.sessionId]?.title = title
            }
        }
        return Array(sessions.values)
    }

    private var supportsList: Bool {
        handshakeCapabilities?.sessionCapabilities?.list == true
    }
    private var handshakeCapabilities: ACPWire.Initialized.AgentCapabilities?

    public func refine(_ id: AgentSession.ID) async throws -> AgentSession {
        guard let session = sessions.values.first(where: { $0.id == id }) else {
            throw ACPClient.ClientError.notInitialized
        }
        return session
    }

    public func request(_ id: AgentSession.ID) async throws -> PendingRequest? {
        asking[id]?.request
    }

    public func transcript(_ id: AgentSession.ID) async throws -> [Turn] {
        guard let raw = providerID(of: id), let text = saidSoFar[raw], !text.isEmpty
        else { return [] }
        return [Turn(id: raw, at: Date(), role: .agent, text: text)]
    }

    public func send(_ text: String, to id: AgentSession.ID) async throws -> SendOutcome {
        guard let raw = providerID(of: id) else { return .failed(reason: "no such session") }
        let result = try await client.prompt(text, session: raw)
        _ = seen(raw: raw, state: result.state)
        return .accepted
    }

    /// Answer the permission prompt with the option the user picked.
    ///
    /// ACP wants the OPTION ID back, not its text, so a response carrying only
    /// what the user said would be rejected by the agent and the row would hold
    /// its lamp for ever. The pending request already carries the ids.
    public func respond(to request: PendingRequest,
                        with response: Response) async throws -> SendOutcome {
        guard let waiting = asking[request.session], waiting.request.id == request.id else {
            return .failed(reason: "that request is no longer open")
        }
        guard let chosen = response.answers.first?.first else {
            return .failed(reason: "nothing chosen")
        }
        try await client.respond(to: waiting.rpcID,
                                 result: ["outcome": ["outcome": "selected",
                                                      "optionId": chosen]])
        asking[request.session] = nil
        emit(request.session, .answered(requestId: request.id))
        return .accepted
    }

    public func start(_ brief: Brief) async throws -> AgentSession.ID {
        try await connectIfNeeded()
        let raw = try await client.newSession(cwd: cwd)
        let session = seen(raw: raw, state: .submitted)
        if !brief.prompt.isEmpty { _ = try await send(brief.prompt, to: session.id) }
        return session.id
    }

    public func cancel(_ id: AgentSession.ID) async throws -> SendOutcome {
        guard let raw = providerID(of: id) else { return .failed(reason: "no such session") }
        try await client.cancel(session: raw)
        _ = seen(raw: raw, state: .canceled)
        return .accepted
    }

    /// A local agent has no page to open. `SessionRow.Door` already knows how
    /// to mean "nowhere", which is better than inventing a URL that 404s.
    public nonisolated func url(for id: AgentSession.ID) -> URL? { nil }

    private func providerID(of id: AgentSession.ID) -> String? {
        sessions.first(where: { $0.value.id == id })?.key
    }
}

/// `session/request_permission`, which is the honest amber signal this app
/// could not see before ACP. Read off the protocol rather than guessed, and
/// deliberately tolerant: an option with no id is dropped rather than sent
/// back as an empty string the agent would reject.
struct ACPPermission: Decodable, Sendable {
    var sessionId: String?
    var toolCall: ToolCall?
    var options: [Option]?

    struct ToolCall: Decodable, Sendable {
        var title: String?
        var rawInput: RawInput?
        struct RawInput: Decodable, Sendable { var command: String? }
    }
    struct Option: Decodable, Sendable {
        var optionId: String?
        var name: String?
        var kind: String?
    }

    func pending(session: AgentSession.ID) -> PendingRequest {
        let asked = toolCall?.title
            ?? toolCall?.rawInput?.command
            ?? "The agent is asking permission"
        let choices = (options ?? []).compactMap { option -> PendingRequest.Option? in
            guard let id = option.optionId else { return nil }
            return PendingRequest.Option(id: id, label: option.name ?? id,
                                         kind: .init(acp: option.kind))
        }
        return PendingRequest(
            id: "\(session)-permission",
            session: session,
            questions: [PendingRequest.Question(asked: asked, options: choices)])
    }
}

private extension PendingRequest.Option.Kind {
    /// ACP's own permission vocabulary, which `PendingRequest.Option.Kind` was
    /// built from in the first place (#367).
    init(acp raw: String?) {
        switch raw {
        case "allow_once": self = .allowOnce
        case "allow_always": self = .allowAlways
        case "reject_once": self = .rejectOnce
        case "reject_always": self = .rejectAlways
        default: self = .other
        }
    }
}

/// A one-value box so an actor can expose something to a non-isolated getter.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    init(_ value: T) { stored = value }
}
