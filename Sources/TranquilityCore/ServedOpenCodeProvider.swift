import Foundation

/// OpenCode as a first-party agent: this app runs `opencode serve` in the
/// workspace, drives it over HTTP, and hands the terminal the same server.
///
/// **The one route for a Mac that has OpenCode installed** (revised 15 Sep
/// 9:11 PM; it was the ACP pipe from 14 Sep). The pipe could start and drive
/// an agent but could not share it: a permission asked over the pipe lived in
/// that child, and the terminal opened on the session never saw it. A served
/// session is one thing seen from two places, and Go to Agent is a terminal
/// attached to it (`OpenCodeServer.attachCommand`), where a question asked by
/// this app's prompt is answered with Enter and the answer comes back on the
/// event stream.
///
/// The lessons of the pipe route are kept: a turn's words are said ONCE, when
/// it ends, from the message the server stored; configuration and title
/// updates are not work; a pending permission holds its state under tool
/// updates; sessions nobody ever spoke to are not adopted; a session ended
/// here stays ended across launches (`ProviderLedger`); a fresh agent is
/// your turn.
public actor ServedOpenCodeProvider: AgentProvider {

    public nonisolated let id = "opencode"
    private let server: OpenCodeServer
    private let client: OpenCodeClient
    private let transport: HTTPTransport
    private let ledger: ProviderLedger?
    public nonisolated var directory: String { server.directory }
    public nonisolated var baseURL: URL { server.baseURL }

    private var sessions: [String: AgentSession] = [:]
    private var asking: [AgentSession.ID: PendingRequest] = [:]
    private var lastSaid: [String: String] = [:]
    /// Ended here. The server keeps emitting for a session it still has
    /// (an abort settles as idle), and a first sighting would bring the row
    /// straight back.
    private var forgotten: Set<String> = []
    /// Subagents, which are their parent's business and never rows. Robert,
    /// 16 Sep: "subagents are appearing in the grid that were kicked off by
    /// the opencode I asked for research, which shouldn't happen, and
    /// naturally doesn't for claude and codex." Read from the list at seed
    /// and on first sight of an unknown session.
    private var children: Set<String> = []
    /// Host each session's TUI in a pane of ours (`OpenCodePane`). Off for
    /// tests and drills, which would otherwise leave attach processes behind.
    private let hostsPanes: Bool
    private var connected = false
    private var connecting: Task<Void, Error>?
    private var pump: Task<Void, Never>?
    private var eventContinuation: AsyncStream<AgentEvent>.Continuation?
    private nonisolated let streamBox = Box<AsyncStream<AgentEvent>?>(nil)

    public init(binary: String, directory: String, ledger: ProviderLedger? = nil,
                port: Int? = nil, pidFile: URL? = nil, hostsPanes: Bool = false,
                trace: (@Sendable (String) -> Void)? = nil) {
        self.server = OpenCodeServer(binary: binary, directory: directory, port: port, pidFile: pidFile)
        self.hostsPanes = hostsPanes
        self.transport = HTTPTransport(base: server.baseURL, password: nil, trace: trace)
        self.client = OpenCodeClient(transport: transport, provider: "opencode")
        self.ledger = ledger
        var continuation: AsyncStream<AgentEvent>.Continuation!
        let stream = AsyncStream<AgentEvent> { continuation = $0 }
        self.eventContinuation = continuation
        self.streamBox.value = stream
    }

    public nonisolated var can: Capabilities {
        Capabilities(canStart: true, canSend: true, canAnswer: true, canCancel: true,
                     sendWhileWorking: true, listIsCallerScoped: true, carriesPullRequest: false)
    }

    public nonisolated func changes() -> AsyncStream<AgentEvent>? { streamBox.value }

    // MARK: - The server

    private func connectIfNeeded() async throws {
        guard !connected else { return }
        if let connecting { return try await connecting.value }
        let task = Task { try await self.connect() }
        connecting = task
        defer { connecting = nil }
        try await task.value
    }

    private func connect() async throws {
        try await server.start()
        connected = true
        if hostsPanes { OpenCodePane.sweepStale(keeping: server.baseURL.port ?? 0) }
        guard let raw = transport.events() else { return }
        pump = Task { [weak self] in
            for await chunk in raw {
                guard let self else { return }
                await self.translate(chunk)
            }
        }
    }

    // MARK: - Events

    private struct Envelope: Decodable {
        var type: String?
        var properties: Properties?
        struct Properties: Decodable {
            var sessionID: String?
            var info: Info?
            var status: Status?
            struct Info: Decodable { var id: String?; var sessionID: String? }
            struct Status: Decodable { var type: String? }
        }
    }

    private func translate(_ data: Data) async {
        guard let e = try? JSONDecoder().decode(Envelope.self, from: data), let type = e.type else { return }
        let raw = e.properties?.sessionID ?? e.properties?.info?.sessionID ?? e.properties?.info?.id
        guard let raw, !raw.isEmpty, !forgotten.contains(raw) else { return }
        if sessions[raw] == nil, !children.contains(raw) {
            // First sight of a session this instance did not start: a
            // subagent's events must not conjure a row for it.
            if let known = try? await client.childSessionIDs() { children = known }
            if children.contains(raw) { return }
        }
        if children.contains(raw) { return }
        switch type {
        case "session.status":
            switch e.properties?.status?.type {
            case "busy": working(raw)
            case "idle": await finished(raw)
            default: break
            }
        case "session.idle":
            await finished(raw)
        case "message.part.updated", "message.part.delta", "message.updated":
            // Words, not state. `session.status` says busy and idle, and a
            // message update can land after idle (the stored message's
            // completion stamp), which read as work flipped a finished row
            // back to blue (live loop, 15 Sep).
            break
        case "permission.asked", "permission.v2.asked", "question.asked", "question.v2.asked":
            await asked(raw)
        case "permission.replied", "permission.updated", "question.replied", "question.updated", "question.rejected":
            await answered(raw)
        case "session.updated", "session.created":
            await retitled(raw)
        case "session.error":
            let session = seen(raw: raw, state: .failed)
            emit(session.id, .failed(reason: "opencode reported a session error"))
        default:
            break
        }
    }

    /// Activity is work, unless the session is waiting on you.
    private func working(_ raw: String) {
        guard let known = sessions[raw], asking[known.id] == nil else { return }
        _ = seen(raw: raw, state: .working)
    }

    /// The turn ended: the ending, then the words, from what the server
    /// stored. EVERY agent message the turn produced, in order, keyed by
    /// its own id: the last one is what the announcer speaks, and the ones
    /// before it are what the hub page shows. With only the last message
    /// carried, a research session's hub had the app's own lines and none
    /// of the agent's (Robert, 16 Sep 2:15 PM: "still nothing in the hub").
    private func finished(_ raw: String) async {
        let session = seen(raw: raw, state: .completed)
        await sayNewTurns(raw, session: session)
        await retitled(raw)
    }

    /// The agent messages not yet said for this session, oldest first.
    private func sayNewTurns(_ raw: String, session: AgentSession) async {
        guard let turns = try? await client.transcript(raw) else { return }
        let agentTurns = turns.filter { $0.role == .agent }
        let fresh: [Turn]
        if let last = lastSaid[raw], let index = agentTurns.lastIndex(where: { $0.id == last }) {
            fresh = Array(agentTurns[(index + 1)...])
        } else {
            fresh = agentTurns
        }
        for turn in fresh {
            lastSaid[raw] = turn.id
            eventContinuation?.yield(AgentEvent(provider: id, session: session.id, at: turn.at, kind: .said(turn)))
        }
    }

    private func asked(_ raw: String) async {
        let session = seen(raw: raw, state: .inputRequired)
        guard let request = try? await client.pendingRequest(raw) else { return }
        asking[session.id] = request
        emit(session.id, .asks(request))
    }

    private func answered(_ raw: String) async {
        guard let known = sessions[raw] else { return }
        if let still = try? await client.pendingRequest(raw) {
            asking[known.id] = still
            return
        }
        if let request = asking.removeValue(forKey: known.id) {
            emit(known.id, .answered(requestId: request.id))
        }
        _ = seen(raw: raw, state: .working)
    }

    private func retitled(_ raw: String) async {
        guard var known = sessions[raw],
              let fresh = try? await client.session(raw),
              let title = OpenCodeTitles.name(fresh.title), title != known.title else { return }
        known.title = title
        sessions[raw] = known
        emit(known.id, .changed(known))
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
        var fresh = AgentSession.of(raw, provider: id, state: state)
        decorate(&fresh, raw: raw)
        sessions[raw] = fresh
        emit(fresh.id, .appeared(fresh))
        return fresh
    }

    private func decorate(_ session: inout AgentSession, raw: String) {
        session.repository = URL(fileURLWithPath: server.directory).lastPathComponent
        session.directory = server.directory
        session.shell = AgentSession.ShellDoor(command: server.attachCommand(session: raw),
                                               directory: server.directory)
        // A pane THIS server's TUI is already in (a reconnect on the same
        // port) is the door; one from another launch is blind and is not.
        // Here, on every first sighting, not only the listed kind: a session
        // first seen through an SSE ask got the plain door and Go to Agent
        // opened a blind window beside a pane that had the question (driven
        // 17 Sep 9:33 AM on Dev).
        if hostsPanes, let port = server.baseURL.port, OpenCodePane.isLive(raw: raw, port: port) {
            session.pane = OpenCodePane.name(for: raw, port: port)
        }
    }

    /// The session's TUI, attached in a pane of ours BEFORE the turn that
    /// may ask; see `OpenCodePane`. Called on the way into `start` and
    /// `send`, and a no-op once the pane is live. Waits, bounded, for the
    /// TUI to draw, since a TUI attached after the ask never shows it.
    private func hostPane(_ raw: String) async {
        guard hostsPanes, var known = sessions[raw] else { return }
        let port = server.baseURL.port ?? 0
        if known.pane == nil || !OpenCodePane.isLive(raw: raw, port: port) {
            known.pane = OpenCodePane.host(raw: raw, port: port, command: server.attachCommand(session: raw),
                                           directory: server.directory)
            sessions[raw] = known
            emit(known.id, .changed(known))
        }
        guard known.pane != nil else { return }
        for _ in 0..<30 where !OpenCodePane.hasDrawn(raw: raw, port: port) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func emit(_ session: AgentSession.ID, _ kind: AgentEvent.Kind) {
        eventContinuation?.yield(AgentEvent(provider: id, session: session, kind: kind))
    }

    // MARK: - AgentProvider

    public func mine() async throws -> [AgentSession] {
        if !connected {
            guard ledger?.used(id) == true else { return [] }
            try await connectIfNeeded()
        }
        children = (try? await client.childSessionIDs()) ?? children
        for listed in try await client.sessions() {
            let raw = listed.providerID
            if sessions[raw] == nil {
                guard OpenCodeTitles.name(listed.title) != nil,
                      !children.contains(raw),
                      ledger?.forgotten(raw, provider: id) != true else { continue }
                var session = listed
                decorate(&session, raw: raw)
                sessions[raw] = session
                emit(session.id, .appeared(session))
                // Adopted WITH its turns, so the row is the same kind of row
                // a local one is (a turn in the store to read on a tap) and
                // the hub has the conversation. Keyed by each turn's own id,
                // so the store keeps one copy across launches; the heard
                // cursor persists, so a turn heard once stays heard.
                await sayNewTurns(raw, session: session)
            } else if let title = OpenCodeTitles.name(listed.title), sessions[raw]?.title != title {
                sessions[raw]?.title = title
                if let s = sessions[raw] { emit(s.id, .changed(s)) }
            }
        }
        return Array(sessions.values)
    }

    public func refine(_ id: AgentSession.ID) async throws -> AgentSession {
        guard let session = sessions.values.first(where: { $0.id == id }) else {
            throw LocalOpenCodeProvider.ProviderError.noSuchSession(id)
        }
        return session
    }

    public func request(_ id: AgentSession.ID) async throws -> PendingRequest? { asking[id] }

    public func transcript(_ id: AgentSession.ID) async throws -> [Turn] {
        guard let raw = providerID(of: id) else { return [] }
        return try await client.transcript(raw)
    }

    public func send(_ text: String, to id: AgentSession.ID) async throws -> SendOutcome {
        guard let raw = providerID(of: id) else { return .failed(reason: "no such session") }
        try await connectIfNeeded()
        if sessions[raw]?.title.isEmpty == true, var titled = sessions[raw] {
            titled.title = ACPProvider.headline(text)
            sessions[raw] = titled
            emit(titled.id, .changed(titled))
        }
        _ = seen(raw: raw, state: .submitted)
        await hostPane(raw)
        return try await client.sendAsync(text, to: raw)
    }

    public func respond(to request: PendingRequest, with response: Response) async throws -> SendOutcome {
        guard let waiting = asking[request.session], waiting.id == request.id else {
            return .failed(reason: "that request is no longer open")
        }
        guard let words = response.answers.first?.first else { return .failed(reason: "nothing chosen") }
        guard let chosen = waiting.option(chosenBy: words) else {
            return .failed(reason: "\"\(words.prefix(40))\" does not choose one of: "
                + (waiting.questions.first?.options.map(\.label).joined(separator: ", ") ?? "no options"))
        }
        guard let raw = providerID(of: request.session) else { return .failed(reason: "no such session") }
        try await connectIfNeeded()
        let isPermission = waiting.questions.first?.options.contains { $0.kind != .other } == true
        let outcome = try await client.respond(to: waiting, kind: isPermission ? .permission : .question,
                                               session: raw, with: Response(chosen.id))
        if case .accepted = outcome {
            asking[request.session] = nil
            emit(request.session, .answered(requestId: request.id))
            _ = seen(raw: raw, state: .working)
        }
        return outcome
    }

    public func start(_ brief: Brief) async throws -> AgentSession.ID {
        try await connectIfNeeded()
        ledger?.mark(id)
        let appID = try await client.start()
        guard let listed = try await client.sessions().first(where: { $0.id == appID }) else {
            throw LocalOpenCodeProvider.ProviderError.noSuchSession(appID)
        }
        let session = seen(raw: listed.providerID, state: .inputRequired)
        await hostPane(listed.providerID)
        if !brief.prompt.isEmpty { _ = try await send(brief.prompt, to: session.id) }
        return session.id
    }

    public func cancel(_ id: AgentSession.ID) async throws -> SendOutcome {
        guard let raw = providerID(of: id) else { return .failed(reason: "no such session") }
        try await client.abort(raw)
        _ = seen(raw: raw, state: .canceled)
        return .accepted
    }

    public func forget(_ id: AgentSession.ID) async {
        guard let raw = providerID(of: id) else { return }
        forgotten.insert(raw)
        if hostsPanes { OpenCodePane.kill(raw: raw, port: server.baseURL.port ?? 0) }
        if connected { _ = try? await client.abort(raw) }
        sessions[raw] = nil
        asking[id] = nil
        ledger?.forget(raw, provider: self.id)
    }

    public nonisolated func url(for id: AgentSession.ID) -> URL? { nil }

    private func providerID(of id: AgentSession.ID) -> String? {
        sessions.first(where: { $0.value.id == id })?.key
    }
}

/// OpenCode's placeholder title for an unprompted session is not a title.
/// One rule, shared by the two routes that list OpenCode's sessions.
public enum OpenCodeTitles {
    public static func name(_ title: String?) -> String? {
        ACPWire.SessionList.Item.name(title)
    }
}
