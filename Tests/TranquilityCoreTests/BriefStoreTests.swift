import XCTest
@testable import TranquilityCore

/// v6: briefs are durable. The in-memory PreparedSummaries used to be the only
/// home of the card fields, so a restart produced depth-1 amnesia — the store
/// now writes a `brief` row on every successful summary and the announce path
/// reads through to it when the memory is gone.
final class BriefStoreTests: XCTestCase {
    var tmpDir: URL!
    var store: QueueStore!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-brief-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = try QueueStore(url: tmpDir.appendingPathComponent("queue.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Doubles

    /// Writes every card field, so depth-1 has something to say.
    final class CountingCardSummary: SummaryProvider, @unchecked Sendable {
        let name = "counting-card"; let isConfigured = true
        var calls = 0
        func brief(for request: SummaryRequest) async throws -> SessionBrief {
            calls += 1
            return SessionBrief(
                topic: "promotions copy edit",
                goal: "ship the Klaviyo export",
                happened: "tests pass",
                nextStep: "run the migration",
                question: "Proceed?",
                risk: "migration drops a legacy table",
                recap: "promotions: export pipeline green.",
                proposal: "Run the migration next. Proceed?")
        }
    }

    final class SilentSpeech: SpeechProvider, @unchecked Sendable {
        let name = "silent"; let isConfigured = true
        var isSpeaking = false
        var spoken: [String] = []
        func speak(_ text: SanitizedSpokenText, onWord: (@Sendable (Range<Int>) -> Void)?) async throws {
            spoken.append(text.text)
        }
        func stop() {}
    }

    final class NoopTransport: DispatchTransport, @unchecked Sendable {
        let kind = TransportKind.terminalApp
        func readiness(for target: DispatchTarget) async -> Readiness { .ready }
        func send(text: String, to target: DispatchTarget) async -> DispatchOutcome {
            .confirmed(latencyMs: 1)
        }
    }

    struct FakeAgents: ClaudeAgentsReading {
        func sessions() -> [LiveSession]? {
            [LiveSession(pid: 1, sessionId: "sess-1", cwd: "/tmp/promotions",
                         status: "idle", name: "promotions", waitingFor: nil)]
        }
    }

    private func makeCoordinator(
        store: QueueStore, provider: any SummaryProvider,
        speech: SilentSpeech = SilentSpeech()
    ) -> Coordinator {
        Coordinator(
            store: store,
            summarizer: SummarizerChain(providers: [provider]),
            speech: SpeechChain(preferred: speech, fallback: speech),
            gate: InterruptGate(minimumIdleSeconds: 0, signals: .quiescent),
            transport: NoopTransport(),
            enrolment: EnrolmentRegistry(url: tmpDir.appendingPathComponent("enrolled.json")),
            agents: FakeAgents(),
            recovery: RecoveryChain(providers: [], maxAttemptsPerProvider: 1, backoff: [0]))
    }

    private func append(message: String = "Export finished. Klaviyo synced.") throws {
        _ = try store.insert(event: QueuedEvent(
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000), hookEvent: .stop,
            sessionId: "sess-1", promptId: UUID().uuidString, cwd: "/tmp/promotions",
            lastAssistantMessage: message, tty: "ttys001"))
    }

    /// Reopen the database as a brand-new process would — nothing in memory.
    private func restartedStore() throws -> QueueStore {
        try QueueStore(url: tmpDir.appendingPathComponent("queue.sqlite"))
    }

    // MARK: - Write on generate

    func testGeneratingASummaryWritesABriefRow() async throws {
        let coordinator = makeCoordinator(store: store, provider: CountingCardSummary())
        try append()
        guard case .spoke(let announcement) = try await coordinator.announceNext() else {
            return XCTFail("expected an announcement")
        }

        let stored = try XCTUnwrap(store.storedBrief(
            sessionId: "sess-1", eventRowid: announcement.event.latestId))
        XCTAssertEqual(stored.topic, "promotions copy edit")
        XCTAssertEqual(stored.goal, "ship the Klaviyo export")
        XCTAssertEqual(stored.risk, "migration drops a legacy table")
        XCTAssertEqual(stored.recap, "promotions: export pipeline green.")
        XCTAssertEqual(stored.provider, "counting-card")
    }

    /// The failure floors are not persisted — same "successful summary" rule as
    /// callsign minting, so a restart re-summarizes those exactly as before.
    func testFailureFloorBriefsAreNotPersisted() async throws {
        let coordinator = makeCoordinator(store: store, provider: CountingCardSummary())
        try append(message: "   ")  // empty source -> provider "empty-source"
        guard case .spoke(let announcement) = try await coordinator.announceNext() else {
            return XCTFail("expected the deterministic floor to speak")
        }
        XCTAssertNil(try store.storedBrief(
            sessionId: "sess-1", eventRowid: announcement.event.latestId))
    }

    // MARK: - Read after "restart"

    func testStoredBriefSurvivesAFreshStoreInstance() throws {
        try store.saveBrief(
            SessionBrief(topic: "voice dispatch store", goal: "persist the argument IR",
                         happened: "migration landed", nextStep: "wire read-through",
                         question: "Go?", risk: "schema is the retention seed",
                         recap: "voice-dispatch: brief table landed.", proposal: "Wire reads. Go?"),
            sessionId: "sess-1", eventRowid: 7, provider: "anthropic", callsign: "voice store")

        let reopened = try restartedStore()
        let stored = try XCTUnwrap(reopened.storedBrief(sessionId: "sess-1", eventRowid: 7))
        XCTAssertEqual(stored.brief.topic, "voice dispatch store")
        XCTAssertEqual(stored.brief.question, "Go?")
        XCTAssertEqual(stored.callsign, "voice store")
        XCTAssertEqual(stored.provider, "anthropic")
    }

    /// The whole point: after a restart the prepared memory is gone, but the
    /// stored brief serves the announcement — zero model calls, provider tagged
    /// `+stored` so a restored announcement is distinguishable.
    func testAnnounceAfterRestartUsesTheStoredBriefWithoutAModelCall() async throws {
        let before = CountingCardSummary()
        let coordinator = makeCoordinator(store: store, provider: before)
        try append()
        try await coordinator.prepareNext()
        XCTAssertEqual(before.calls, 1)

        // "Restart": fresh store, fresh coordinator, empty PreparedSummaries.
        let after = CountingCardSummary()
        let speech = SilentSpeech()
        let restarted = makeCoordinator(store: try restartedStore(), provider: after,
                                        speech: speech)
        guard case .spoke(let announcement) = try await restarted.announceNext() else {
            return XCTFail("expected an announcement")
        }
        XCTAssertEqual(after.calls, 0, "the stored brief must answer, not a new model call")
        XCTAssertEqual(announcement.via, "silent")
        XCTAssertTrue(announcement.spoken.text.contains("export pipeline green"),
                      "the restored recap is what plays: \(announcement.spoken.text)")
        XCTAssertEqual(speech.spoken.count, 1)
    }

    /// Depth-1 amnesia, fixed: the ⌃⌃ pull composes from the restored brief's
    /// card fields after a restart.
    func testDepthOneWorksFromTheStoredBriefAcrossRestart() async throws {
        let coordinator = makeCoordinator(store: store, provider: CountingCardSummary())
        try append()
        _ = try await coordinator.prepareNext()

        let after = CountingCardSummary()
        let restarted = makeCoordinator(store: try restartedStore(), provider: after)
        guard case .spoke(let announcement) = try await restarted.announceNext() else {
            return XCTFail("expected an announcement")
        }
        let depthOne = SpokenComposition.depthOneSpokenText(
            for: announcement, allowing: ["Klaviyo"])
        XCTAssertEqual(after.calls, 0)
        XCTAssertTrue(depthOne.text.contains("ship the Klaviyo export"),
                      "card fields survive the restart: \(depthOne.text)")
        XCTAssertTrue(depthOne.text.contains("migration drops a legacy table"))
    }

    // MARK: - Harvest

    /// Topics and goals are durable now, so the lexicon hears them: the topic
    /// joins verbatim, the goal contributes its proper nouns.
    func testLexiconHarvestIncludesStoredTopicsAndGoalNames() throws {
        try store.saveBrief(
            SessionBrief(topic: "promotions copy edit", goal: "ship the Zendesk import",
                         happened: "done"),
            sessionId: "sess-1", eventRowid: 3, provider: "anthropic", callsign: nil)

        let lexicon = Lexicon.harvest(store: store)
        XCTAssertTrue(lexicon.terms.contains("promotions copy edit"),
                      "the stored topic is harvested verbatim: \(lexicon.terms)")
        XCTAssertTrue(lexicon.terms.contains("Zendesk"),
                      "the goal contributes its proper nouns")
        XCTAssertTrue(lexicon.allowlistTerms.contains("edit"),
                      "multi-word topics split for the sanitizer allowlist")
    }

    // MARK: - The grid's topic source (visual port)

    /// The grid never shows prose prefixes: the waiting queries carry the stored
    /// brief's composed 3–6-word topic, joined on the latest event's rowid, and
    /// nil before any brief exists so a row can fall back to callsign-only.
    func testWaitingSessionsCarryTheStoredBriefTopic() throws {
        try append()
        let before = try XCTUnwrap(store.waitingSessions().first)
        XCTAssertNil(before.briefTopic, "no brief yet — the row shows callsign only")

        try store.saveBrief(
            SessionBrief(topic: "Klaviyo export shipped", happened: "done"),
            sessionId: "sess-1", eventRowid: before.latestId,
            provider: "anthropic", callsign: nil)

        XCTAssertEqual(try store.waitingSessions().first?.briefTopic,
                       "Klaviyo export shipped")
        XCTAssertEqual(try store.waitingSessionsIncludingHeard().first?.briefTopic,
                       "Klaviyo export shipped",
                       "quiet rows read the same joined topic")
    }

    /// Per-event, not per-session: a brief written for an older turn must not
    /// label the newer one — a stale topic under a fresh green lamp would
    /// describe work the session has already moved past.
    func testBriefTopicIsPerEventNotPerSession() throws {
        try append()
        let first = try XCTUnwrap(store.waitingSessions().first)
        try store.saveBrief(
            SessionBrief(topic: "old turn topic", happened: "done"),
            sessionId: "sess-1", eventRowid: first.latestId,
            provider: "anthropic", callsign: nil)

        try append(message: "A newer turn finished.")
        XCTAssertNil(try store.waitingSessions().first?.briefTopic,
                     "the newer turn has no brief yet — stale topics must not carry over")
    }
}
