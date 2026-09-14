import Foundation

/// Answering an agent that runs somewhere else.
///
/// The second `DispatchTransport` conformance, beside the tmux one, and the
/// whole point is that **callers do not learn a new verb**. The panel already
/// resolves a target and calls `send`; this makes those words arrive over HTTP
/// instead of as keystrokes, and the card, the earcon and the receipt are
/// unchanged.
///
/// It answers a QUESTION when there is one and sends a MESSAGE when there is
/// not, and that is not a detail: a provider that raised a structured request
/// wants a structured answer, and sending prose at a pending permission is how
/// a typed answer goes nowhere (crobot, `ui-owxd968g5sbf`, 11 Sep).
public struct RemoteDispatchTransport: DispatchTransport {

    public let kind: TransportKind = .remote
    private let registry: AgentProviderRegistry
    /// What the poller last saw. Read rather than re-fetched, because the
    /// panel has already decided who it is answering and a second opinion
    /// here could disagree with the row the user is looking at.
    private let pending: @Sendable (AgentSession.ID) -> PendingRequest?
    private let agent: @Sendable (AgentSession.ID) -> AgentSession?
    public var now: @Sendable () -> Date = { Date() }

    public init(registry: AgentProviderRegistry,
                agent: @escaping @Sendable (AgentSession.ID) -> AgentSession?,
                pending: @escaping @Sendable (AgentSession.ID) -> PendingRequest?) {
        self.registry = registry
        self.agent = agent
        self.pending = pending
    }

    // MARK: - Readiness

    /// What the PROVIDER says, first-hand.
    ///
    /// No process probe and no file tail, because neither exists and neither
    /// would be better evidence than the provider's own statement. The
    /// mapping is deliberately narrow: everything that is not plainly
    /// dispatchable defers rather than guessing.
    public func readiness(for target: DispatchTarget) async -> Readiness {
        guard let session = agent(target.sessionId) else { return .targetGone }
        guard let provider = registry.provider(session.provider) else { return .targetGone }

        // A PROVIDER THAT CANNOT TAKE A REPLY IS NOT "gone", and saying so
        // would be a lie the user acts on: Copilot's agent is perfectly alive
        // and simply has no follow-up endpoint. `.notRegistered` is the
        // existing word for "alive, and injecting here is wrong", which is
        // exactly this.
        guard provider.can.canSend || provider.can.canAnswer else { return .notRegistered }

        switch session.state {
        case .inputRequired, .authRequired:
            // Waiting is the state most in need of an answer, and for a remote
            // agent there is no dialog to accidentally dismiss.
            return .waiting(pending(target.sessionId)?.asked)
        case .working, .submitted:
            // The provider decides whether a mid-turn send lands. If it does
            // not accept one, deferring here is cheaper than a round trip that
            // comes back busy.
            return provider.can.sendWhileWorking ? .ready : .busy
        case .completed, .canceled, .rejected:
            // Finished, and still answerable: sending to a completed session
            // is how a conversation continues. Only `failed` and `unknown`
            // hold back.
            return .ready
        case .failed:
            return .targetGone
        case .unknown:
            // NOBODY CAN SAY. Never dispatch on silence: the reply would go
            // to an agent whose state we lost, and the poller has already
            // recorded why it is quiet.
            return .notRegistered
        }
    }

    // MARK: - Sending

    public func send(text: String, to target: DispatchTarget) async -> DispatchOutcome {
        guard let session = agent(target.sessionId),
              let provider = registry.provider(session.provider) else {
            return .failed(.targetGone)
        }
        let started = now()

        // A QUESTION GETS AN ANSWER, not a message. A provider that raised a
        // structured request wants one back; prose sent at a pending
        // permission is a typed answer that goes nowhere.
        if let request = pending(target.sessionId) {
            guard provider.can.canAnswer else {
                return refusal(provider, verb: "answer a question")
            }
            let outcome: SendOutcome
            do { outcome = try await provider.respond(to: request, with: Response(text)) }
            catch { return .failed(.injectionFailed(String(describing: error))) }
            return result(outcome, provider: provider, verb: "answer", started: started)
        }

        guard provider.can.canSend else {
            return refusal(provider, verb: "take a follow-up message")
        }
        let outcome: SendOutcome
        do { outcome = try await provider.send(text, to: target.sessionId) }
        catch { return .failed(.injectionFailed(String(describing: error))) }
        return result(outcome, provider: provider, verb: "send", started: started)
    }

    /// **`busy` is surfaced, never swallowed.** Cursor refuses a follow-up
    /// while an agent is working, and a user who hears nothing assumes their
    /// words landed. `deferred` is the outcome that already means "not now,
    /// and here is why", so the card has something true to say.
    private func result(_ outcome: SendOutcome, provider: any AgentProvider,
                        verb: String, started: Date) -> DispatchOutcome {
        switch outcome {
        case .accepted:
            // CONFIRMED rather than queued, and the difference is real: the
            // provider's API returned success, which is a receipt. A local
            // send has to watch the screen to know; this one was told.
            return .confirmed(latencyMs: Int(now().timeIntervalSince(started) * 1000))
        case .busy:
            return .deferred(.busy)
        case .unsupported:
            return refusal(provider, verb: verb)
        case .failed(let reason):
            // Carries its reason, both streams (ruling, 11 Sep).
            return .failed(.injectionFailed(reason))
        }
    }

    /// A polite refusal, in words, rather than an obscure failure.
    ///
    /// `notEnrolled` is the existing case for "this target cannot receive
    /// what you are about to send", and its payload is the sentence shown. A
    /// provider without a verb is a fact about that provider, not a fault, and
    /// the user should be told which it is.
    private func refusal(_ provider: any AgentProvider, verb: String) -> DispatchOutcome {
        .failed(.notEnrolled("\(provider.id) cannot \(verb)"))
    }
}
