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
        // WHO WE ARE, or nothing at all.
        //
        // Measured 14 Sep against the live gateway: 115 tasks visible, 7
        // created by this user. `listIsCallerScoped` is false, so this filter
        // is the only thing between the panel and 108 other people's agents,
        // and a nil identity used to mean "show everything" rather than "do
        // not know". Refusing is the safe direction: an empty list reads as
        // nothing to show, a full one reads as somebody else's work being
        // yours.
        guard let who = try await whoAmI() else { return [] }

        // A GENEROUS PAGE. `limit` slices newest-first, so a small page silently
        // drops the caller's older tasks off the end while returning a
        // perfectly valid list of somebody else's newer ones.
        return try await transport.tasks(limit: 200)
            .filter { $0.createdBy == who }
            // ARCHIVED IS HISTORY, not an agent. The disk was released; the
            // record stays so a follow-up can recreate the sandbox. 112 of the
            // 115 were archived, and listing them would bury three live agents
            // under a hundred tombstones.
            .filter { $0.status != "archived" }
            .map { $0.agentSession(provider: id) }
    }

    /// The caller's identity, asked once and remembered.
    ///
    /// `me` passed to the initialiser wins when present, so a test decides.
    private func whoAmI() async throws -> String? {
        if let me { return me }
        return try await transport.identity()
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

    /// **crobot cannot make a task without a repository, so it asks for one.**
    ///
    /// Not a picker special-cased into New Agent: the seam is
    /// `AgentProvider.startQuestions`, and this is crobot's answer to it. The
    /// options are the repos this key can reach (`GET /repos`, the same list
    /// crobot's Slack bot shows), with the org's default pre-selected. A repo
    /// already on the brief means nothing to ask — a deep link or a repeat.
    ///
    /// `allowsMultiple` because a crobot task can span repositories (the Slack
    /// picker says "tick one or more"); `allowsCustom` so a repo the list does
    /// not surface can still be typed, the same escape hatch every question has.
    public func startQuestions(for brief: Brief) async throws -> [PendingRequest.Question] {
        if let repo = brief.repository, !repo.isEmpty { return [] }
        let listing = try await transport.repos()
        let options = listing.repos.map {
            PendingRequest.Option(id: $0, label: $0)
        }
        return [PendingRequest.Question(
            asked: "Which repository should I work in?",
            options: options,
            allowsMultiple: true,
            allowsCustom: true)]
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
    /// The vendor's own id for an agent we hold an addressable id for.
    ///
    /// **The mapping is consulted FIRST, and that is the whole fix** (14 Sep
    /// 2026). This used to open with a shortcut: if the id looked like a
    /// plausible session and hashing it returned itself, treat it as already
    /// raw and skip the lookup. That guard is a TAUTOLOGY for any id that is
    /// already hex, because `AgentSession.id` returns such an id unchanged —
    /// and every id this type produces for crobot is a 64-character SHA-256
    /// digest, which is exactly that shape.
    ///
    /// So a send posted our own hash to the gateway as though it were a task
    /// id. Measured against the live gateway: the hash is 64 characters, a
    /// Kubernetes label value may be 63, so the sandbox lookup came back 400
    /// and the whole thing surfaced as a 500 with a PVC selector in it.
    ///
    /// Invisible against the fake, which accepts whatever id it is handed.
    /// Only a real gateway with a real Kubernetes behind it could say.
    private func rawID(for id: AgentSession.ID) async throws -> String? {
        if let known = try await mine().first(where: { $0.id == id })?.providerID {
            return known
        }
        // Nothing known by that id. It may still BE a vendor id — a deep link,
        // or a task that has aged out of the list — so try it as one rather
        // than refusing outright. A digest of ours is excluded by name: it can
        // only ever have come from the branch above.
        guard ArtifactStore.isPlausibleSession(id), !Self.looksLikeOurDigest(id)
        else { return nil }
        return id
    }

    /// 64 lowercase hex characters and nothing else: the shape
    /// `AgentSession.id` emits, and a shape no vendor id surveyed has.
    static func looksLikeOurDigest(_ id: String) -> Bool {
        id.count == 64 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
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
    /// Whose key this is, for the client-side `createdBy` filter that
    /// `listIsCallerScoped: false` makes mandatory. Nil when the gateway will
    /// not say, which is handled by refusing to list rather than by listing
    /// everybody.
    func identity() async throws -> String?
    func tasks(limit: Int) async throws -> [CrobotTask]
    func task(_ id: String) async throws -> CrobotTask
    func prompt(_ id: String, text: String) async throws -> SendOutcome
    func create(repo: String, prompt: String, baseBranch: String?) async throws -> String
    /// The repositories this key may start a task in, and the one to
    /// pre-select. What crobot's own Slack picker is built from.
    func repos() async throws -> (repos: [String], preselect: String?)
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
        // Through `RolloutClock`, which parses BOTH the fractional-second stamp
        // and the plain one. A bare `ISO8601DateFormatter` reads no fractional
        // seconds, and crobot stamps them ("...:31.315Z"), so every crobot
        // agent's `updatedAt` was epoch 0 — which read as harmless until lit
        // rows began ordering by recency (#454) and a 1970 timestamp sorted
        // every crobot task to the very bottom, off the panel. Same defect as
        // the ACP `session/list` stamp, same fix (15 Sep 2026).
        RolloutClock.date(raw) ?? Date(timeIntervalSince1970: 0)
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
