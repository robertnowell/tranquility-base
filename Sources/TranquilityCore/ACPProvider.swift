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
    /// Where a started agent is remembered across relaunches. Nil for a
    /// provider built by hand (tests, probes), which then never spawns on a
    /// list and never survives one either.
    private let ledger: ProviderLedger?
    /// The vendor's own interface on this session, as a shell line, or nil.
    /// Go to Agent for a row with no pane and no page.
    private let open: @Sendable (String) -> String?

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
    /// What the agent has said in the turn now running, per session. Emitted
    /// ONCE, when the turn ends: a `.said` per chunk became a spool line per
    /// chunk, and a spool line is a turn the panel announces.
    private var turnText: [String: String] = [:]
    /// The turn in flight per session. `session/prompt` returns when the turn
    /// ENDS, and a `send` that waited on it would hold the dispatcher for as
    /// long as the agent takes; the HTTP providers return the moment the
    /// message is accepted, and this one does the same.
    private var turns: [String: Task<Void, Never>] = [:]
    /// Permission prompts the agent is waiting on, keyed by our request id so
    /// `respond` can answer the right JSON-RPC call.
    private var asking: [AgentSession.ID: (rpcID: Int, request: PendingRequest)] = [:]

    /// Sessions THIS PROCESS created or loaded. Anything else in `sessions`
    /// arrived by `session/list` and lives only in the agent's store until
    /// `session/load` brings it in; a prompt before that is refused with
    /// "session not found" (measured 15 Sep).
    private var loaded: Set<String> = []
    /// Sessions mid-`session/load`, whose replayed history must not be
    /// announced as new: a turn from yesterday spoken again at relaunch is the
    /// same defect as a duplicate spool line, with a voice.
    private var replaying: Set<String> = []

    private var eventContinuation: AsyncStream<AgentEvent>.Continuation?
    private var pump: Task<Void, Never>?

    public init(id: String, client: ACPClient, cwd: String,
                start: @escaping @Sendable () throws -> Void = {},
                ledger: ProviderLedger? = nil,
                open: @escaping @Sendable (String) -> String? = { _ in nil }) {
        self.id = id
        self.client = client
        self.cwd = cwd
        self.start = start
        self.ledger = ledger
        self.open = open
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
        // One spawn, however many callers arrive while it is in flight: the
        // poller's seed and a New Agent can land in the same moment, and two
        // children on one pipe is two agents answering as one.
        if let connecting { return try await connecting.value }
        let task = Task { try await connect() }
        connecting = task
        defer { connecting = nil }
        try await task.value
    }
    private var connecting: Task<Void, Error>?

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
                await self.note(translated: message.sequence)
            }
        }
    }

    /// How far the pump has translated the inbound stream.
    private var translated = 0
    private func note(translated sequence: Int) { translated = max(translated, sequence) }

    /// Wait until every notification delivered before `sequence` has been
    /// translated. A response resumes its caller directly while the
    /// notifications ahead of it are still queued for the pump; a turn's
    /// last chunk can arrive after the turn's result. Bounded: a pump that
    /// has died must not hold a turn for ever.
    private func caughtUp(to sequence: Int) async {
        var waited = 0
        while translated < sequence, waited < 200 {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 1
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
        // History replayed by `session/load` is not news.
        guard !replaying.contains(raw) else { return }
        let kind = update.update?.sessionUpdate
        // Configuration is not activity. OpenCode answers `session/new` with
        // `available_commands_update` (and a mode update), and reading those
        // as work put a blue lamp on an agent that had never been spoken to
        // (the live loop caught it, 15 Sep). Everything else from the agent,
        // named or not, is evidence of a turn: an update this app cannot name
        // is still work, which is why the default is `.working` rather than a
        // silent drop.
        if kind == ACPWire.UpdateKind.availableCommandsUpdate.rawValue
            || kind == ACPWire.UpdateKind.currentModeUpdate.rawValue {
            return
        }
        let session = seen(raw: raw, state: .working)
        guard kind == ACPWire.UpdateKind.agentMessageChunk.rawValue,
              let text = update.update?.content?.text, !text.isEmpty
        else {
            emit(session.id, .changed(session))
            return
        }
        saidSoFar[raw, default: ""] += text
        turnText[raw, default: ""] += text
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
        // The place, so an untitled row reads as the agent in its workspace
        // rather than as eight hex characters (#470).
        fresh.repository = URL(fileURLWithPath: cwd).lastPathComponent
        fresh.directory = cwd
        fresh.shell = door(raw)
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
    ///
    /// **And the relaunch.** The child dies with the app (measured 15 Sep: no
    /// `opencode acp` survived the relaunch), and a fresh provider holds
    /// nothing. The sessions are still in the agent's own store, so a provider
    /// this Mac has started an agent on before spawns here to ask for them;
    /// one it never has stays a free registry entry. That is the ledger's
    /// whole job, and it is why "no process until started" and "survives a
    /// relaunch" are not in tension (#470).
    public func mine() async throws -> [AgentSession] {
        if !connected {
            guard ledger?.used(id) == true else { return [] }
            try await connectIfNeeded()
        }
        try await adoptListed()
        return Array(sessions.values)
    }

    /// One `session/list`, merged. Called at seed and after every turn, the
    /// latter because the model's title arrives in the list and nowhere else.
    private func adoptListed() async throws {
        guard supportsList else { return }
        for item in (try? await client.listSessions(cwd: cwd)) ?? [] {
            if sessions[item.sessionId] == nil {
                // A session nobody ever spoke to is not an agent anyone
                // started work with. OpenCode keeps every `session/new`,
                // including the ones New Agent made and nobody answered, and
                // adopting them drew four identical green "tranquility-base"
                // rows on Robert's panel (15 Sep). The placeholder title is
                // how the list says "never prompted"; the model names a
                // session at its first turn. One started in THIS process is
                // already known here and is not touched by this rule.
                guard ACPWire.SessionList.Item.name(item.title) != nil,
                      ledger?.forgotten(item.sessionId, provider: id) != true else { continue }
                var session = item.agentSession(provider: id)
                session.directory = item.cwd ?? cwd
                session.shell = door(item.sessionId)
                sessions[item.sessionId] = session
                emit(session.id, .appeared(session))
            } else if let title = ACPWire.SessionList.Item.name(item.title),
                      sessions[item.sessionId]?.title != title {
                sessions[item.sessionId]?.title = title
                if let session = sessions[item.sessionId] { emit(session.id, .changed(session)) }
            }
        }
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
        try await connectIfNeeded()
        try await loadIfNeeded(raw)
        // The first thing said names the row until the model does (#470):
        // the precedence is the model's title, then the first user message,
        // then the agent and its place, and this is the middle rung.
        if sessions[raw]?.title.isEmpty == true, let named = sessions[raw] {
            var titled = named
            titled.title = Self.headline(text)
            sessions[raw] = titled
            emit(titled.id, .changed(titled))
        }
        turnText[raw] = ""
        _ = seen(raw: raw, state: .submitted)
        turns[raw]?.cancel()
        turns[raw] = Task { [weak self] in await self?.run(turn: text, in: raw) }
        return .accepted
    }

    /// One prompt turn, start to stop reason.
    private func run(turn text: String, in raw: String) async {
        do {
            let result = try await client.prompt(text, session: raw)
            await caughtUp(to: result.sequence)
            let said = turnText[raw] ?? ""
            turnText[raw] = nil
            // The ending first, then the words, so the latest line in the
            // spool for this session is the one that carries what was said:
            // the announcer speaks a session's latest stop, and a bare
            // "finished a turn" after the words would be the one it read.
            let session = seen(raw: raw, state: result.state)
            if !said.isEmpty {
                emit(session.id, .said(Turn(id: "\(raw)-\(saidSoFar[raw]?.count ?? 0)",
                                            at: Date(), role: .agent, text: said)))
            }
            try? await adoptListed()
        } catch {
            turnText[raw] = nil
            let session = seen(raw: raw, state: .failed)
            emit(session.id, .failed(reason: "\(error)"))
        }
    }

    /// The first line of what the USER said, cut to a row's width. A reply
    /// through the panel is framed as `[assistant]: <heard>` then
    /// `[user]: <said>` (`HeardContext`); the row wore the first half
    /// (Robert, 15 Sep: a row titled "[assistant]: How should we get
    /// started?"). The user's own words are the title; the framing is not.
    static func headline(_ text: String) -> String {
        let spoken = HeardContext.spokenPart(text)
        let line = spoken.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? spoken
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count <= 60 ? trimmed : String(trimmed.prefix(59)) + "…"
    }

    /// Bring a listed session into this process before speaking to it.
    private func loadIfNeeded(_ raw: String) async throws {
        guard !loaded.contains(raw) else { return }
        replaying.insert(raw)
        defer { replaying.remove(raw) }
        try await client.loadSession(raw, cwd: cwd)
        loaded.insert(raw)
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
        guard let words = response.answers.first?.first else {
            return .failed(reason: "nothing chosen")
        }
        // What was SAID picks the option; the option id goes back. Sending
        // the words as the id was refused by the agent and the row held its
        // lamp for ever. A reply that chooses nothing is refused here, out
        // loud, rather than guessed at.
        guard let chosen = waiting.request.option(chosenBy: words) else {
            return .failed(reason: "\"\(words.prefix(40))\" does not choose one of: "
                + (waiting.request.questions.first?.options.map(\.label).joined(separator: ", ") ?? "no options"))
        }
        try await connectIfNeeded()
        try await client.respond(to: waiting.rpcID,
                                 result: ["outcome": ["outcome": "selected",
                                                      "optionId": chosen.id]])
        asking[request.session] = nil
        emit(request.session, .answered(requestId: request.id))
        return .accepted
    }

    public func start(_ brief: Brief) async throws -> AgentSession.ID {
        try await connectIfNeeded()
        ledger?.mark(id)
        let raw = try await client.newSession(cwd: cwd)
        loaded.insert(raw)
        // An agent started with nothing to do is waiting for you, which under
        // the three-lamp ruling is your turn: `.inputRequired`, green. It
        // shipped as `.submitted`, which is blue, and the first thing the row
        // said about a fresh OpenCode was "working" (#470). `.submitted` is
        // kept for the brief that is on its way.
        let session = seen(raw: raw, state: brief.prompt.isEmpty ? .inputRequired : .submitted)
        if !brief.prompt.isEmpty { _ = try await send(brief.prompt, to: session.id) }
        return session.id
    }

    public func cancel(_ id: AgentSession.ID) async throws -> SendOutcome {
        guard let raw = providerID(of: id) else { return .failed(reason: "no such session") }
        try await client.cancel(session: raw)
        _ = seen(raw: raw, state: .canceled)
        return .accepted
    }

    /// End Agent: the turn is cancelled if one is running, the session is
    /// dropped here and remembered as ended so the next launch's list does
    /// not bring it back. OpenCode keeps the session in its own store.
    public func forget(_ id: AgentSession.ID) async {
        guard let raw = providerID(of: id) else { return }
        turns[raw]?.cancel()
        if connected { _ = try? await client.cancel(session: raw) }
        sessions[raw] = nil
        loaded.remove(raw)
        asking[id] = nil
        ledger?.forget(raw, provider: self.id)
    }

    /// A local agent has no page to open. `SessionRow.Door` already knows how
    /// to mean "nowhere", which is better than inventing a URL that 404s.
    public nonisolated func url(for id: AgentSession.ID) -> URL? { nil }

    private func door(_ raw: String) -> AgentSession.ShellDoor? {
        open(raw).map { AgentSession.ShellDoor(command: $0, directory: cwd) }
    }

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
