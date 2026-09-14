import Foundation
@testable import TranquilityCore

// Two stub providers, and they are DELIBERATELY DIFFERENT IN SHAPE.
//
// The point of building two at once is that every signature on `AgentProvider`
// is negotiated by both from the start. If crobot were written first and the
// second provider retrofitted, the interface would be shaped by crobot and the
// mismatch found late, which is the exact failure this design exists to avoid.
//
// An earlier draft used crobot and local OpenCode as the two. Both are request
// and response over HTTP, so the negotiation would not have exercised the half
// that matters. So: one polled and one streaming, the second standing in for
// the ACP client (#386), with a blocking permission request in its event
// stream. If the streaming stub cannot express that without changing the
// protocol, the protocol is wrong, and learning it in a fixture costs an hour
// rather than a rewrite after #368 is built on it.
//
// Fixtures, in Tests, never in Sources: a fake provider that ships is a
// provider somebody eventually configures.

// MARK: - Polled

/// Stands in for crobot: REST, no stream, a list endpoint that is not caller
/// scoped, and a pending request that has to be fetched separately from the
/// state.
struct PolledStub: AgentProvider, Sendable {
    let id = "polled-stub"
    var can = Capabilities(canStart: true, canSend: true, canAnswer: false,
                           canCancel: true, sendWhileWorking: false,
                           listIsCallerScoped: false, carriesPullRequest: true)

    /// Fixtures, settable per test.
    var sessions: [AgentSession] = [
        AgentSession(id: "8f14e45f-ceea-467a-9eef-2b9c1b2dc9f0", provider: "polled-stub",
                     title: "port the importer", state: .working,
                     updatedAt: Date(timeIntervalSince1970: 1_757_000_000),
                     repository: "acme/importer"),
        AgentSession(id: "c4ca4238-a0b9-4382-8dcc-509a6f75849b", provider: "polled-stub",
                     title: "raise the timeout", state: .inputRequired,
                     updatedAt: Date(timeIntervalSince1970: 1_757_000_100),
                     repository: "acme/api"),
    ]
    var pending: PendingRequest? = PendingRequest(
        id: "req-1", session: "c4ca4238-a0b9-4382-8dcc-509a6f75849b",
        asked: "The migration drops a column. Run it?")
    var sendResult: SendOutcome = .accepted

    /// nil: poll me instead. This IS the capability declaration.
    func changes() -> AsyncStream<AgentEvent>? { nil }

    func mine() async throws -> [AgentSession] { sessions }

    func refine(_ id: AgentSession.ID) async throws -> AgentSession {
        guard let hit = sessions.first(where: { $0.id == id }) else {
            throw StubError.noSuchSession
        }
        return hit
    }

    func request(_ id: AgentSession.ID) async throws -> PendingRequest? {
        pending?.session == id ? pending : nil
    }

    func transcript(_ id: AgentSession.ID) async throws -> [Turn] {
        [Turn(id: "t1", at: Date(timeIntervalSince1970: 1_757_000_000),
              role: .agent, text: "Reading the schema.")]
    }

    func send(_ text: String, to id: AgentSession.ID) async throws -> SendOutcome {
        guard can.canSend else { return .unsupported }
        // The Cursor shape: 409 while the agent is working.
        if !can.sendWhileWorking,
           sessions.first(where: { $0.id == id })?.state == .working { return .busy }
        return sendResult
    }

    /// REFUSES rather than throws, which is the rule: a capability that is
    /// false is an answer the panel can say out loud, and a throw is a failure
    /// it would have to apologise for.
    func respond(to request: PendingRequest, with response: Response) async throws -> SendOutcome {
        can.canAnswer ? .accepted : .unsupported
    }

    func start(_ brief: Brief) async throws -> AgentSession.ID {
        guard can.canStart else { throw StubError.unsupported }
        return AgentSession.id("started-\(brief.prompt.count)", provider: id)
    }

    func cancel(_ id: AgentSession.ID) async throws -> SendOutcome {
        can.canCancel ? .accepted : .unsupported
    }

    func url(for id: AgentSession.ID) -> URL? {
        URL(string: "https://polled.example.test/tasks/\(id)")
    }

    enum StubError: Error { case noSuchSession, unsupported }
}

// MARK: - Streaming

/// Stands in for the ACP client: a live stream carrying a **blocking
/// permission request**, structural answers, and a snapshot on demand for the
/// catch-up after the stream drops.
struct StreamingStub: AgentProvider, Sendable {
    let id = "streaming-stub"
    var can = Capabilities(canStart: true, canSend: true, canAnswer: true,
                           canCancel: true, sendWhileWorking: true,
                           listIsCallerScoped: true, carriesPullRequest: false)

    static let session = AgentSession(
        id: "45c48cce-2e2d-4fa8-8aec-0eb4779d1ba9", provider: "streaming-stub",
        title: "tidy the fixtures", state: .working,
        updatedAt: Date(timeIntervalSince1970: 1_757_000_200))

    /// The blocking request, in ACP's own permission vocabulary, which is the
    /// best off-the-shelf one found anywhere in the survey.
    static let permission = PendingRequest(
        id: "perm-1", session: session.id,
        asked: "Run `rm -rf build/`?",
        options: [
            .init(id: "once", label: "Allow once", kind: .allowOnce),
            .init(id: "always", label: "Always allow", kind: .allowAlways),
            .init(id: "no", label: "Reject", kind: .rejectOnce),
        ])

    /// The whole point of this stub: a blocking inbound request must be
    /// expressible as an EVENT, not only as something a poller discovers by
    /// asking. `AgentEvent.Kind.asks` is what that negotiation produced.
    func changes() -> AsyncStream<AgentEvent>? {
        AsyncStream { continuation in
            let s = Self.session
            continuation.yield(AgentEvent(provider: id, session: s.id,
                                          at: s.updatedAt, kind: .appeared(s)))
            continuation.yield(AgentEvent(
                provider: id, session: s.id, at: s.updatedAt,
                kind: .said(Turn(id: "t1", at: s.updatedAt, role: .agent,
                                 text: "Cleaning up."))))
            continuation.yield(AgentEvent(provider: id, session: s.id,
                                          at: s.updatedAt, kind: .asks(Self.permission)))
            continuation.finish()
        }
    }

    /// Mandatory even here: the catch-up after a dropped stream, carrying the
    /// full state rather than a delta, so a client that missed the transition
    /// into `inputRequired` cannot stay wrong about it.
    func mine() async throws -> [AgentSession] {
        var blocked = Self.session
        blocked.state = .inputRequired
        return [blocked]
    }

    func refine(_ id: AgentSession.ID) async throws -> AgentSession {
        guard let hit = try await mine().first(where: { $0.id == id }) else {
            throw PolledStub.StubError.noSuchSession
        }
        return hit
    }

    func request(_ id: AgentSession.ID) async throws -> PendingRequest? {
        id == Self.session.id ? Self.permission : nil
    }

    func transcript(_ id: AgentSession.ID) async throws -> [Turn] {
        [Turn(id: "t1", at: Self.session.updatedAt, role: .agent, text: "Cleaning up.")]
    }

    func send(_ text: String, to id: AgentSession.ID) async throws -> SendOutcome {
        can.canSend ? .accepted : .unsupported
    }

    func respond(to request: PendingRequest, with response: Response) async throws -> SendOutcome {
        guard can.canAnswer else { return .unsupported }
        // Structural: the answer must name an option the request offered, so
        // the provider is never asked to parse a sentence back into a choice.
        if let chosen = response.answers.first?.first,
           let offered = request.questions.first?.options, !offered.isEmpty,
           !offered.contains(where: { $0.id == chosen }) {
            return .failed(reason: "no such option: \(chosen)")
        }
        return .accepted
    }

    func start(_ brief: Brief) async throws -> AgentSession.ID {
        AgentSession.id("stream-\(brief.prompt.count)", provider: id)
    }

    func cancel(_ id: AgentSession.ID) async throws -> SendOutcome {
        can.canCancel ? .accepted : .unsupported
    }

    /// A local server has no page to open, and nil is the honest answer.
    func url(for id: AgentSession.ID) -> URL? { nil }
}

// MARK: - Minimal

/// Stands in for GitHub Copilot's coding agent, which is not a degenerate case
/// invented to pad the suite: it genuinely has **no follow-up endpoint at all**.
/// You comment on the draft pull request, and the pull request is the
/// checkpoint. There is no message verb to call.
///
/// It exists here because the conformance suite's refusal branches are most of
/// what it checks, and a suite where every provider can do everything proves
/// nothing about refusal. `testTheStubsBetweenThemExerciseBothSidesOfEveryCapability`
/// is what found that gap, with three stubs that all declared `canSend`.
struct MinimalStub: AgentProvider, Sendable {
    let id = "minimal-stub"
    /// Everything false but the one thing it does: produce a pull request.
    var can = Capabilities(canStart: true, canSend: false, canAnswer: false,
                           canCancel: false, sendWhileWorking: false,
                           listIsCallerScoped: true, carriesPullRequest: true)

    static let session = AgentSession(
        id: "6512bd43-d9ca-4e6e-a1b0-8d35d6b5e7c0", provider: "minimal-stub",
        title: "open a PR and wait", state: .working,
        updatedAt: Date(timeIntervalSince1970: 1_757_000_400),
        repository: "acme/site",
        pullRequest: URL(string: "https://github.com/acme/site/pull/4"))

    func changes() -> AsyncStream<AgentEvent>? { nil }
    func mine() async throws -> [AgentSession] { [Self.session] }
    func refine(_ id: AgentSession.ID) async throws -> AgentSession { Self.session }
    /// Nothing to fetch: this provider never blocks on a question, it blocks on
    /// a review, which is a pull request rather than a prompt.
    func request(_ id: AgentSession.ID) async throws -> PendingRequest? { nil }
    func transcript(_ id: AgentSession.ID) async throws -> [Turn] { [] }

    /// REFUSES. There is no endpoint to call, and `.unsupported` is a sentence
    /// the panel can say out loud. Throwing would make the panel apologise for
    /// a failure that did not happen.
    func send(_ text: String, to id: AgentSession.ID) async throws -> SendOutcome { .unsupported }
    func respond(to request: PendingRequest, with response: Response) async throws -> SendOutcome {
        .unsupported
    }
    func start(_ brief: Brief) async throws -> AgentSession.ID {
        AgentSession.id("minimal-\(brief.prompt.count)", provider: id)
    }

    /// Refuses, like everything else it cannot do. Copilot's answer to "stop
    /// that" is to close the pull request, which is not this verb.
    func cancel(_ id: AgentSession.ID) async throws -> SendOutcome { .unsupported }
    func url(for id: AgentSession.ID) -> URL? {
        URL(string: "https://github.com/acme/site/pull/4")
    }
}
