import Foundation

/// A local `opencode serve`, as an agent provider.
///
/// **The streaming half of the pair**, and deliberately so. crobot is polled
/// REST; this one subscribes. Two request-response providers would not have
/// exercised the half that matters, and the conformance suite's whole job is to
/// police the difference.
///
/// It is also the cheapest thing in the epic to prove end to end: no credential
/// unless the server was started with one, no account, no network, no cluster.
/// Every failure mode in rows, lamps, the event stream, a pending permission, a
/// follow-up, the transcript and the hub page is slow to diagnose against a
/// remote gateway and fast to diagnose against a process you can restart.
///
/// And it is the honest second conformance for the model: it shares a client
/// with crobot and differs completely in lifecycle. `carriesPullRequest`,
/// `listIsCallerScoped` and `url(for:)` all disagree with crobot's, which is
/// exactly the shape #375 exists to catch.
public struct LocalOpenCodeProvider: AgentProvider {

    public let id = "opencode"
    private let client: OpenCodeClient

    public init(client: OpenCodeClient) {
        self.client = client
    }

    /// The provider this machine is configured for, or nil when it has no
    /// address for a local server. Absent means not connected, never an error.
    public init?(config: URL = HubApp.configPath, session: URLSession = .shared) {
        guard let base = ProviderConfig.baseURL("opencode", config: config) else { return nil }
        self.client = OpenCodeClient(
            transport: HTTPTransport(base: base,
                                     password: Secrets.read(.openCodePassword),
                                     session: session),
            provider: "opencode")
    }

    public var can: Capabilities {
        Capabilities(
            canStart: true,
            canSend: true,
            canAnswer: true,
            canCancel: false,
            // A local server takes a follow-up while it is working; the queue
            // is the server's problem, not ours. crobot's sandbox is the one
            // that refuses.
            sendWhileWorking: true,
            // Caller-scoped BY CONSTRUCTION: it is your own process on your own
            // machine. crobot's list has no creator filter at all, and the two
            // disagreeing here is the point of building both.
            listIsCallerScoped: true,
            // No pull requests exist here. A provider that invented one would
            // be lying, and `AgentSession.pullRequest` stays nil.
            carriesPullRequest: false)
    }

    // MARK: - Ingress

    /// The server's own `/event` stream. Non-nil, which IS the declaration that
    /// this provider pushes rather than being polled.
    public func changes() -> AsyncStream<AgentEvent>? { client.events() }

    /// Mandatory even here, because it is the catch-up after the stream drops,
    /// and a local server restarts more often than a cluster does. A2A's rule,
    /// copied: the snapshot has to be available or a client that missed a
    /// transition into a blocked state stays wrong about it for ever.
    public func mine() async throws -> [AgentSession] {
        try await client.sessions()
    }

    // MARK: - Detail

    public func refine(_ id: AgentSession.ID) async throws -> AgentSession {
        guard let hit = try await mine().first(where: { $0.id == id }) else {
            throw ProviderError.noSuchSession(id)
        }
        return hit
    }

    /// The id the SERVER knows, for an addressable id this app minted.
    ///
    /// `AgentSession.id` hashes anything that is not already hex and dashes, so
    /// the mapping is one-way. `AgentSession.providerID` carries the other half
    /// precisely so no caller has to keep a private reverse map, and this is
    /// one list call, the same one `mine()` already makes on every poll.
    private func raw(for id: AgentSession.ID) async throws -> String {
        guard let hit = try await mine().first(where: { $0.id == id }) else {
            throw ProviderError.noSuchSession(id)
        }
        return hit.providerID
    }

    public func request(_ id: AgentSession.ID) async throws -> PendingRequest? {
        try await client.pendingRequest(raw(for: id))
    }

    public func transcript(_ id: AgentSession.ID) async throws -> [Turn] {
        try await client.transcript(raw(for: id))
    }

    // MARK: - Egress

    public func send(_ text: String, to id: AgentSession.ID) async throws -> SendOutcome {
        guard can.canSend else { return .unsupported }
        return try await client.send(text, to: raw(for: id))
    }

    public func respond(to request: PendingRequest,
                        with response: Response) async throws -> SendOutcome {
        guard can.canAnswer else { return .unsupported }
        // WHICH ROUTE raised it decides how it is answered, and the two are not
        // interchangeable: a question answered on the permission route, or the
        // reverse, is a 404 the user reads as silence. The client cannot tell
        // them apart from the request alone, so the kind is carried by the
        // option vocabulary, which is the one thing that differs: a permission
        // is the only request built from ACP's allow/reject kinds.
        let isPermission = request.questions.count == 1
            && request.questions[0].options.allSatisfy { $0.kind != .other }
            && !request.questions[0].options.isEmpty

        // AN ANSWER MUST NAME AN OPTION THE REQUEST OFFERED, and the provider
        // checks rather than trusting the caller. Caught by the conformance
        // suite on this provider's first run, which is the whole reason that
        // rule is in there: a row the user left open holds the options as they
        // were minutes ago, and a stale pick must not be forwarded as though it
        // were current. The server would likely refuse it too, but "likely" is
        // a silent send and a lamp that never changes.
        //
        // A question that allows custom text has nothing to check against, and
        // one with no options at all is free text by definition.
        if let bad = firstUnofferedAnswer(in: request, response) {
            return .failed(reason: "no such option: \(bad)")
        }

        return try await client.respond(
            to: request, kind: isPermission ? .permission : .question,
            session: try await raw(for: request.session), with: response)
    }

    /// The first answer that names something the request did not offer, or nil
    /// when every answer is valid. Position matters: answer `n` belongs to
    /// question `n`, which is the contract `Response` documents.
    func firstUnofferedAnswer(in request: PendingRequest, _ response: Response) -> String? {
        guard !response.isRejection else { return nil }
        for (index, question) in request.questions.enumerated() {
            guard !question.allowsCustom, !question.options.isEmpty,
                  index < response.answers.count else { continue }
            let offered = Set(question.options.map(\.id))
            if let bad = response.answers[index].first(where: { !offered.contains($0) }) {
                return bad
            }
        }
        return nil
    }

    public func start(_ brief: Brief) async throws -> AgentSession.ID {
        guard can.canStart else { throw ProviderError.unsupported }
        let id = try await client.start()
        // The brief is the first message. A local server has no repository or
        // branch to take, which is why `Brief` carries both as optional.
        if !brief.prompt.isEmpty {
            _ = try await client.send(brief.prompt, to: raw(for: id))
        }
        return id
    }

    public func cancel(_ id: AgentSession.ID) async throws -> SendOutcome {
        // OpenCode's abort route is not in the surface this client covers, and
        // declaring a capability with nothing behind it is how the previous
        // capability struct reached four dead fields. `.unsupported` is a
        // sentence the panel can say; a lie is not.
        .unsupported
    }

    /// **nil, and that is the honest answer.** There is no web page for a
    /// process on your own machine, which is why the protocol lets this return
    /// nothing rather than forcing every provider to invent a URL.
    public func url(for id: AgentSession.ID) -> URL? { nil }

    public enum ProviderError: Error, CustomStringConvertible, Equatable {
        case noSuchSession(String)
        case unsupported
        public var description: String {
            switch self {
            case .noSuchSession(let id): return "no session \(id.prefix(8)) on this server"
            case .unsupported: return "this provider cannot do that"
            }
        }
    }
}

// MARK: - The real transport

/// `URLSession` against a local server, beside the protocol like
/// `HubMirror.URLSessionTransport` sits beside its own.
public struct HTTPTransport: OpenCodeClient.Transport {
    public let base: URL
    /// HTTP BASIC with the literal username `opencode`, which is what the
    /// crobot gateway itself sets when it proxies to a sandbox. nil for a
    /// server started without `--password`, which accepts unauthenticated
    /// requests from localhost: that absence is a configuration, not a fault.
    public let password: String?
    public var session: URLSession
    /// Why the stream stopped, when it does.
    ///
    /// This existed as an empty `catch {}` for exactly one afternoon, and that
    /// afternoon is the whole argument for the 11 Sep ruling it violated: the
    /// subscription failed silently against a live server and there was no way
    /// to find out why without editing the file. A failure worth recording is
    /// recorded WITH ITS REASON.
    public var trace: (@Sendable (String) -> Void)?

    public init(base: URL, password: String?, session: URLSession = .shared,
                trace: (@Sendable (String) -> Void)? = nil) {
        self.base = base; self.password = password; self.session = session
        self.trace = trace
    }

    private func authorized(_ request: inout URLRequest) {
        guard let password, let raw = "opencode:\(password)".data(using: .utf8) else { return }
        request.setValue("Basic " + raw.base64EncodedString(),
                         forHTTPHeaderField: "Authorization")
    }

    public func send(method: String, path: String, body: Data?) async throws
        -> (status: Int, body: Data) {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        // Short, because a poll that hangs has already failed at its job even
        // if it eventually answers. The stream below is deliberately not
        // bounded this way.
        request.timeoutInterval = 15
        authorized(&request)
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// One accumulated line, yielded if it carries a payload.
    ///
    /// `\r` is stripped because SSE permits CRLF and a trailing carriage
    /// return would ride into the JSON decoder and fail it for a reason nobody
    /// would guess from the error.
    private static func emit(_ buffer: inout [UInt8],
                             to continuation: AsyncStream<Data>.Continuation) {
        defer { buffer.removeAll(keepingCapacity: true) }
        guard !buffer.isEmpty,
              let line = String(bytes: buffer, encoding: .utf8)?
                  .trimmingCharacters(in: CharacterSet(charactersIn: "\r")),
              line.hasPrefix("data:")
        else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty else { return }
        continuation.yield(Data(payload.utf8))
    }

    public func events() -> AsyncStream<Data>? {
        var request = URLRequest(url: base.appendingPathComponent("event"))
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        // No timeout: a stream that is quiet is not a stream that is broken,
        // and the 15 seconds above would tear down a healthy subscription
        // every time the agent stopped to think.
        request.timeoutInterval = .infinity
        authorized(&request)
        let session = self.session
        let trace = self.trace
        // Captured as a `let`: a var crossing into a concurrently-executing
        // closure is a data race the compiler is right to refuse.
        let subscription = request
        return AsyncStream { continuation in
            // `@Sendable` explicitly: the continuation and the request both
            // cross into the task, and strict concurrency is right to ask.
            let task = Task { @Sendable in
                do {
                    let (bytes, _) = try await session.bytes(for: subscription)
                    // Server-sent events: `data: <json>` lines, blank-line
                    // separated. Only the payload matters here; the client
                    // decides what a frame means.
                    trace?("opencode stream connected")
                    // LINES SPLIT BY HAND, from the raw byte stream.
                    //
                    // `AsyncBytes.lines` looks like exactly the right tool and
                    // is unusable here. Measured against a live
                    // `opencode serve` 1.18.30: iterating `bytes` yields the
                    // first frame in about ten milliseconds, and iterating
                    // `bytes.lines` on the same request yields NOTHING for
                    // eight seconds and then reports only the cancellation that
                    // ended the wait.
                    //
                    // It fails in the worst available shape: no error, no
                    // throw, just silence, which is indistinguishable from a
                    // server with nothing to say. The stream had connected, the
                    // status was 200 and the content type was
                    // `text/event-stream`, and every one of those facts was
                    // reassuring and irrelevant.
                    //
                    // So: accumulate bytes, split on newline, and keep the
                    // remainder. Server-sent events are newline-delimited by
                    // definition, so this is the format's own rule rather than
                    // a workaround for one server.
                    var buffer: [UInt8] = []
                    for try await byte in bytes {
                        guard byte != UInt8(ascii: "\n") else {
                            Self.emit(&buffer, to: continuation)
                            continue
                        }
                        buffer.append(byte)
                        // A frame that never ends is a memory leak with good
                        // manners. 1 MB is far past any real event and far
                        // short of a problem.
                        if buffer.count > 1_000_000 { buffer.removeAll(keepingCapacity: true) }
                    }
                    Self.emit(&buffer, to: continuation)
                } catch {
                    // A dropped stream is not fatal: `mine()` is the catch-up,
                    // and that is the whole reason it stays mandatory for a
                    // streaming provider. But it is not silent either.
                    trace?("opencode stream ended: \(error)")
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
