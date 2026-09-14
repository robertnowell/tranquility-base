import Foundation

/// crobot: OpenCode in a sandbox, behind a gateway that owns its lifecycle.
///
/// **Only the lifecycle is here.** Sessions, messages, the event stream,
/// questions and permissions all live in `OpenCodeClient`, pointed at the
/// gateway's reverse proxy (`/api/v1/tasks/:id/opencode/*`), because that
/// proxy IS an OpenCode server. What is left is the half a local server has
/// none of: tasks, repositories, pull requests, waking, sleeping and org
/// scope.
///
/// That split is why the second provider was cheap. Written as one monolith it
/// would have cost what the first did.
public struct CrobotProvider: AgentProvider {

    public let id = "crobot"
    private let transport: any CrobotTransport
    /// Whose work to show. crobot's list endpoint has **no creator filter**,
    /// so this is applied client-side; without it a row appears for an agent
    /// this user cannot answer.
    private let me: String?

    public init(transport: any CrobotTransport, me: String?) {
        self.transport = transport
        self.me = me
    }

    public var can: Capabilities {
        Capabilities(
            canStart: true,
            canSend: true,
            canAnswer: true,
            canCancel: false,
            // The sandbox refuses a follow-up while a turn is running; the
            // gateway answers 409 and `OpenCodeClient` turns that into `.busy`.
            sendWhileWorking: false,
            // **FALSE, and this is the one that matters.** `GET /api/v1/tasks`
            // returns everybody's tasks. `mine()` filters on `createdBy` here,
            // and a caller that trusted the list would show rows for other
            // people's work.
            listIsCallerScoped: false,
            carriesPullRequest: true)
    }

    // MARK: - Ingress

    /// **Polled, not streamed.** The gateway has an SSE stream per task, but
    /// no stream over the task LIST, so there is nothing to subscribe to for
    /// the row set. Returning nil is the declaration, and `AgentPoller` reads
    /// it and polls instead.
    public func changes() -> AsyncStream<AgentEvent>? { nil }

    public func mine() async throws -> [AgentSession] {
        // A GENEROUS PAGE. `limit` slices newest-first, so a small page silently
        // drops the caller's older tasks off the end while returning a
        // perfectly valid list of somebody else's newer ones.
        try await transport.tasks(limit: 200)
            .filter { task in me.map { task.createdBy == $0 } ?? true }
            .map { $0.agentSession(provider: id) }
    }

    // MARK: - Detail

    /// The detail endpoint, which carries `running` and the list DOES NOT.
    ///
    /// A listed status of `running` is a claim; `running` on the detail is an
    /// observation of the sandbox. That asymmetry is the reason tier two of
    /// the poller exists at all.
    public func refine(_ id: AgentSession.ID) async throws -> AgentSession {
        guard let raw = try await rawID(for: id) else { throw CrobotError.noSuchTask }
        return try await transport.task(raw).agentSession(provider: self.id)
    }

    public func request(_ id: AgentSession.ID) async throws -> PendingRequest? {
        guard let raw = try await rawID(for: id) else { return nil }
        do {
            return try await opencode(raw).pendingRequest(sessionFor: raw, transport: transport)
        } catch OpenCodeClient.ClientError.asleep {
            // **NORMAL, not an error.** The gateway answers reads with 409
            // rather than waking a task, so an idle crobot task returns this
            // on every poll. A sleeping sandbox is not asking a question.
            return nil
        }
    }

    public func transcript(_ id: AgentSession.ID) async throws -> [Turn] {
        guard let raw = try await rawID(for: id) else { return [] }
        do { return try await opencode(raw).transcript(sessionFor: raw, transport: transport) }
        catch OpenCodeClient.ClientError.asleep { return [] }
    }

    // MARK: - Egress

    /// Both a follow-up and an answer go to the SAME endpoint.
    ///
    /// `POST /tasks/:id/prompt` fuzzy-matches the text against the pending
    /// question's option labels and reports whether it resolved one. So there
    /// is no separate answer verb here, and sending prose at a question is
    /// correct for this provider where it would be wrong for a bare OpenCode
    /// server.
    public func send(_ text: String, to id: AgentSession.ID) async throws -> SendOutcome {
        guard let raw = try await rawID(for: id) else { return .failed(reason: "no such task") }
        // THE DECLARATION IS LOAD-BEARING, not decorative. `sendWhileWorking`
        // is false for this provider, so a send to a working task reports busy
        // here rather than being posted and refused somewhere downstream.
        //
        // Caught by the conformance suite, which asserts both sides of every
        // capability: the first draft declared the limit and then forwarded
        // whatever the gateway said, so a provider that lied about itself
        // would have passed. A capability nothing enforces is the same defect
        // as a capability nothing reads.
        if !can.sendWhileWorking,
           let task = try? await transport.task(raw), task.state == .working {
            return .busy
        }
        return try await transport.prompt(raw, text: text)
    }

    public func respond(to request: PendingRequest,
                        with response: Response) async throws -> SendOutcome {
        // The words the user chose, sent as a prompt, because that is the only
        // door the gateway offers. `answers` is flattened in question order,
        // which is the order the option labels were shown in.
        let words = response.answers.flatMap { $0 }.joined(separator: ", ")
        guard !words.isEmpty else { return .failed(reason: "nothing to say") }
        return try await send(words, to: request.session)
    }

    public func start(_ brief: Brief) async throws -> AgentSession.ID {
        guard let repository = brief.repository else {
            // A task without a repository is not a thing crobot can make, and
            // saying so beats a 400 the user has to interpret.
            throw CrobotError.repositoryRequired
        }
        let raw = try await transport.create(repo: repository, prompt: brief.prompt,
                                             baseBranch: brief.branch)
        return AgentSession.id(raw, provider: id)
    }

    public func cancel(_ id: AgentSession.ID) async throws -> SendOutcome {
        // No cancel verb on the gateway. Declaring the capability false and
        // refusing here is the honest pair; the alternative is a button that
        // does nothing.
        .unsupported
    }

    public func url(for id: AgentSession.ID) -> URL? { transport.taskURL(id) }

    // MARK: -

    /// The gateway's own task id for an app-side id.
    ///
    /// `AgentSession.id` keeps a crobot task id verbatim, because they are
    /// already hex and dashes, so this is almost always the identity. It is a
    /// lookup rather than an assumption because "almost always" is how the
    /// next id format change becomes a silent 404.
    private func rawID(for id: AgentSession.ID) async throws -> String? {
        if ArtifactStore.isPlausibleSession(id),
           AgentSession.id(id, provider: self.id) == id { return id }
        return try await mine().first { $0.id == id }?.providerID
    }

    private func opencode(_ raw: String) -> OpenCodeClient {
        OpenCodeClient(transport: transport.opencode(raw), provider: id)
    }

    public enum CrobotError: Error, CustomStringConvertible, Equatable {
        case noSuchTask
        case repositoryRequired
        public var description: String {
            switch self {
            case .noSuchTask: return "no such crobot task"
            case .repositoryRequired: return "crobot needs a repository to start a task"
            }
        }
    }
}

// MARK: - The gateway, as a seam

/// What the gateway can be asked, so a test never opens a socket.
public protocol CrobotTransport: Sendable {
    func tasks(limit: Int) async throws -> [CrobotTask]
    func task(_ id: String) async throws -> CrobotTask
    func prompt(_ id: String, text: String) async throws -> SendOutcome
    func create(repo: String, prompt: String, baseBranch: String?) async throws -> String
    func taskURL(_ id: String) -> URL?
    /// An `OpenCodeClient` transport pointed at this task's proxy.
    func opencode(_ id: String) -> any OpenCodeClient.Transport
}

/// One crobot task, in the gateway's own shape.
///
/// Read from `ui/src/types.ts` against the running gateway, not guessed.
/// Everything optional, per rule 1: a field the gateway adds or stops sending
/// must cost one row's detail rather than the whole list.
public struct CrobotTask: Decodable, Sendable, Equatable {
    public var id: String
    public var title: String?
    public var repo: String?
    public var createdBy: String?
    public var status: String?
    public var statusDetail: String?
    /// **Present on the DETAIL endpoint and absent from the LIST.** A listed
    /// status of `running` is a claim; this is an observation.
    public var running: Bool?
    public var prUrl: String?
    public var lastActive: String?

    /// The prefix the gateway writes and depends on
    /// (`gateway/src/manifests.ts`, `WAITING_FOR_ANSWER`).
    ///
    /// **Matched as a PREFIX, never by equality**, because that same field
    /// also carries provider rate-limit text and pod-loss notices. Worth
    /// knowing: crobot's own web client does not use this at all, and its list
    /// view shows a blocked task as running.
    public static let waitingPrefix = "Waiting for your answer"

    public var isWaiting: Bool { statusDetail?.hasPrefix(Self.waitingPrefix) ?? false }

    public func agentSession(provider: String) -> AgentSession {
        var session = AgentSession.of(id, provider: provider, title: title ?? "",
                                      state: state, updatedAt: Self.date(lastActive))
        session.repository = repo
        session.pullRequest = prUrl.flatMap(URL.init(string:))
        return session
    }

    /// crobot's five statuses, plus the one it has no status for.
    var state: AgentSessionState {
        // WAITING OUTRANKS THE STATUS, because crobot has no waiting state at
        // all: a blocked task still reads `running`, and the only evidence is
        // the prefix on `statusDetail`.
        if isWaiting { return .inputRequired }
        switch status {
        case "starting": return .submitted
        case "running":
            // The list omits `running`, so nil here means "the list said so",
            // which is a claim rather than an observation. Trusting it is
            // correct for a row; tier two of the poller is what verifies it.
            return .working
        case "idle": return .completed
        case "failed": return .failed
        // The disk was released; the record stays and a follow-up recreates
        // the sandbox. Finished, not dead.
        case "archived": return .completed
        default: return .unknown
        }
    }

    static func date(_ raw: String?) -> Date {
        guard let raw else { return Date(timeIntervalSince1970: 0) }
        return ISO8601DateFormatter().date(from: raw) ?? Date(timeIntervalSince1970: 0)
    }
}

extension OpenCodeClient {
    /// crobot's proxy is scoped to ONE task, and that task has one OpenCode
    /// session whose id the gateway knows. These resolve it rather than making
    /// the caller carry two ids.
    func pendingRequest(sessionFor task: String,
                        transport: any CrobotTransport) async throws -> PendingRequest? {
        guard let session = try await sessions().first else { return nil }
        return try await pendingRequest(session.providerID)
    }

    func transcript(sessionFor task: String,
                    transport: any CrobotTransport) async throws -> [Turn] {
        guard let session = try await sessions().first else { return [] }
        return try await transcript(session.providerID)
    }
}
