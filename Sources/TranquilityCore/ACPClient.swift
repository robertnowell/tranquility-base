import Foundation

/// A JSON-RPC peer speaking ACP to a child process over its stdio.
///
/// **The transport is injected**, exactly as `OpenCodeClient`'s is, so the
/// whole protocol can be exercised against a scripted pipe with no agent
/// installed. That mattered immediately: CI has no `opencode`, no `cursor-agent`
/// and no `gemini`, so a client that could only be tested by spawning one would
/// have no tests at all on the machine that gates merges.
///
/// Duplex and line-oriented. `send` writes one line; `lines()` yields whatever
/// comes back, interleaved, in arrival order, because on one pipe a response to
/// our request and a request from the agent are the same stream.
public protocol ACPTransport: Sendable {
    func write(_ line: Data) async throws
    func lines() -> AsyncStream<Data>
    /// Ends the conversation and reaps whatever was behind it.
    func close() async
}

public actor ACPClient {

    public enum ClientError: Error, Equatable {
        case notInitialized
        case timedOut(method: String)
        case remote(code: Int, message: String)
        /// The agent answered a different protocol version than we speak.
        case versionMismatch(theirs: Int, ours: Int)
    }

    private let transport: any ACPTransport
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<ACPWire.Message, Error>] = [:]
    private var reader: Task<Void, Never>?

    /// What the agent said it could do, from the handshake. nil until
    /// `initialize()` returns, and `Capabilities` is derived from it rather
    /// than from a catalog entry that would go stale.
    public private(set) var handshake: ACPWire.Initialized?

    /// Notifications and agent-to-client requests, for whoever owns the
    /// session. Kept as a stream rather than a delegate so the provider can
    /// map it straight into `AgentEvent` without a second buffering layer.
    private var inboundContinuation: AsyncStream<ACPWire.Message>.Continuation?
    public nonisolated let inbound: AsyncStream<ACPWire.Message>

    /// How long any one request may take. Generous, because a prompt turn is a
    /// model call: the live probe's round trip was 22 seconds and that was a
    /// three-token answer.
    public private(set) var timeout: Duration = .seconds(180)

    /// Shortened when a caller is probing rather than working: a catalog sweep
    /// across eleven agents cannot spend three minutes per broken one.
    public func setTimeout(_ value: Duration) { timeout = value }

    public init(transport: any ACPTransport) {
        self.transport = transport
        var continuation: AsyncStream<ACPWire.Message>.Continuation!
        self.inbound = AsyncStream { continuation = $0 }
        self.inboundContinuation = continuation
    }

    // MARK: - The loop

    /// Start reading. Idempotent, so a caller that is unsure cannot start two.
    public func start() {
        guard reader == nil else { return }
        reader = Task { [weak self] in
            guard let self else { return }
            for await line in await self.transport.lines() {
                await self.receive(line)
            }
            await self.failEverythingPending()
        }
    }

    /// One line in. A line that is not a JSON-RPC message is DROPPED rather
    /// than thrown: agents print banners, progress and warnings to stdout, and
    /// a client that died on the first one would work only for the agents that
    /// happen to be quiet.
    private func receive(_ line: Data) {
        guard let message = ACPWire.Message(line: line) else { return }
        if let id = message.id, message.method == nil {
            // A response to something we asked.
            pending.removeValue(forKey: id)?.resume(returning: message)
            return
        }
        // A notification, or a request from the agent. Both belong to the
        // session's owner, not to this layer.
        inboundContinuation?.yield(message)
    }

    /// The pipe closed with requests outstanding. Every one of them fails with
    /// its own reason rather than hanging until its timeout, because "the
    /// agent exited" is an answer and a stalled await is not.
    private func failEverythingPending() {
        let stranded = pending
        pending = [:]
        for (_, continuation) in stranded {
            continuation.resume(throwing: ClientError.remote(
                code: -1, message: "the agent's stdio closed"))
        }
        inboundContinuation?.finish()
    }

    // MARK: - Asking

    /// **Nothing that is not `Sendable` crosses into the actor**, and the
    /// waiting happens outside it.
    ///
    /// `[String: Any]` is not `Sendable`, so handing one to an actor is a data
    /// race the compiler is right to refuse. This compiled on arm64 and failed
    /// on the Intel slice, which is exactly why that job exists: one toolchain
    /// was stricter and the stricter one was correct. So the dictionary is
    /// serialised here, on the caller's side, and only `Data` goes in.
    ///
    /// The timeout race lives out here too. A task group inside an actor method
    /// hands closures a `self`-isolated context, which is its own hazard; out
    /// here the group is ordinary concurrent code and the actor is touched only
    /// by the one call that needs it.
    @discardableResult
    public nonisolated func request(_ method: String,
                                    params: [String: Any] = [:]) async throws
        -> ACPWire.Message {
        // `params` is ALWAYS sent, even empty. JSON-RPC 2.0 permits omitting
        // it and a live `opencode acp` 1.18.30 answers `session/list` with
        // nothing at all when it is absent — no result, no error, just silence
        // until the request times out. Measured 14 Sep, after the fixture
        // passed and the real agent returned zero sessions.
        let encoded = try JSONSerialization.data(withJSONObject: params)
        let limit = await timeout

        let message: ACPWire.Message = try await withThrowingTaskGroup(
            of: ACPWire.Message.self
        ) { group in
            group.addTask {
                try await Task.sleep(for: limit)
                throw ClientError.timedOut(method: method)
            }
            group.addTask {
                try await self.deliver(method: method, params: encoded)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw ClientError.timedOut(method: method)
            }
            return first
        }
        if let error = message.error {
            throw ClientError.remote(code: error.code, message: error.message)
        }
        return message
    }

    /// The isolated half: allocate the id, register the waiter, write the line.
    private func deliver(method: String, params: Data) async throws -> ACPWire.Message {
        let id = nextID
        nextID += 1
        // Assembled as bytes, so the envelope never becomes a dictionary that
        // would have to cross a boundary to get here.
        var line = Data(#"{"jsonrpc":"2.0","id":"#.utf8)
        line.append(Data("\(id)".utf8))
        line.append(Data(#","method":"#.utf8))
        line.append(try JSONEncoder().encode(method))
        line.append(Data(#","params":"#.utf8))
        line.append(params)
        line.append(Data("}".utf8))

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [transport] in
                do { try await transport.write(line) }
                catch { await self.abandon(id: id, because: error) }
            }
        }
    }

    /// The write itself failed, so nobody will ever answer this id.
    private func abandon(id: Int, because error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    /// A reply to a request the AGENT made of us. Carries the agent's id back,
    /// so it is a response and never a new request. Encoded on the caller's
    /// side for the same reason `request` is.
    public nonisolated func respond(to id: Int, result: [String: Any]) async throws {
        let body: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        try await write(try JSONSerialization.data(withJSONObject: body))
    }

    private func write(_ line: Data) async throws { try await transport.write(line) }

    // MARK: - The protocol

    /// Handshake. Returns what the agent says it can do.
    ///
    /// A version the client does not speak is REFUSED rather than tolerated:
    /// the shape of every message below depends on it, and carrying on would
    /// mean decoding version 2 payloads with version 1 expectations and
    /// reporting the resulting nils as an idle agent.
    @discardableResult
    public func initialize() async throws -> ACPWire.Initialized {
        let message = try await request("initialize", params: [
            "protocolVersion": ACPWire.protocolVersion,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false]],
        ])
        guard let initialized = message.result(ACPWire.Initialized.self) else {
            throw ClientError.remote(code: -1, message: "initialize returned no result")
        }
        guard initialized.protocolVersion == ACPWire.protocolVersion else {
            throw ClientError.versionMismatch(theirs: initialized.protocolVersion,
                                              ours: ACPWire.protocolVersion)
        }
        handshake = initialized
        return initialized
    }

    public func newSession(cwd: String) async throws -> String {
        let message = try await request("session/new",
                                        params: ["cwd": cwd, "mcpServers": []])
        guard let new = message.result(ACPWire.NewSession.self) else {
            throw ClientError.remote(code: -1, message: "session/new returned no sessionId")
        }
        return new.sessionId
    }

    /// One prompt turn. Returns why it stopped, which is what decides the lamp.
    public func prompt(_ text: String, session: String) async throws -> ACPWire.PromptResult {
        let message = try await request("session/prompt", params: [
            "sessionId": session,
            "prompt": [["type": "text", "text": text]],
        ])
        return message.result(ACPWire.PromptResult.self) ?? ACPWire.PromptResult()
    }

    /// Sessions the agent already knows about.
    ///
    /// **The catch-up a streaming provider cannot do without.** A push
    /// provider only hears what happens next, so without this every session
    /// that existed before the client attached is invisible for ever. That
    /// exact defect shipped once already, on 14 Sep, against local OpenCode
    /// over HTTP; the conformance suite caught it here before it could.
    ///
    /// `cwd` is a filter, and the agent applies it: measured 15 Sep against
    /// `opencode acp`, a process in one directory asked for another's
    /// sessions got that other directory's sessions. Passed explicitly so the
    /// list is the workspace's regardless of where the process happens to run.
    public func listSessions(cwd: String? = nil) async throws -> [ACPWire.SessionList.Item] {
        let message = try await request("session/list", params: cwd.map { ["cwd": $0] } ?? [:])
        return message.result(ACPWire.SessionList.self)?.sessions ?? []
    }

    /// `session/load`: bring a session this process has only LISTED back into
    /// it. A listed session is not a loaded one: measured 15 Sep, a prompt to
    /// a listed-but-unloaded id is refused with "session not found". The agent
    /// replays the session's history as `session/update` notifications before
    /// answering, which the caller has to expect and must not announce.
    public func loadSession(_ session: String, cwd: String) async throws {
        try await request("session/load", params: [
            "sessionId": session, "cwd": cwd, "mcpServers": [],
        ])
    }

    public func cancel(session: String) async throws {
        try await request("session/cancel", params: ["sessionId": session])
    }

    public func close() async {
        reader?.cancel()
        await transport.close()
        failEverythingPending()
    }
}
