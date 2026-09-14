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
    public var timeout: Duration = .seconds(180)

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

    @discardableResult
    public func request(_ method: String, params: [String: Any] = [:]) async throws
        -> ACPWire.Message {
        let id = nextID
        nextID += 1
        // `params` is ALWAYS sent, even empty. JSON-RPC 2.0 permits omitting
        // it and a live `opencode acp` 1.18.30 answers `session/list` with
        // nothing at all when it is absent — no result, no error, just
        // silence until the request times out. Measured 14 Sep, after the
        // fixture passed and the real agent returned zero sessions.
        let body: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ]
        let line = try JSONSerialization.data(withJSONObject: body)

        let message: ACPWire.Message = try await withThrowingTaskGroup(of: ACPWire.Message.self) {
            group in
            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                throw ClientError.timedOut(method: method)
            }
            group.addTask { [self] in
                try await withCheckedThrowingContinuation { continuation in
                    Task { await self.enqueue(id: id, continuation: continuation, line: line) }
                }
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

    private func enqueue(id: Int, continuation: CheckedContinuation<ACPWire.Message, Error>,
                         line: Data) async {
        pending[id] = continuation
        do { try await transport.write(line) } catch {
            pending.removeValue(forKey: id)?.resume(throwing: error)
        }
    }

    /// A reply to a request the AGENT made of us. Carries the agent's id back,
    /// so it is a response and never a new request.
    public func respond(to id: Int, result: [String: Any]) async throws {
        let body: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        try await transport.write(try JSONSerialization.data(withJSONObject: body))
    }

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
    public func listSessions() async throws -> [ACPWire.SessionList.Item] {
        let message = try await request("session/list")
        return message.result(ACPWire.SessionList.self)?.sessions ?? []
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
