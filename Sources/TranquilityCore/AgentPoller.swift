import Foundation

/// Keeps a snapshot of every configured provider's agents, off the main
/// thread, so the grid can read one without asking the network.
///
/// **Two tiers, because the calls cost different amounts.** A provider's list
/// is one request for every agent it has; verified liveness and the pending
/// request are one request EACH. So tier one runs on a beat and gets the row
/// set with coarse state, and tier two runs only for the handful of rows tier
/// one says are live or waiting, which in practice is nought to three.
///
/// crobot's own web client polls its list every fifteen seconds, so twenty is
/// neighbourly. A provider that streams is not polled on tier one at all: its
/// `changes()` is the ingress, and this holds the snapshot its events update.
///
/// Modelled on `HubMirror`: same `DispatchSourceTimer` on a utility queue,
/// same coalescing `kick()`, same rule that a test never opens a socket.
public final class AgentPoller: @unchecked Sendable {

    /// How often tier one runs.
    public static let beat: TimeInterval = 20

    private let registry: AgentProviderRegistry
    private let queue = DispatchQueue(label: "agent-poller", qos: .utility)
    private let lock = NSLock()
    private func sync<T>(_ body: () -> T) -> T { lock.withLock(body) }

    private var timer: DispatchSourceTimer?
    private var state = Snapshot()
    private var digests: [String: [AgentSession.ID: String]] = [:]
    private var streams: [String: Task<Void, Never>] = [:]

    /// Every event this poller has produced, for whoever writes spool lines
    /// (#372). Set before `start()`; called off the main thread.
    public var onEvents: (@Sendable ([AgentEvent]) -> Void)?
    /// Diagnostics, with reasons. Never the user's speech.
    public var trace: (@Sendable (String) -> Void)?
    public var now: @Sendable () -> Date = { Date() }
    /// Which config decides a provider is CONFIGURED.
    ///
    /// Injectable for the reason `Prerequisites` learned the hard way on
    /// 13 Sep: a default that reads `~/.claude/hq.json` makes every test's
    /// result depend on what happens to be on the machine running it, and the
    /// divergence only appears once somebody has actually finished the setup
    /// the code exists to support.
    public var registryConfig: URL = HubApp.configPath

    public init(registry: AgentProviderRegistry) {
        self.registry = registry
    }

    private var configured: [any AgentProvider] {
        registry.configured(config: registryConfig)
    }

    // MARK: - The snapshot

    /// What the grid reads. A value, copied out under the lock, so a repaint
    /// never waits on a network call and never sees a half-updated map.
    public struct Snapshot: Sendable {
        public init() {}
        public var agents: [AgentSession] = []
        /// The pending request per agent, for the few that have one.
        public var requests: [AgentSession.ID: PendingRequest] = [:]
        /// **Why a provider is silent, when it is.** Held rather than
        /// discarded: a row whose provider cannot be reached shows its last
        /// state with this beside it, and never turns green on silence.
        public var unreachable: [String: String] = [:]
        /// When each agent was last CONFIRMED by a provider that answered.
        /// The grid shows the age; a stale row is honest, an invented state is
        /// not.
        public var confirmedAt: [AgentSession.ID: Date] = [:]

        public func agent(_ id: AgentSession.ID) -> AgentSession? {
            agents.first { $0.id == id }
        }
    }

    public var snapshot: Snapshot { sync { state } }

    // MARK: - Running

    public func start() {
        stop()
        for provider in configured {
            subscribe(provider)
            // SEED IT. A stream reports what happens NEXT, and the largest gap
            // is the one before it opened: at startup a streaming provider's
            // sessions all already exist, so nothing is "changing" and the grid
            // shows an empty panel beside a server with work on it.
            //
            // Measured 14 Sep on a live `opencode serve` holding 22 sessions:
            // the app polled, subscribed, logged no error, and drew no rows.
            //
            // `mine()` is mandatory for a streaming provider for exactly this
            // reason, and the first draft of this poller required it and then
            // never called it. A2A's rule is the same one: resubscribe must
            // deliver a snapshot first, because a client that only hears
            // changes cannot know the state it started in.
            if provider.changes() != nil { seed(provider) }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: Self.beat)
        t.setEventHandler { [weak self] in self?.tick() }
        sync { timer = t }
        t.resume()
    }

    public func stop() {
        let t: DispatchSourceTimer? = sync { let t = timer; timer = nil; return t }
        t?.cancel()
        let running: [String: Task<Void, Never>] = sync { let s = streams; streams = [:]; return s }
        for (_, task) in running { task.cancel() }
    }

    /// End Agent on a remote row: the provider forgets it, the snapshot drops
    /// it, and the next repaint has no row. Right-click → End Agent on a
    /// remote row did nothing before this (Robert, 15 Sep): the handler
    /// looked for a local pid, found none, and logged "already gone".
    public func end(_ id: AgentSession.ID) async {
        guard let session = snapshot.agent(id),
              let provider = registry.provider(session.provider) else { return }
        await provider.forget(id)
        sync {
            state.agents.removeAll { $0.id == id }
            state.requests.removeValue(forKey: id)
            state.confirmedAt.removeValue(forKey: id)
        }
        trace?("\(session.provider) ended \(id.prefix(8))")
    }

    /// Coalesced, like `HubMirror.kick`: several reasons to refresh inside a
    /// moment are one refresh.
    public func kick() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.tick() }
    }

    /// One list call for a provider whose ingress is a stream, so the rows
    /// exist before anything changes.
    private func seed(_ provider: any AgentProvider) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let fresh = try await provider.mine()
                self.sync {
                    self.state.unreachable.removeValue(forKey: provider.id)
                    self.merge(fresh, from: provider.id)
                    let at = self.now()
                    for session in fresh { self.state.confirmedAt[session.id] = at }
                }
                self.trace?("provider \(provider.id) seeded \(fresh.count) agent(s)")
            } catch {
                // Same rule as a failed poll: silence is recorded with its
                // reason and never read as "there is nothing there".
                self.sync { self.state.unreachable[provider.id] = String(describing: error) }
                self.trace?("provider \(provider.id) could not be seeded: \(error)")
            }
        }
    }

    private func tick() {
        Task { [weak self] in await self?.refresh() }
    }

    // MARK: - Tier one

    /// Every configured provider that does not stream, asked for its list.
    ///
    /// A provider that DOES stream is skipped here: its events already keep
    /// the snapshot current, and polling it as well would double every row's
    /// cost to learn what it just said.
    public func refresh() async {
        for provider in configured {
            guard provider.changes() == nil else { continue }
            await pollOnce(provider)
        }
    }

    /// **A polled agent that just finished says what it did.**
    ///
    /// A streaming provider emits `.said` with the words as they arrive, so
    /// the brief, the summary, the spoken card and the hub page all fill up.
    /// A polled provider (crobot) only yields `.changed` — the poll sees THAT
    /// the state moved, never WHAT was written — so a finished crobot task
    /// reached the panel as a bare "it finished" and a link, not a recap.
    /// Robert: "shouldn't we have summary and hub page and stuff, instead of
    /// always just going to the webpage ... it's not the full experience."
    ///
    /// So on the one transition that has a recap worth hearing — a turn
    /// finishing — the poller fetches the agent's last words and emits them as
    /// `.said`, the same event a streaming turn would. One fetch per finished
    /// turn, and only for a provider that cannot stream. `RemoteSpool` then
    /// drops the now-redundant empty finish line, so the recap speaks once.
    private func withTheirLastWords(_ events: [AgentEvent],
                                    from provider: any AgentProvider) async -> [AgentEvent] {
        var out: [AgentEvent] = []
        out.reserveCapacity(events.count)
        for event in events {
            // Only a fresh, non-failing finish carries a recap worth fetching.
            // A failure already speaks its reason; anything not finishing has
            // no last word to hand over yet.
            guard case .changed(let session) = event.kind,
                  session.state.isFinished, event.previously?.isFinished != true,
                  session.state != .failed, session.state != .rejected,
                  let turns = try? await provider.transcript(event.session),
                  let last = turns.last(where: { $0.role == .agent && !$0.text.isEmpty })
            else { out.append(event); continue }
            // REPLACE the wordless finish with the words. One stop line, not
            // two: the `.said` lights the same green lamp the `.changed` would
            // have, and now it carries a summary and a hub page. A finish with
            // no readable transcript keeps its `.changed` line above, so the
            // lamp still lights — just without a recap, which is the truth.
            var said = event
            said.kind = .said(last)
            out.append(said)
        }
        return out
    }

    func pollOnce(_ provider: any AgentProvider) async {
        let before = sync { digests[provider.id] ?? [:] }
        let outcome = await AgentPoll.refresh(provider, from: before, at: now())

        switch outcome {
        case .unreachable(let reason, let stale):
            // NEVER IDLE. Absence of news is not news: the rows keep their last
            // state, the provider is recorded as unreachable with its reason,
            // and `confirmedAt` stops advancing so the age the grid shows
            // starts telling the truth about how old this is.
            sync {
                state.unreachable[provider.id] = reason
                for id in stale where state.agent(id) != nil {
                    if let index = state.agents.firstIndex(where: { $0.id == id }) {
                        state.agents[index].state = .unknown
                    }
                }
            }
            trace?("provider \(provider.id) unreachable: \(reason)")

        case .polled(let diffed, let next):
            let fresh = (try? await provider.mine()) ?? []
            var events = diffed
            // `previously` is read from the state BEFORE the merge below, which
            // is what still shows the turn as working. Set it first.
            sync {
                for index in events.indices {
                    events[index].previously = state.agent(events[index].session)?.state
                }
            }
            // **The lamp holds blue while we fetch the recap** (ruled 15 Sep).
            // A finished turn is not the user's turn until there is something
            // to hand them, so the last words are fetched HERE, before the
            // finished state is merged. Until this returns the row keeps its
            // working lamp; a cold-sandbox fetch simply keeps it blue a little
            // longer, which is the truth.
            let enriched = await withTheirLastWords(events, from: provider)
            // Now the finished state and the recap land together: the row turns
            // green in the same beat the words become readable, never before.
            sync {
                digests[provider.id] = next
                state.unreachable.removeValue(forKey: provider.id)
                merge(fresh, from: provider.id)
                let at = now()
                for session in fresh { state.confirmedAt[session.id] = at }
            }
            if !enriched.isEmpty { onEvents?(enriched) }
            await refine(fresh, with: provider)
        }
    }

    // MARK: - Tier two

    /// The expensive calls, for the few rows that earn them.
    ///
    /// "Live or waiting" is the filter the issue names, and it is deliberately
    /// narrow: a finished agent has nothing to verify and an unknown one has
    /// nobody to ask. In practice this is nought to three rows, which is the
    /// whole reason the tiers exist.
    func refine(_ agents: [AgentSession], with provider: any AgentProvider) async {
        let worth = agents.filter { $0.state.isBlocked || $0.state == .working }
        for agent in worth.prefix(8) {
            // A THROW and a nil are different answers and must not be merged.
            // `request` returning nil means "it is not asking"; a throw means
            // "I could not find out", and clearing the row's question on the
            // second would drop an amber lamp because the network blinked.
            let answered: PendingRequest??
            do { answered = try await provider.request(agent.id) }
            catch {
                trace?("could not read \(agent.id.prefix(8))'s request: \(error)")
                continue
            }
            sync {
                if let request = answered ?? nil { state.requests[agent.id] = request }
                else { state.requests.removeValue(forKey: agent.id) }
            }
        }
    }

    // MARK: - Streaming providers

    private func subscribe(_ provider: any AgentProvider) {
        guard let stream = provider.changes() else { return }
        let task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                let stamped = self.apply(event)
                self.onEvents?([stamped])
            }
            self?.trace?("provider \(provider.id) stream ended")
            // A DROPPED STREAM IS A GAP TOO. Re-listing on the way out is what
            // turns `mine()` from a formality into the catch-up it was
            // specified as: whatever changed while the connection was down is
            // in the list even though its events are gone for ever.
            self?.seed(provider)
        }
        sync { streams[provider.id] = task }
    }

    /// One event into the snapshot. The stream is the ingress for a provider
    /// that has one, so this is the equivalent of tier one for those.
    ///
    /// Returns the event stamped with what the snapshot knew before it was
    /// applied (`AgentEvent.previously`), for the spool writer.
    @discardableResult
    func apply(_ event: AgentEvent) -> AgentEvent {
        var stamped = event
        sync {
            stamped.previously = state.agent(event.session)?.state
            switch event.kind {
            case .appeared(let session):
                // The one line that answers "did the row reach the grid" from
                // the log. Measured 15 Sep: New Agent started an OpenCode
                // session, the process ran, the card said so, and nothing in
                // the log could say whether the poller had heard of it.
                trace?("\(event.provider) appeared \(session.id.prefix(8)) \(session.state)")
                merge([session], from: event.provider)
                state.confirmedAt[session.id] = event.at
            case .changed(let session):
                if stamped.previously != session.state {
                    trace?("\(event.provider) \(session.id.prefix(8)) \(stamped.previously?.rawValue ?? "new") -> \(session.state.rawValue)")
                }
                merge([session], from: event.provider)
                state.confirmedAt[session.id] = event.at
            case .asks(let request):
                state.requests[event.session] = request
                if let index = state.agents.firstIndex(where: { $0.id == event.session }) {
                    state.agents[index].state = .inputRequired
                }
            case .answered:
                state.requests.removeValue(forKey: event.session)
            case .said:
                state.confirmedAt[event.session] = event.at
            case .failed(let reason):
                trace?("agent \(event.session.prefix(8)) failed: \(reason)")
                if let index = state.agents.firstIndex(where: { $0.id == event.session }) {
                    state.agents[index].state = .failed
                }
            }
        }
        return stamped
    }

    // MARK: -

    /// Replace this provider's agents with what it just reported, and leave
    /// every other provider's alone.
    ///
    /// **An agent missing from one poll is NOT removed**, for the reason
    /// `AgentPoll.events` gives: crobot's list has no creator filter and
    /// several vendors paginate, so absence from one page of one poll is not
    /// evidence that an agent ended. An ending is a state. Rows leave this
    /// snapshot when a provider says they are finished, or when the whole
    /// provider goes away.
    private func merge(_ fresh: [AgentSession], from provider: String) {
        for session in fresh {
            if let index = state.agents.firstIndex(where: { $0.id == session.id }) {
                state.agents[index] = session
            } else {
                state.agents.append(session)
            }
        }
    }
}
