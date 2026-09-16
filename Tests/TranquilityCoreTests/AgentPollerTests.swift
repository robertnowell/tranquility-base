import XCTest
@testable import TranquilityCore

/// The poller's whole job is to be honest about what it does not know.
/// Everything below is that rule from one angle or another.
final class AgentPollerTests: XCTestCase {

    /// A provider whose answers the test controls, including failing on demand.
    final class Controlled: AgentProvider, @unchecked Sendable {
        let id: String
        var can = Capabilities(canSend: true, canAnswer: true, listIsCallerScoped: true)
        var sessions: [AgentSession] = []
        var pending: [AgentSession.ID: PendingRequest] = [:]
        var failList = false
        var failRequest = false
        var stream: [AgentEvent]?
        private(set) var requestCalls: [AgentSession.ID] = []

        init(id: String) { self.id = id }

        struct Down: Error, CustomStringConvertible { var description: String { "the wire is down" } }

        /// `holdOpen` keeps the stream alive after its events, which matters
        /// more than it looks: a stream that FINISHES triggers the
        /// stream-ended seed, so a test using one cannot tell the start-time
        /// seed from the reconnect seed. The first version of the seeding test
        /// passed with the fix removed for exactly that reason.
        var holdOpen = false
        func changes() -> AsyncStream<AgentEvent>? {
            guard let stream else { return nil }
            let hold = holdOpen
            return AsyncStream { c in
                for e in stream { c.yield(e) }
                if !hold { c.finish() }
            }
        }
        func mine() async throws -> [AgentSession] {
            if failList { throw Down() }
            return sessions
        }
        func refine(_ id: AgentSession.ID) async throws -> AgentSession {
            guard let hit = sessions.first(where: { $0.id == id }) else { throw Down() }
            return hit
        }
        func request(_ id: AgentSession.ID) async throws -> PendingRequest? {
            requestCalls.append(id)
            if failRequest { throw Down() }
            return pending[id]
        }
        var transcripts: [AgentSession.ID: [Turn]] = [:]
        func transcript(_ id: AgentSession.ID) async throws -> [Turn] { transcripts[id] ?? [] }
        func send(_ text: String, to id: AgentSession.ID) async throws -> SendOutcome { .accepted }
        func respond(to r: PendingRequest, with response: Response) async throws -> SendOutcome {
            .accepted
        }
        func start(_ brief: Brief) async throws -> AgentSession.ID { "x" }
        func cancel(_ id: AgentSession.ID) async throws -> SendOutcome { .unsupported }
        func url(for id: AgentSession.ID) -> URL? { nil }
    }

    private func session(_ raw: String, _ provider: String,
                         _ state: AgentSessionState = .working) -> AgentSession {
        AgentSession.of(raw, provider: provider, title: raw, state: state)
    }

    /// The registry filters to CONFIGURED providers, so the tests supply a
    /// config naming them rather than depending on this machine's.
    private func poller(_ providers: [any AgentProvider]) throws -> (AgentPoller, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("poller-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = dir.appendingPathComponent("hq.json")
        let entries = providers.map { "\"\($0.id)\":{\"base_url\":\"http://127.0.0.1:1\"}" }
        try "{\"providers\":{\(entries.joined(separator: ","))}}"
            .write(to: config, atomically: true, encoding: .utf8)
        return (AgentPoller(registry: AgentProviderRegistry(providers)), config)
    }

    // MARK: - The rule that keeps it honest

    /// **A failed poll is UNKNOWN, never idle.** Absence of news is not news,
    /// and this is the single easiest way to lie to the user.
    func testAFailedPollLeavesTheRowUnknownAndNeverIdle() async throws {
        let p = Controlled(id: "a")
        p.sessions = [session("s1", "a", .working)]
        let (poller, config) = try poller([p])
        poller.registryConfig = config

        await poller.pollOnce(p)
        XCTAssertEqual(poller.snapshot.agent(session("s1", "a").id)?.state, .working)

        p.failList = true
        await poller.pollOnce(p)

        let after = poller.snapshot
        XCTAssertEqual(after.agent(session("s1", "a").id)?.state, .unknown,
                       "a poll that failed must not leave a stale working lamp either")
        XCTAssertNotNil(after.unreachable["a"], "the provider's silence has a reason recorded")
        XCTAssertEqual(
            AgentPresentation.bucket(state: .unknown, hasPendingRequest: false),
            .problem, "and it renders amber, not as a calm agent")
    }

    /// The row keeps its age so staleness is visible rather than invented.
    func testConfirmedAtStopsAdvancingWhileAProviderIsSilent() async throws {
        let p = Controlled(id: "a")
        p.sessions = [session("s1", "a")]
        let (poller, config) = try poller([p])
        poller.registryConfig = config
        let clock = Locked(Date(timeIntervalSince1970: 1_000))
        poller.now = { clock.value }

        await poller.pollOnce(p)
        let first = poller.snapshot.confirmedAt[session("s1", "a").id]
        XCTAssertEqual(first?.timeIntervalSince1970, 1_000)

        clock.value = Date(timeIntervalSince1970: 2_000)
        p.failList = true
        await poller.pollOnce(p)

        XCTAssertEqual(poller.snapshot.confirmedAt[session("s1", "a").id]?.timeIntervalSince1970,
                       1_000, "a failed poll must not claim to have confirmed anything")
    }

    /// crobot's list has no creator filter and vendors paginate, so absence
    /// from one poll is not evidence an agent ended. An ending is a state.
    func testAnAgentMissingFromOnePollIsNotRemoved() async throws {
        let p = Controlled(id: "a")
        p.sessions = [session("s1", "a"), session("s2", "a")]
        let (poller, config) = try poller([p])
        poller.registryConfig = config
        await poller.pollOnce(p)
        XCTAssertEqual(poller.snapshot.agents.count, 2)

        p.sessions = [session("s1", "a")]
        await poller.pollOnce(p)
        XCTAssertEqual(poller.snapshot.agents.count, 2, "a short page invented an ending")
    }

    // MARK: - Two tiers

    /// Tier two costs one call per row, so it runs only for the rows that
    /// earn it: live or waiting, which in practice is nought to three.
    func testTierTwoAsksOnlyAboutLiveOrWaitingRows() async throws {
        let p = Controlled(id: "a")
        p.sessions = [
            session("working", "a", .working),
            session("blocked", "a", .inputRequired),
            session("done", "a", .completed),
            session("silent", "a", .unknown),
        ]
        let (poller, config) = try poller([p])
        poller.registryConfig = config
        await poller.pollOnce(p)

        let asked = Set(p.requestCalls)
        XCTAssertTrue(asked.contains(session("working", "a").id))
        XCTAssertTrue(asked.contains(session("blocked", "a").id))
        XCTAssertFalse(asked.contains(session("done", "a").id),
                       "a finished agent has nothing to verify")
        XCTAssertFalse(asked.contains(session("silent", "a").id),
                       "an unknown agent has nobody to ask")
    }

    /// A throw and a nil are different answers. Clearing a question because
    /// the network blinked drops an amber lamp.
    func testAFailedRequestReadDoesNotClearAKnownQuestion() async throws {
        let p = Controlled(id: "a")
        let blocked = session("s1", "a", .inputRequired)
        p.sessions = [blocked]
        p.pending = [blocked.id: PendingRequest(id: "q", session: blocked.id, asked: "which?")]
        let (poller, config) = try poller([p])
        poller.registryConfig = config

        await poller.pollOnce(p)
        XCTAssertNotNil(poller.snapshot.requests[blocked.id])

        p.failRequest = true
        await poller.pollOnce(p)
        XCTAssertNotNil(poller.snapshot.requests[blocked.id],
                        "the question survived a failed read, as it must")
    }

    /// A provider that streams is its own ingress. Polling it as well doubles
    /// every row's cost to learn what it just said.
    func testAStreamingProviderIsNotPolledOnTierOne() async throws {
        let streamer = Controlled(id: "a")
        streamer.stream = []
        streamer.sessions = [session("s1", "a")]
        let polled = Controlled(id: "b")
        polled.sessions = [session("s2", "b")]
        let (poller, config) = try poller([streamer, polled])
        poller.registryConfig = config

        await poller.refresh()
        XCTAssertNil(poller.snapshot.agent(session("s1", "a").id),
                     "the streaming provider was polled anyway")
        XCTAssertNotNil(poller.snapshot.agent(session("s2", "b").id))
    }

    // MARK: - A stream has to be seeded

    /// **A stream reports what happens NEXT.** At startup a streaming
    /// provider's sessions all already exist, so nothing is changing and the
    /// grid would show an empty panel beside a server with work on it.
    ///
    /// Measured 14 Sep on a live `opencode serve` holding 22 sessions: the app
    /// polled, subscribed, logged no error and drew no rows. `mine()` is
    /// mandatory for a streaming provider for exactly this reason, and the
    /// first poller required it and then never called it.
    func testAStreamingProviderIsSeededSoItsRowsExistBeforeAnythingChanges() async throws {
        let p = Controlled(id: "a")
        p.stream = []                       // declares a stream, emits nothing
        p.holdOpen = true                   // and never ends, so only the start-time seed can fire
        p.sessions = [session("s1", "a"), session("s2", "a")]
        let (poller, config) = try poller([p])
        poller.registryConfig = config

        poller.start()
        defer { poller.stop() }

        // The seed is a Task; give it a moment to land.
        for _ in 0..<40 where poller.snapshot.agents.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(poller.snapshot.agents.count, 2,
                       "a streaming provider drew no rows until something moved")
    }

    /// And a failed seed is silence WITH a reason, never "there is nothing
    /// there" - the same rule a failed poll follows.
    func testAFailedSeedIsRecordedRatherThanReadAsEmpty() async throws {
        let p = Controlled(id: "a")
        p.stream = []
        p.holdOpen = true
        p.failList = true
        let (poller, config) = try poller([p])
        poller.registryConfig = config

        poller.start()
        defer { poller.stop() }
        for _ in 0..<40 where poller.snapshot.unreachable["a"] == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(poller.snapshot.unreachable["a"])
        XCTAssertTrue(poller.snapshot.agents.isEmpty)
    }

    // MARK: - Events into the snapshot

    func testAnAskEventLightsTheRowAndCarriesItsQuestion() {
        let (poller, _) = try! poller([])
        let s = session("s1", "a")
        poller.apply(AgentEvent(provider: "a", session: s.id, kind: .appeared(s)))
        let request = PendingRequest(id: "q", session: s.id, asked: "Run it?")
        poller.apply(AgentEvent(provider: "a", session: s.id, kind: .asks(request)))

        XCTAssertEqual(poller.snapshot.agent(s.id)?.state, .inputRequired)
        XCTAssertEqual(poller.snapshot.requests[s.id]?.id, "q")
    }

    /// Somebody may answer in the provider's own interface. Without this the
    /// row holds an amber lamp for ever.
    func testAnAnsweredEventClearsTheQuestion() {
        let (poller, _) = try! poller([])
        let s = session("s1", "a")
        poller.apply(AgentEvent(provider: "a", session: s.id, kind: .appeared(s)))
        poller.apply(AgentEvent(provider: "a", session: s.id,
                                kind: .asks(PendingRequest(id: "q", session: s.id, asked: "?"))))
        poller.apply(AgentEvent(provider: "a", session: s.id, kind: .answered(requestId: "q")))
        XCTAssertNil(poller.snapshot.requests[s.id])
    }

    func testAFailureEventMarksTheRowFailedWithItsReasonTraced() {
        let (poller, _) = try! poller([])
        let s = session("s1", "a")
        let reasons = Locked<[String]>([])
        poller.trace = { reasons.value.append($0) }
        poller.apply(AgentEvent(provider: "a", session: s.id, kind: .appeared(s)))
        poller.apply(AgentEvent(provider: "a", session: s.id,
                                kind: .failed(reason: "the sandbox died")))
        XCTAssertEqual(poller.snapshot.agent(s.id)?.state, .failed)
        XCTAssertTrue(reasons.value.contains { $0.contains("the sandbox died") },
                      "a failure must carry its reason")
    }

    /// One provider's trouble is not another's.
    func testOneProvidersSilenceDoesNotTouchAnothersRows() async throws {
        let a = Controlled(id: "a"); a.sessions = [session("s1", "a", .working)]
        let b = Controlled(id: "b"); b.sessions = [session("s2", "b", .working)]
        let (poller, config) = try poller([a, b])
        poller.registryConfig = config
        await poller.refresh()

        a.failList = true
        await poller.refresh()

        XCTAssertEqual(poller.snapshot.agent(session("s1", "a").id)?.state, .unknown)
        XCTAssertEqual(poller.snapshot.agent(session("s2", "b").id)?.state, .working)
        XCTAssertNil(poller.snapshot.unreachable["b"])
    }
}

/// A box so a test can move a clock the poller reads from another thread.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentEvent] = []
    func add(_ e: [AgentEvent]) { lock.lock(); events += e; lock.unlock() }
    var all: [AgentEvent] { lock.lock(); defer { lock.unlock() }; return events }
}

extension AgentPollerTests {

    /// **A polled agent that finishes says what it did** (ruled 15 Sep 2026).
    /// A streaming provider emits `.said`; a polled one only yields `.changed`,
    /// so a finished crobot task reached the panel with no words to summarize.
    /// On the finish transition the poller now fetches the last turn and emits
    /// it as `.said`, the same event a streaming turn would.
    func testAPolledFinishEmitsTheLastTurnAsSaid() async throws {
        let p = Controlled(id: "a")
        p.sessions = [session("s1", "a", .working)]
        let (poller, config) = try poller([p])
        poller.registryConfig = config

        let sink = EventSink()
        poller.onEvents = { evs in sink.add(evs) }

        await poller.pollOnce(p)                       // first sight: working
        let id = session("s1", "a").id
        p.sessions = [session("s1", "a", .completed)]  // the turn ends
        p.transcripts[id] = [Turn(id: "t", at: Date(), role: .agent,
                                  text: "Opened the PR and left the tests green.")]
        await poller.pollOnce(p)

        let said = sink.all.compactMap { event -> Turn? in
            if case .said(let turn) = event.kind { return turn }
            return nil
        }
        XCTAssertEqual(said.last?.text, "Opened the PR and left the tests green.",
                       "the finished agent's own words must reach the pipeline")
        // Exactly one stop-worthy event for the finish: the .said REPLACED the
        // wordless .changed, it did not add a second card.
        let finishEvents = sink.all.filter { event in
            guard event.session == id else { return false }
            if case .said = event.kind { return true }
            if case .changed(let sess) = event.kind { return sess.state.isFinished }
            return false
        }
        XCTAssertEqual(finishEvents.count, 1, "a finish must be one event, not a bare line plus a recap")
    }

    /// **The lamp holds blue until the recap is ready.** A finished turn is not
    /// the user's turn until there is something to hand them, so the finished
    /// state is not merged until the words are fetched. A slow transcript keeps
    /// the row working, not prematurely green.
    func testTheRowStaysWorkingWhileTheRecapIsFetched() async throws {
        let p = Controlled(id: "a")
        p.sessions = [session("s1", "a", .working)]
        let (poller, config) = try poller([p])
        poller.registryConfig = config
        await poller.pollOnce(p)

        let id = session("s1", "a").id
        p.sessions = [session("s1", "a", .completed)]
        // No transcript yet — the fetch returns nothing this tick, but the
        // point is the ORDER: state is read for `previously` before the merge,
        // so the row was working right up to the merge, never green-without-words.
        p.transcripts[id] = [Turn(id: "t", at: Date(), role: .agent, text: "done")]
        await poller.pollOnce(p)

        // After the tick the row is finished (green-eligible) AND its words are
        // out, so the two are never seen apart.
        XCTAssertEqual(poller.snapshot.agent(id)?.state, .completed)
    }
}
