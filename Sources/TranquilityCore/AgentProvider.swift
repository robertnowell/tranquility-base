import Foundation

/// A place agents run, and what this app is allowed to ask of it.
///
/// The seam every cloud provider plugs into. `docs/rulings/ruling-the-provider-seam.md`
/// holds the ten rules that keep it from rotting; the two that shape the
/// signatures below are rule 1 (capabilities, never a version number) and rule 5
/// (every declared capability is read by production code).
///
/// **Providers emit events. They do not answer status questions.** The ingress
/// is `changes()` or `mine()`, and everything else on this protocol is either a
/// detail fetched on demand or something the user did. There is deliberately no
/// `status(of:)`.
///
/// The acceptance test for the whole epic: adding a third provider should be one
/// file plus one entry in the registry, with `AgentProviderConformance` passing
/// unchanged.
public protocol AgentProvider: Sendable {

    /// Stable and human-legible: "crobot", "opencode". Keyed on by
    /// `ProviderConfig`, `Secrets.credential(forProvider:)` and
    /// `Prerequisites.Item.provider`, so it is one vocabulary rather than
    /// three.
    var id: String { get }

    /// What this provider can do. Never assumed uniform, never versioned.
    var can: Capabilities { get }

    // MARK: - Ingress: two shapes, one required

    /// The provider's own stream, or **nil meaning "poll me instead"**.
    ///
    /// This return type *is* the push-or-poll capability declaration. There is
    /// no `supportsStreaming` flag beside it, and that is rule 5 satisfied by
    /// construction rather than by a test: a flag can go dead while nothing
    /// reads it, and this cannot, because production code must branch on it to
    /// receive anything at all.
    ///
    /// Push or poll is per provider, not per deployment. A provider returns a
    /// stream if it has one, which is how the local hook path keeps its latency
    /// without a local web server anywhere in the design.
    func changes() -> AsyncStream<AgentEvent>?

    /// Every agent of mine, as the provider currently sees them.
    ///
    /// **Mandatory even for a streaming provider**, because it is the catch-up
    /// after a dropped stream. A2A's precedent is worth copying exactly here:
    /// `tasks/resubscribe` MUST deliver a full snapshot as its first event, so
    /// a client that was disconnected across a transition into a blocked state
    /// cannot stay wrong about it. A stream alone has no answer to "what did I
    /// miss", and every one of these connections will drop.
    ///
    /// When `Capabilities.listIsCallerScoped` is false this returns everybody's
    /// agents and the caller must filter, which crobot forces.
    func mine() async throws -> [AgentSession]

    // MARK: - Detail, on demand

    /// One agent, freshly. Used when a row is opened rather than on every poll.
    func refine(_ id: AgentSession.ID) async throws -> AgentSession

    /// The pending request for an agent, or nil while it has none. Separate
    /// from the state by design: see `PendingRequest`.
    func request(_ id: AgentSession.ID) async throws -> PendingRequest?

    func transcript(_ id: AgentSession.ID) async throws -> [Turn]

    // MARK: - Egress: things a person did

    /// Never returns a `Bool`. See `SendOutcome`.
    ///
    /// A provider whose `can.canSend` is false must return `.unsupported`
    /// rather than throwing. Refusing is an answer; throwing is a failure, and
    /// the panel says different things about them.
    func send(_ text: String, to id: AgentSession.ID) async throws -> SendOutcome

    /// Answer a blocking request structurally, so the provider is not asked to
    /// parse a sentence back into the choice it offered. Gated by
    /// `can.canAnswer`; a provider without it returns `.unsupported`.
    func respond(to request: PendingRequest, with response: Response) async throws -> SendOutcome

    /// Gated by `can.canStart`. Throws rather than returning an outcome,
    /// because there is no id to hand back when it did not happen.
    func start(_ brief: Brief) async throws -> AgentSession.ID

    /// Stop an agent. Gated by `can.canCancel`.
    ///
    /// Added 13 Sep, because `canCancel` shipped in the first draft with no
    /// method to act on it. A capability that can never be consulted is how the
    /// previous capability struct reached four dead fields, and declaring one
    /// on day one of a seam written to prevent exactly that would have been a
    /// poor start.
    func cancel(_ id: AgentSession.ID) async throws -> SendOutcome

    /// End the agent as far as this app is concerned: after this it is not
    /// listed, not adopted at the next launch, and its row is gone. What the
    /// vendor does with the session is the vendor's business (OpenCode keeps
    /// it in its own store; `opencode --session` still opens it). Default is
    /// nothing, for a provider whose list this app cannot edit.
    func forget(_ id: AgentSession.ID) async

    /// Where a person looks at this agent in the provider's own interface, or
    /// nil for a provider with no such place (a local server has none).
    func url(for id: AgentSession.ID) -> URL?
}

/// The providers this machine can drive.
///
/// One entry per provider, and adding one is the whole of "add a provider"
/// once the adapter exists. Deliberately an instance rather than a global
/// singleton so a test and the app can hold different sets, which is the same
/// reasoning `Coordinator` gives for injecting everything it uses.
public struct AgentProviderRegistry: Sendable {
    public let providers: [any AgentProvider]
    /// Providers this app spawns itself, which need no address: an installed
    /// binary is their address. Named here rather than as a capability on the
    /// provider, because a capability nothing reads is rule 5's failure and
    /// this set is read in exactly one place, `configured()`.
    public let spawnable: Set<String>

    public init(_ providers: [any AgentProvider], spawnable: Set<String> = []) {
        self.providers = providers
        self.spawnable = spawnable
    }

    public func provider(_ id: String) -> (any AgentProvider)? {
        providers.first { $0.id == id }
    }

    /// Only the providers this machine has an address for. A registry entry is
    /// what the app CAN drive; a configured base URL is what it currently
    /// does, and conflating them puts a row on the panel for a service nobody
    /// here has heard of.
    public func configured(config: URL = HubApp.configPath) -> [any AgentProvider] {
        let addressed = Set(ProviderConfig.configured(config: config)).union(spawnable)
        return providers.filter { addressed.contains($0.id) }
    }
}


extension AgentProvider {
    public func forget(_ id: AgentSession.ID) async {}
}
