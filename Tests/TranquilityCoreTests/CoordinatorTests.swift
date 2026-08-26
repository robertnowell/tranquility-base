import XCTest
@testable import TranquilityCore

/// Proves the assembly, not the parts. Speech, summarization and the terminal are
/// faked so the test can assert the *sequence*.
///
/// Most tests below pin a bug that actually happened in one day of use and that
/// resisted being fixed while session state was a mutable status column. They pass
/// now because the model makes them unrepresentable, not because a rule was
/// corrected — which is the whole argument for the rewrite.
final class CoordinatorTests: XCTestCase {
    var tmpDir: URL!
    var store: QueueStore!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-coord-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = try QueueStore(url: tmpDir.appendingPathComponent("queue.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Doubles

    struct FixedSummary: SummaryProvider {
        let name = "fixed"
        let isConfigured = true
        func brief(for request: SummaryRequest) async throws -> SessionBrief {
            SessionBrief(topic: "Export refactor", happened: "tests pass",
                         recap: "Fixing the export pipeline. Tests pass.",
                         proposal: "Run the migration next. Proceed?")
        }
    }

    final class SilentSpeech: SpeechProvider, @unchecked Sendable {
        let name = "silent"
        let isConfigured = true
        var isSpeaking = false
        var spoken: [String] = []
        /// Makes every announcement stop part-way, as a stray keypress does.
        var interrupt = false
        /// Makes every announcement die on its own — a synth failure, not a
        /// choice. Distinct from `interrupt` because the cursor treats them
        /// oppositely: a user stop opens the turn, a fault never does.
        var fail = false
        struct SynthDied: Error {}
        func speak(_ text: SanitizedSpokenText, onWord: (@Sendable (Range<Int>) -> Void)?) async throws {
            if fail { throw SynthDied() }
            if interrupt { throw SpeechError.interrupted }
            spoken.append(text.text)
        }
        func stop() {}
    }

    final class RecordingTransport: DispatchTransport, @unchecked Sendable {
        let kind = TransportKind.terminalApp
        var sent: [String] = []
        var sentTargets: [DispatchTarget] = []
        var outcome: DispatchOutcome = .confirmed(latencyMs: 42)
        var readinessValue: Readiness = .ready
        func readiness(for target: DispatchTarget) async -> Readiness { readinessValue }
        func send(text: String, to target: DispatchTarget) async -> DispatchOutcome {
            sent.append(text)
            sentTargets.append(target)
            return outcome
        }
    }

    struct FakeAgents: ClaudeAgentsReading {
        let live: [LiveSession]
        func sessions() -> [LiveSession]? { live }
    }

    /// The probe itself failing — CLI missing, spawn error, bad JSON — which is a
    /// different fact from "no sessions", and must behave differently.
    struct FailingAgents: ClaudeAgentsReading {
        func sessions() -> [LiveSession]? { nil }
    }

    /// A fixed set of ownership records — `waiting()`'s only source of
    /// Codex liveness (26 Aug: `agents` never carries a Codex session at
    /// all, registered or not). Never the real `FileSessionOwnershipStore`
    /// in this file's tests, which must not read whatever this machine's
    /// own real Codex sessions happen to have recorded.
    struct StubOwnershipStore: SessionOwnershipStore {
        let records: [SessionOwnershipRecord]
        func record(_ r: SessionOwnershipRecord) {}
        func current(sessionId: String) -> SessionOwnershipRecord? {
            records.first { $0.sessionId == sessionId }
        }
        func remove(sessionId: String) {}
        func all() -> [SessionOwnershipRecord] { records }
    }

    /// A session that is not listed yet and appears after a few probes — a
    /// brand-new agent, which can register, bind, and briefly drop back out of
    /// `claude agents --json` before it has taken any input.
    final class LateAgents: ClaudeAgentsReading, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        let appearsOnCall: Int
        let live: [LiveSession]

        init(appearsOnCall: Int, live: [LiveSession]) {
            self.appearsOnCall = appearsOnCall
            self.live = live
        }

        var probes: Int { lock.lock(); defer { lock.unlock() }; return calls }

        func sessions() -> [LiveSession]? {
            lock.lock(); calls += 1; let n = calls; lock.unlock()
            return n >= appearsOnCall ? live : []
        }
    }

    struct FixedTranscript: RecoveryTranscriptionProvider {
        let name = "fixed"
        let isConfigured = true
        let text: String
        func transcribe(fileAt url: URL) async throws -> TranscriptionResult {
            TranscriptionResult(text: text, finality: .recoveryForcedFinal, provider: name)
        }
    }

    private func makeCoordinator(
        speech: SilentSpeech = SilentSpeech(),
        tmuxTransport: RecordingTransport = RecordingTransport(),
        enrolled: Bool = true,
        sessionLive: Bool = true,
        gate: InterruptGate = InterruptGate(minimumIdleSeconds: 0, signals: .quiescent),
        // Zero by default: these tests assert the REFUSAL, and paying the
        // production grace for each one added twelve seconds apiece to the
        // suite. The grace has its own test, below.
        readinessGrace: TimeInterval = 0,
        // A FABRICATED pane by default, for every test but the ones that
        // exist to assert `resumeTwin` failing specifically. Single-
        // transport cut (23 Aug): with `TerminalAppTransport` deleted,
        // `Coordinator.dispatch` refuses cleanly the moment `resumeTwin`
        // returns nil (no fallback transport left to reach) — so a
        // fixture pid the test process has no real tmux pane for (every
        // `LiveSession` below, cwd "/tmp/p") needs SOME resolved pane to
        // reach `tmuxTransport` at all, the same way production reaches it
        // via a real `resumeTmux`. The two tests that assert the refusal
        // itself pass `resumeTwin: { _, _ in nil }` explicitly.
        resumeTwin: @escaping @Sendable (String, String) -> TmuxPaneAddress? = { _, _ in
            TmuxPaneAddress(socketName: "tb", paneId: "%1",
                            sessionName: "tb-fixture", paneTty: "/dev/ttys999")
        },
        // nil keeps the default fixed FakeAgents below — only the ownership-
        // transfer test needs an agents fake that answers DIFFERENTLY before
        // and after `resumeTwin` runs, since that is exactly the seam it
        // exercises (the real `resumeTwin` ends one pid and starts another).
        agents overrideAgents: (any ClaudeAgentsReading)? = nil,
        // Empty by default, and never the real FileSessionOwnershipStore —
        // this file's tests must not read whatever this machine's own real
        // Codex sessions happen to have recorded.
        ownership: any SessionOwnershipStore = StubOwnershipStore(records: [])
    ) throws -> Coordinator {
        let registry = EnrolmentRegistry(url: tmpDir.appendingPathComponent("enrolled.json"))
        if enrolled { try registry.enrol(sessionId: "sess-1") }
        return Coordinator(
            store: store,
            summarizer: SummarizerChain(providers: [FixedSummary()]),
            speech: SpeechChain(preferred: speech, fallback: speech),
            gate: gate,
            tmuxTransport: tmuxTransport,
            enrolment: registry,
            agents: overrideAgents ?? FakeAgents(live: sessionLive
                ? ["sess-1", "old", "new", "human", "cron", "waiting-one"].map {
                    LiveSession(pid: Int(ProcessInfo.processInfo.processIdentifier),
                                sessionId: $0, cwd: "/tmp/p", status: "idle",
                                name: "p", waitingFor: nil)
                  }
                : []),
            ownership: ownership,
            recovery: RecoveryChain(
                providers: [FixedTranscript(text: "yes go ahead")],
                maxAttemptsPerProvider: 1, backoff: [0]),
            readinessGrace: readinessGrace,
            resumeTwin: resumeTwin)
    }

    /// Append to the log. Nothing else ever writes an event.
    private func append(
        _ kind: HookEventKind = .stop, session: String = "sess-1",
        at ms: Int64 = 1_000, message: String = "a turn finished", tty: String? = "ttys001"
    ) throws {
        _ = try store.insert(event: QueuedEvent(
            createdAtMs: ms, hookEvent: kind, sessionId: session,
            promptId: UUID().uuidString, cwd: "/tmp/\(session)",
            lastAssistantMessage: message, tty: tty))
    }

    private func silence(seconds: Double = 1) -> Data { Data(count: Int(seconds * 16000) * 2) }

    /// A transcript on disk whose `entrypoint` says who started this session.
    /// The announcer reads it from the path the hook recorded, so the fixture
    /// has to be a real file.
    private func transcript(_ session: String, entrypoint: String?) throws -> String {
        let path = tmpDir.appendingPathComponent("\(session).jsonl").path
        let entry = entrypoint.map { #""entrypoint":"\#($0)","# } ?? ""
        try (#"{"type":"user",\#(entry)"cwd":"/tmp"}"# + "\n"
            + #"{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}"#
            + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func appendWithTranscript(
        session: String, entrypoint: String?, at ms: Int64 = 1_000
    ) throws {
        _ = try store.insert(event: QueuedEvent(
            createdAtMs: ms, hookEvent: .stop, sessionId: session,
            promptId: UUID().uuidString, cwd: "/tmp/\(session)",
            transcriptPath: try transcript(session, entrypoint: entrypoint),
            lastAssistantMessage: "a turn finished", tty: "ttys001"))
    }

    // MARK: - Only sessions a person started are announced

    /// Liveness used to do this job by accident, and the accident held only
    /// while the probe answered. A cron job that finishes is gone from the
    /// agents API, so it never got announced — but when the probe FAILS the
    /// announcer falls back to the store's whole set, which on the author's
    /// machine is 502 sessions a week, 460 of them robots.
    func testHeadlessSessionsAreNeverAnnouncedEvenWhenTheProbeFails() throws {
        let coordinator = try makeCoordinator(sessionLive: false)
        try appendWithTranscript(session: "human", entrypoint: "cli", at: 1_000)
        try appendWithTranscript(session: "cron", entrypoint: "sdk-cli", at: 2_000)

        let live = try coordinator.waiting().map(\.sessionId)
        XCTAssertFalse(live.contains("cron"))

        let failing = Coordinator(
            store: store,
            summarizer: SummarizerChain(providers: [FixedSummary()]),
            speech: SpeechChain(preferred: SilentSpeech(), fallback: SilentSpeech()),
            gate: InterruptGate(minimumIdleSeconds: 0, signals: .quiescent),
            tmuxTransport: RecordingTransport(),
            enrolment: EnrolmentRegistry(url: tmpDir.appendingPathComponent("e2.json")),
            agents: FailingAgents(),
            recovery: RecoveryChain(providers: [FixedTranscript(text: "x")],
                                    maxAttemptsPerProvider: 1, backoff: [0]),
            readinessGrace: 0)
        let blind = try failing.waiting().map(\.sessionId)
        XCTAssertTrue(blind.contains("human"),
                      "a probe failure must still surface real work")
        XCTAssertFalse(blind.contains("cron"),
                       "and must no longer surface machine-started runs")
    }

    /// The failure the tty filter actually caused was hiding real
    /// conversations, so an unreadable or unrecognised origin keeps its
    /// session. Exclusion needs positive evidence.
    func testAnUnreadableOriginIsStillAnnounced() throws {
        let coordinator = try makeCoordinator(sessionLive: true)
        try appendWithTranscript(session: "human", entrypoint: nil, at: 1_000)
        XCTAssertTrue(try coordinator.waiting().map(\.sessionId).contains("human"))
    }

    // MARK: - Codex liveness (26 Aug) — `agents` never carries one, ever

    /// A Codex session never appears in `agents` — registered or not, that
    /// registry is `claude agents --json` — so without an ownership record
    /// it must NOT read as gone the instant it's first polled the way a
    /// fresh launch was found doing live, seconds after registering.
    func testACodexSessionWithALivePidIsAnnounced() throws {
        let coordinator = try makeCoordinator(sessionLive: false, ownership: StubOwnershipStore(
            records: [SessionOwnershipRecord(
                sessionId: "codex-1", harness: "codex",
                pid: Int(ProcessInfo.processInfo.processIdentifier))]))
        try appendWithTranscript(session: "codex-1", entrypoint: "cli", at: 1_000)
        XCTAssertTrue(try coordinator.waiting().map(\.sessionId).contains("codex-1"))
    }

    /// A Codex session recorded once but no longer running must not read as
    /// live forever — the pid is the only liveness fact this record has,
    /// same discipline `verifiedCurrent` already applies.
    func testACodexSessionWithADeadPidIsNotAnnounced() throws {
        var reaped: Process? = Process()
        reaped?.executableURL = URL(fileURLWithPath: "/bin/echo")
        try? reaped?.run()
        let deadPid = Int(reaped?.processIdentifier ?? -1)
        reaped?.waitUntilExit()
        reaped = nil

        let coordinator = try makeCoordinator(sessionLive: false, ownership: StubOwnershipStore(
            records: [SessionOwnershipRecord(sessionId: "codex-1", harness: "codex", pid: deadPid)]))
        try appendWithTranscript(session: "codex-1", entrypoint: "cli", at: 1_000)
        XCTAssertFalse(try coordinator.waiting().map(\.sessionId).contains("codex-1"))
    }

    /// A live Claude Code session in `ownership` (recorded by a revive, say)
    /// must not double-count or otherwise interfere — `agents` alone is
    /// still authoritative for that harness.
    func testOwnershipRecordsForOtherHarnessesDoNotChangeClaudeCodeLiveness() throws {
        let coordinator = try makeCoordinator(sessionLive: true, ownership: StubOwnershipStore(
            records: [SessionOwnershipRecord(sessionId: "human", harness: "claude-code", pid: -1)]))
        try appendWithTranscript(session: "human", entrypoint: "cli", at: 1_000)
        XCTAssertTrue(try coordinator.waiting().map(\.sessionId).contains("human"))
    }

    /// The fuller proof: being counted as "waiting" (above) is necessary but
    /// not sufficient — `dispatch`'s OWN readiness resolution is a second,
    /// independent call to `agents.sessions()` (Coordinator+ReplyPipeline.
    /// swift), found live the same day a Codex session's greeting card
    /// correctly stayed up and the reply that answered it still got refused
    /// with "can't take this yet." A full submitReply → confirmAndSend round
    /// trip against a session `agents` has never heard of must actually
    /// reach the transport.
    func testACodexSessionsReplyActuallyDispatches() async throws {
        let transport = RecordingTransport()
        let coordinator = try makeCoordinator(
            tmuxTransport: transport, sessionLive: false,
            ownership: StubOwnershipStore(records: [SessionOwnershipRecord(
                sessionId: "codex-1", harness: "codex",
                pid: Int(ProcessInfo.processInfo.processIdentifier),
                paneId: "%1", socketName: "tb", sessionName: "tb-codex-1", paneTty: "/dev/ttys999")]))
        try append(session: "codex-1")
        _ = try await coordinator.announceNext()

        guard case .readyToSend(let utteranceId, _, _, let sessionId) =
            try await coordinator.submitReply(pcm16: silence())
        else { return XCTFail("expected a pending send") }
        XCTAssertEqual(sessionId, "codex-1")
        guard case .dispatched = try await coordinator.confirmAndSend(utteranceId: utteranceId)
        else { return XCTFail("a Codex session agents has never heard of must still receive the reply") }
        XCTAssertEqual(transport.sent.count, 1)
    }

    // MARK: - The full loop

    func testAnnounceThenReplyRoutesBackToTheSessionThatSpoke() async throws {
        let speech = SilentSpeech()
        let transport = RecordingTransport()
        let coordinator = try makeCoordinator(speech: speech, tmuxTransport: transport)
        try append()

        guard case .spoke(let announcement) = try await coordinator.announceNext() else {
            return XCTFail("expected an announcement")
        }
        XCTAssertEqual(speech.spoken.count, 1)
        XCTAssertTrue(announcement.spoken.text.contains("Fixing the export pipeline"))
        XCTAssertEqual(try coordinator.replyTarget()?.sessionId, "sess-1")

        guard case .readyToSend(let utteranceId, _, _, _) =
            try await coordinator.submitReply(pcm16: silence())
        else { return XCTFail("expected a pending send") }
        XCTAssertTrue(transport.sent.isEmpty, "nothing is typed while the window is open")

        guard case .dispatched(let text, _, let sessionId, _) =
            try await coordinator.confirmAndSend(utteranceId: utteranceId)
        else { return XCTFail("expected dispatch") }
        XCTAssertEqual(sessionId, "sess-1")
        XCTAssertEqual(transport.sent, [text])
    }

    // MARK: - The bugs this model makes unrepresentable

    /// THE bug. You type, the agent works, the agent finishes — and that finished
    /// turn is exactly what you want to hear. Retiring on user-typed deleted it, so
    /// an actively-used session could never have anything waiting.
    func testATurnArrivingAfterYouTypedIsStillWaiting() async throws {
        let coordinator = try makeCoordinator()
        try append(.stop, at: 1_000, message: "an older turn")
        try append(.userPromptSubmit, at: 2_000, message: "")
        XCTAssertNil(try coordinator.nextToAnnounce(),
                     "you answered it yourself, so nothing is waiting")

        try append(.stop, at: 3_000, message: "the reply to what you just typed")

        XCTAssertEqual(try coordinator.nextToAnnounce()?.lastAssistantMessage,
                       "the reply to what you just typed",
                       "a later event wins; nothing was written to make this true")
    }

    /// THE 10 Aug bug. Reply to a session, go back to the grid, press ⌃⌥ because
    /// you are ready for the next thing — and the session you just answered starts
    /// talking again.
    ///
    /// The grid had already been taught this: its lamp goes blue the instant you
    /// send, via `DeliveryInFlight.supersedesWaiting`. The selector had not, because
    /// it was `waiting().first` — so the panel said blue while the keyboard acted
    /// on green. This pins the two to the same predicate.
    func testASessionYouAreMidReplyToIsNotOfferedNext() async throws {
        let coordinator = try makeCoordinator()
        try append(.stop, at: 1_000, message: "the turn you are about to answer")
        let waiting = try XCTUnwrap(coordinator.nextToAnnounce())

        var delivering = DeliveryInFlight()
        delivering.began(sessionId: waiting.sessionId, answering: waiting.latestId)

        XCTAssertNil(try coordinator.nextToAnnounce(excluding: delivering),
                     "you are answering it right now; offering it back is the bug")
        XCTAssertNotNil(try coordinator.nextToAnnounce(),
                        "waiting() itself is unchanged — the overlay is the caller's")
    }

    /// The overlay must hold back only the turn being answered. A turn that arrives
    /// WHILE the reply is in flight is genuinely unread, and swallowing it would
    /// trade a noisy bug for a silent one — which is the worse of the two.
    func testANewerTurnArrivingDuringDeliveryStillAnnounces() async throws {
        let coordinator = try makeCoordinator()
        try append(.stop, at: 1_000, message: "the turn you answered")
        let answered = try XCTUnwrap(coordinator.nextToAnnounce())

        var delivering = DeliveryInFlight()
        delivering.began(sessionId: answered.sessionId, answering: answered.latestId)

        try append(.stop, at: 2_000, message: "something new while you were talking")

        XCTAssertEqual(
            try coordinator.nextToAnnounce(excluding: delivering)?.lastAssistantMessage,
            "something new while you were talking",
            "a newer turn outranks the delivery overlay")
    }

    /// The overlay expires. A delivery that never resolves must not pin a session
    /// out of the queue for ever — the same reasoning as the lamp's ceiling, and
    /// the reason `DeliveryInFlight` bounds every entry.
    func testAStaleDeliveryStopsHoldingTheSessionBack() async throws {
        let coordinator = try makeCoordinator()
        try append(.stop, at: 1_000, message: "the turn you answered")
        let answered = try XCTUnwrap(coordinator.nextToAnnounce())

        var delivering = DeliveryInFlight()
        let longAgo = Date().addingTimeInterval(-(DeliveryInFlight.ceiling + 1))
        delivering.began(sessionId: answered.sessionId, answering: answered.latestId, at: longAgo)

        XCTAssertNotNil(try coordinator.nextToAnnounce(excluding: delivering),
                        "a delivery past its ceiling has stopped meaning anything")
    }

    /// Dismissal is scoped to the item that existed when you dismissed it. A boolean
    /// would silence the session for ever; a watermark lets the next turn revive it.
    func testDismissingASessionDoesNotSilenceItForever() async throws {
        let coordinator = try makeCoordinator()
        try append(.stop, at: 1_000, message: "first turn")
        let first = try XCTUnwrap(coordinator.nextToAnnounce())

        try coordinator.dismiss(sessionId: first.sessionId, through: first.latestId)
        XCTAssertNil(try coordinator.nextToAnnounce(), "dealt with")

        try append(.stop, at: 2_000, message: "a later turn")

        XCTAssertEqual(try coordinator.nextToAnnounce()?.lastAssistantMessage, "a later turn",
                       "the next turn revives the session by construction")
    }

    /// Stopping part-way OPENS the turn (re-ruled 13 Aug, reversing "hearing
    /// it through is the only thing that advances the cursor" — measured
    /// against use, not argued: almost no announcement is played to the end,
    /// so the old rule replayed nearly everything and ⌃⌥ could never move
    /// on). Audio started and the user stopped it: the cursor advances, the
    /// automatic path skips it, and it stays waiting — read is not answered —
    /// so the grid keeps it and a replay stays one row-tap away.
    func testStoppingPartWayOpensTheTurnButLeavesItWaiting() async throws {
        let speech = SilentSpeech()
        speech.interrupt = true
        let coordinator = try makeCoordinator(speech: speech)
        try append()

        guard case .interrupted = try await coordinator.announceNext() else {
            return XCTFail("expected an interrupted announcement")
        }
        XCTAssertNotNil(try store.cursor(for: "sess-1")?.heardThrough,
                        "audio you stopped yourself counts as opened")
        XCTAssertNil(try coordinator.nextToAnnounce(), "opened, so not re-announced")
        XCTAssertEqual(try coordinator.nextToReplay()?.sessionId, "sess-1",
                       "still waiting: green always has something to play")
        XCTAssertEqual(try coordinator.replyTarget()?.sessionId, "sess-1",
                       "the session you just walked out of takes the reply")
    }

    /// ⌃⌥ over an all-opened stack WALKS it. The first fix replayed
    /// `waiting().first`, a constant function, so the key welded itself to one
    /// session — five presses, five `replaying 4394c0ec` (app.log 16 Aug
    /// 01:04). Reported as "hitting Control-Option again goes back to the same
    /// session as was playing before".
    func testReplayWalksTheStackRatherThanRepeatingOneRow() async throws {
        let coordinator = try makeCoordinator()
        // Newest first is the stack's order, so: new, human, old.
        try append(session: "old", at: 1_000)
        try append(session: "human", at: 2_000)
        try append(session: "new", at: 3_000)

        XCTAssertEqual(try coordinator.nextToReplay()?.sessionId, "new",
                       "no walk in progress opens at the top")
        XCTAssertEqual(try coordinator.nextToReplay(after: "new")?.sessionId, "human")
        XCTAssertEqual(try coordinator.nextToReplay(after: "human")?.sessionId, "old")
        XCTAssertEqual(try coordinator.nextToReplay(after: "old")?.sessionId, "new",
                       "the end wraps — a dead end is the silent press again")
    }

    /// One green row replays itself, because that is genuinely all there is.
    /// The wrap must not turn a single-row stack into nothing to play.
    func testAOneRowStackReplaysItself() async throws {
        let coordinator = try makeCoordinator()
        try append(session: "sess-1", at: 1_000)
        XCTAssertEqual(try coordinator.nextToReplay(after: "sess-1")?.sessionId, "sess-1")
    }

    /// A walk marker for a session that has since left the stack — dismissed,
    /// died, swept — restarts at the top rather than returning nothing.
    func testAStaleWalkMarkerFallsBackToTheTop() async throws {
        let coordinator = try makeCoordinator()
        try append(session: "old", at: 1_000)
        try append(session: "new", at: 2_000)
        XCTAssertEqual(try coordinator.nextToReplay(after: "gone-session")?.sessionId, "new")
    }

    /// The half of the old rule that survives: audio that stopped ITSELF is a
    /// fault, not a choice, and a silent failure must not consume the turn.
    func testAFailedAnnouncementStaysUnread() async throws {
        let speech = SilentSpeech()
        speech.fail = true
        let coordinator = try makeCoordinator(speech: speech)
        try append()

        guard case .interrupted(let failure) = try await coordinator.announceNext() else {
            return XCTFail("expected an interrupted announcement")
        }
        XCTAssertNotNil(failure, "a fault is surfaced, never respected quietly")
        XCTAssertNil(try store.cursor(for: "sess-1")?.heardThrough,
                     "no sound reached anyone, so nothing was opened")
        XCTAssertNotNil(try coordinator.nextToAnnounce(), "still first in line")
    }

    /// Two hooks in the same millisecond used to flip the state, because bare-column
    /// max() over a timestamp returns an arbitrary row on ties. Rowids cannot tie.
    func testIdenticalTimestampsResolveDeterministically() async throws {
        let coordinator = try makeCoordinator()
        try append(.stop, at: 5_000, message: "earlier write, same millisecond")
        try append(.userPromptSubmit, at: 5_000, message: "")

        XCTAssertNil(try coordinator.nextToAnnounce(),
                     "the later ROW wins regardless of the identical timestamp")

        try append(.stop, at: 5_000, message: "later write, same millisecond again")
        XCTAssertEqual(try coordinator.nextToAnnounce()?.lastAssistantMessage,
                       "later write, same millisecond again")
    }

    /// A stack, not a queue: the newest turn is the state that is actually true.
    /// A prepared summary is a summary OF one event. When the session moves on,
    /// the stale preparation must be discarded, not spoken — one played aloud two
    /// turns after the user had already answered it.
    func testPreparedSummaryForAnOlderTurnIsNotSpoken() async throws {
        final class CountingSummary: SummaryProvider, @unchecked Sendable {
            let name = "counting"; let isConfigured = true
            var calls = 0
            func brief(for request: SummaryRequest) async throws -> SessionBrief {
                calls += 1
                return SessionBrief(topic: "T", happened: "H",
                                    recap: request.lastAssistantMessage, proposal: "P?")
            }
        }
        let counting = CountingSummary()
        let registry = EnrolmentRegistry(url: tmpDir.appendingPathComponent("enrolled.json"))
        let coordinator = Coordinator(
            store: store, summarizer: SummarizerChain(providers: [counting]),
            speech: SpeechChain(preferred: SilentSpeech(), fallback: SilentSpeech()),
            gate: InterruptGate(minimumIdleSeconds: 0, signals: .quiescent),
            tmuxTransport: RecordingTransport(), enrolment: registry,
            agents: FakeAgents(live: [LiveSession(pid: 1, sessionId: "sess-1", cwd: "/tmp",
                                                  status: "idle", name: "p", waitingFor: nil)]),
            recovery: RecoveryChain(providers: [], maxAttemptsPerProvider: 1, backoff: [0]))

        try append(.stop, at: 1_000, message: "the OLD turn")
        try await coordinator.prepareNext()
        XCTAssertEqual(counting.calls, 1)

        try append(.stop, at: 2_000, message: "the NEW turn")
        guard case .spoke(let spoken) = try await coordinator.announceNext() else {
            return XCTFail("expected an announcement")
        }
        XCTAssertTrue(spoken.spoken.text.contains("the NEW turn"),
                      "the stale preparation must not be what plays")
        XCTAssertEqual(counting.calls, 2, "re-summarized for the newer event")
    }

    func testNewestSessionFirst() async throws {
        let coordinator = try makeCoordinator()
        try append(.stop, session: "old", at: 1_000, message: "older session")
        try append(.stop, session: "new", at: 9_000, message: "newer session")

        XCTAssertEqual(try coordinator.nextToAnnounce()?.sessionId, "new")
        XCTAssertEqual(try coordinator.waiting().count, 2)
    }

    /// Machine-driven runs are identified by being GONE, not by their terminal.
    ///
    /// Three attempts tried to read the hook's controlling terminal and all three
    /// were wrong: a hook spawned by a real interactive session records "??" exactly
    /// as a `claude -p` run does. That filter hid live conversations. Liveness is
    /// the honest question — if the session is gone there is no tab to open and
    /// nobody to answer.
    func testSessionsThatHaveExitedAreNotOffered() async throws {
        let registry = EnrolmentRegistry(url: tmpDir.appendingPathComponent("enrolled.json"))
        let coordinator = Coordinator(
            store: store,
            summarizer: SummarizerChain(providers: [FixedSummary()]),
            speech: SpeechChain(preferred: SilentSpeech(), fallback: SilentSpeech()),
            gate: InterruptGate(minimumIdleSeconds: 0, signals: .quiescent),
            tmuxTransport: RecordingTransport(), enrolment: registry,
            agents: FakeAgents(live: [
                LiveSession(pid: 1, sessionId: "human", cwd: "/tmp", status: "idle",
                            name: "p", waitingFor: nil)]),
            recovery: RecoveryChain(providers: [], maxAttemptsPerProvider: 1, backoff: [0]))

        try append(.stop, session: "cron", at: 9_000, message: "a nightly job that exited")
        try append(.stop, session: "human", at: 1_000, message: "your session")

        XCTAssertEqual(try coordinator.nextToAnnounce()?.sessionId, "human",
                       "the live session wins even though the job is newer")
        XCTAssertEqual(try coordinator.waitingCount(), 1)
    }

    /// The tty is recorded but must never decide anything: real sessions report "??".
    func testTerminalIsNeverUsedToExclude() async throws {
        let coordinator = try makeCoordinator()
        try append(tty: "??")
        XCTAssertNotNil(try coordinator.nextToAnnounce(),
                        "a live session reporting no terminal is still a live session")
    }

    /// The badge and the keypress share one predicate, so they cannot disagree —
    /// the badge once read "2 waiting" while nothing could be played.
    func testBadgeAgreesWithWhatCanBeAnnounced() async throws {
        let coordinator = try makeCoordinator()
        XCTAssertEqual(try store.pendingCount(), 0)
        XCTAssertNil(try coordinator.nextToAnnounce())

        try append()
        XCTAssertEqual(try store.pendingCount(), 1)
        XCTAssertNotNil(try coordinator.nextToAnnounce())
    }

    func testHearingItThroughIsWhatMarksItRead() async throws {
        let coordinator = try makeCoordinator()
        try append()

        guard case .spoke = try await coordinator.announceNext() else {
            return XCTFail("expected an announcement")
        }
        XCTAssertNil(try coordinator.nextToAnnounce(), "heard, so no longer waiting")
        XCTAssertNotNil(try store.cursor(for: "sess-1")?.heardThrough)
    }

    // MARK: - The gate can only delay

    func testGateVetoLeavesTheSessionWaitingRatherThanChangingIt() async throws {
        let speech = SilentSpeech()
        let coordinator = try makeCoordinator(
            speech: speech,
            gate: InterruptGate(
                minimumIdleSeconds: 8,
                signals: .init(idleSeconds: { 0 }, frontmostApp: { nil }, screenLocked: { false })))
        try append()

        guard case .held = try await coordinator.announceNext() else {
            return XCTFail("expected the gate to hold it")
        }
        XCTAssertTrue(speech.spoken.isEmpty)
        XCTAssertNotNil(try coordinator.nextToAnnounce(), "a veto delays; it never consumes")
        XCTAssertNil(try store.cursor(for: "sess-1")?.heardThrough, "and it writes nothing")
    }

    // MARK: - Refusals

    func testTranscribingNeverTypesAnything() async throws {
        let transport = RecordingTransport()
        let coordinator = try makeCoordinator(tmuxTransport: transport, enrolled: false)
        try append()
        _ = try await coordinator.announceNext()

        guard case .readyToSend = try await coordinator.submitReply(pcm16: silence()) else {
            return XCTFail("expected a pending send")
        }
        XCTAssertTrue(transport.sent.isEmpty, "nothing is typed before the window closes")
        XCTAssertNotNil(try store.utterances().first?.audioPath, "the recording is kept")
    }

    /// Absent from `claude agents --json` means blocked on a dialog. Typing would
    /// answer the dialog, so we refuse and keep the audio.
    func testDialogBlockedSessionIsRefusedNotGuessed() async throws {
        let transport = RecordingTransport()
        // Heard while live, then the session blocks on a dialog and disappears from
        // the agents API before the reply is sent.
        let live = try makeCoordinator(tmuxTransport: transport)
        try append()
        _ = try await live.announceNext()
        guard case .readyToSend(let utteranceId, _, _, _) =
            try await live.submitReply(pcm16: silence())
        else { return XCTFail("expected a pending send") }

        let coordinator = try makeCoordinator(tmuxTransport: transport, sessionLive: false)

        guard case .sessionNotReady(.notRegistered) =
            try await coordinator.confirmAndSend(utteranceId: utteranceId)
        else { return XCTFail("expected a refusal") }
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testAmbiguousDispatchIsNeverMarkedConfirmedOrRetried() async throws {
        let transport = RecordingTransport()
        transport.outcome = .failed(.verificationTimedOut)
        let coordinator = try makeCoordinator(tmuxTransport: transport)
        try append()
        _ = try await coordinator.announceNext()

        guard case .readyToSend(let utteranceId, _, _, _) =
            try await coordinator.submitReply(pcm16: silence())
        else { return XCTFail("expected a pending send") }

        guard case .dispatchFailed(.verificationTimedOut, _) =
            try await coordinator.confirmAndSend(utteranceId: utteranceId)
        else { return XCTFail("expected an ambiguous result") }
        XCTAssertEqual(try store.utterances().first?.status, .dispatchedUnconfirmed,
                       "must not claim success, and must not silently resend")
        XCTAssertEqual(transport.sent.count, 1, "one attempt: a duplicate is worse than a drop")
    }

    /// The 22 Aug fix, narrowed 23 Aug: a hand-started session with no tmux
    /// pane resumes a twin (via the injected `resumeTwin`) and dispatches
    /// into THAT. Used to be "instead of falling to `transport`
    /// (AppleScript/Terminal.app)" — that fallback is deleted outright now
    /// (single-transport cut), so the only thing left to assert is that the
    /// transfer happens and the reply lands over tmux. The twin's own
    /// pid/pane are fabricated here — only the WIRING is under test, not
    /// `resumeTmux` itself, which has no place running for real inside a
    /// unit test (see `resumeTwin`'s own doc comment).
    func testAHandStartedSessionWithNoPaneResumesATwinAndDispatchesOverTmux() async throws {
        let tmux = RecordingTransport()
        let fabricatedPane = TmuxPaneAddress(
            socketName: "tb", paneId: "%99", sessionName: "tb-fabricated", paneTty: "/dev/ttys099")
        final class Calls: @unchecked Sendable {
            private let lock = NSLock()
            private var seen: [(sessionId: String, directory: String)] = []
            func record(_ sessionId: String, _ directory: String) {
                lock.lock(); defer { lock.unlock() }
                seen.append((sessionId, directory))
            }
            var all: [(sessionId: String, directory: String)] {
                lock.lock(); defer { lock.unlock() }; return seen
            }
        }
        let resumeTwinCalls = Calls()
        let coordinator = try makeCoordinator(
            tmuxTransport: tmux,
            resumeTwin: { sessionId, directory in
                resumeTwinCalls.record(sessionId, directory)
                return fabricatedPane
            })
        try append()
        _ = try await coordinator.announceNext()

        guard case .readyToSend(let utteranceId, _, _, _) =
            try await coordinator.submitReply(pcm16: silence())
        else { return XCTFail("expected a pending send") }

        _ = try await coordinator.confirmAndSend(utteranceId: utteranceId)

        XCTAssertEqual(resumeTwinCalls.all.count, 1)
        XCTAssertEqual(resumeTwinCalls.all.first?.sessionId, "sess-1")
        XCTAssertEqual(resumeTwinCalls.all.first?.directory, "/tmp/p")
        XCTAssertEqual(tmux.sent.count, 1, "the reply lands in the twin, over tmux")
    }

    /// A mutable `ClaudeAgentsReading` fake — needed only by the test below,
    /// where `resumeTwin` itself must change what the NEXT probe answers
    /// (the real default implementation ends one process and starts
    /// another; `agents.sessions()` reporting the OLD pid throughout would
    /// make the test pass by construction rather than by testing anything).
    final class SwappableAgents: ClaudeAgentsReading, @unchecked Sendable {
        private let lock = NSLock()
        private var current: [LiveSession]
        init(_ live: [LiveSession]) { current = live }
        func sessions() -> [LiveSession]? { lock.lock(); defer { lock.unlock() }; return current }
        func replace(_ live: [LiveSession]) { lock.lock(); current = live; lock.unlock() }
    }

    /// 23 Aug, the day `resumeTwin`'s default became a TRANSFER (end the
    /// hand-started process, resume fresh under tmux) rather than a
    /// parallel twin: `DispatchTarget.pid` and `Coordinator`'s own `live`
    /// still read the pid `resumed` from BEFORE the call, which is the
    /// exact pid the transfer just ended on purpose. Found live the same
    /// day: GO TO AGENT read "couldn't find a terminal for process 21081 —
    /// it may have exited", true and also the bug — the panel never learned
    /// about the NEW pid the transfer had actually landed on.
    func testOwnershipTransferRefreshesThePidDownstream() async throws {
        let tmux = RecordingTransport()
        let fabricatedPane = TmuxPaneAddress(
            socketName: "tb", paneId: "%99", sessionName: "tb-fabricated", paneTty: "/dev/ttys099")
        let rows: @Sendable (Int) -> [LiveSession] = { pid in
            ["sess-1", "old", "new", "human", "cron", "waiting-one"].map {
                LiveSession(pid: pid, sessionId: $0, cwd: "/tmp/p", status: "idle",
                           name: "p", waitingFor: nil)
            }
        }
        let agents = SwappableAgents(rows(111))
        let coordinator = try makeCoordinator(
            tmuxTransport: tmux,
            resumeTwin: { _, _ in
                // The real closure's own effect, faked here: the
                // hand-started pid is gone, a fresh one is live under tmux.
                agents.replace(rows(222))
                return fabricatedPane
            },
            agents: agents)
        try append()
        _ = try await coordinator.announceNext()

        guard case .readyToSend(let utteranceId, _, _, _) =
            try await coordinator.submitReply(pcm16: silence())
        else { return XCTFail("expected a pending send") }

        _ = try await coordinator.confirmAndSend(utteranceId: utteranceId)

        XCTAssertEqual(tmux.sentTargets.first?.pid, 222,
                       "the target must carry the pid the transfer landed on, not 111")
        XCTAssertEqual(try store.utterances().first?.targetPid, 222,
                       "the stored utterance must agree with the dispatch target")
    }

    /// The other half, rewritten for the single-transport cut (23 Aug): when
    /// `resumeTwin` fails (returns nil — the real default does this whenever
    /// `resumeTmux` itself fails), dispatch used to fall back to
    /// `TerminalAppTransport`; with that deleted outright (on the operator's
    /// own instruction — no fallback worth keeping for a failure mode this
    /// narrow), it refuses cleanly instead. A genuinely broken tmux binary
    /// now reads as an honest failure, not a silent reroute through a
    /// far-less-tested transport.
    func testATwinThatFailsToResumeRefusesCleanly() async throws {
        let tmux = RecordingTransport()
        let coordinator = try makeCoordinator(
            tmuxTransport: tmux, resumeTwin: { _, _ in nil })
        try append()
        _ = try await coordinator.announceNext()

        guard case .readyToSend(let utteranceId, _, _, _) =
            try await coordinator.submitReply(pcm16: silence())
        else { return XCTFail("expected a pending send") }

        guard case .dispatchFailed(.injectionFailed, _) =
            try await coordinator.confirmAndSend(utteranceId: utteranceId)
        else { return XCTFail("expected a clean refusal") }

        XCTAssertTrue(tmux.sent.isEmpty, "nothing was ever typed anywhere")
        XCTAssertEqual(try store.utterances().first?.status, .ready,
                       "kept, not lost — the words are still there to retry")
    }

    /// A session mid-turn still takes input; Claude Code queues it.
    func testMidTurnSessionsStillAcceptReplies() async throws {
        let transport = RecordingTransport()
        transport.readinessValue = .busy
        transport.outcome = .queued
        let coordinator = try makeCoordinator(tmuxTransport: transport)
        try append()
        _ = try await coordinator.announceNext()

        guard case .readyToSend(let utteranceId, _, _, _) =
            try await coordinator.submitReply(pcm16: silence())
        else { return XCTFail("expected a pending send") }
        guard case .queued = try await coordinator.confirmAndSend(utteranceId: utteranceId)
        else { return XCTFail("a busy session must still receive the reply") }
        XCTAssertEqual(transport.sent.count, 1)
    }

    /// A liveness probe failure must never hide waiting work. It did: failure
    /// collapsed into an empty list, the filter treated "I don't know" as "nobody
    /// is home", and every session vanished silently — observed live, with two
    /// sessions the terminal could see and the app called gone.
    func testProbeFailureFailsOpenForAnnouncing() async throws {
        let registry = EnrolmentRegistry(url: tmpDir.appendingPathComponent("enrolled.json"))
        let coordinator = Coordinator(
            store: store,
            summarizer: SummarizerChain(providers: [FixedSummary()]),
            speech: SpeechChain(preferred: SilentSpeech(), fallback: SilentSpeech()),
            gate: InterruptGate(minimumIdleSeconds: 0, signals: .quiescent),
            tmuxTransport: RecordingTransport(), enrolment: registry,
            agents: FailingAgents(),
            recovery: RecoveryChain(providers: [], maxAttemptsPerProvider: 1, backoff: [0]))
        try append()

        XCTAssertEqual(try coordinator.waiting().count, 1,
                       "cannot verify liveness means announce anyway; noise is recoverable")
        XCTAssertNotNil(try coordinator.nextToAnnounce())
    }

    /// The same failure must refuse TYPING. Injecting into a session we cannot
    /// verify could answer a dialog; the asymmetry with announcing is the point.
    func testProbeFailureFailsClosedForTyping() async throws {
        let transport = RecordingTransport()
        let registry = EnrolmentRegistry(url: tmpDir.appendingPathComponent("enrolled.json"))
        try registry.enrol(sessionId: "sess-1")
        let coordinator = Coordinator(
            store: store,
            summarizer: SummarizerChain(providers: [FixedSummary()]),
            speech: SpeechChain(preferred: SilentSpeech(), fallback: SilentSpeech()),
            gate: InterruptGate(minimumIdleSeconds: 0, signals: .quiescent),
            tmuxTransport: transport, enrolment: registry,
            agents: FailingAgents(),
            recovery: RecoveryChain(
                providers: [FixedTranscript(text: "yes go ahead")],
                maxAttemptsPerProvider: 1, backoff: [0]),
            // A probe that cannot answer will not answer in twelve seconds
            // either, and this test is about the refusal, not the wait.
            readinessGrace: 0)
        try append()
        _ = try await coordinator.announceNext()

        guard case .readyToSend(let utteranceId, _, _, _) =
            try await coordinator.submitReply(pcm16: silence())
        else { return XCTFail("expected a pending send") }
        guard case .sessionNotReady = try await coordinator.confirmAndSend(utteranceId: utteranceId)
        else { return XCTFail("an unverifiable session must refuse injection") }
        XCTAssertTrue(transport.sent.isEmpty, "and nothing was typed")
    }

    /// A dialog and a dead target are the only refusals — and as of 19 Aug a
    /// dialog has two witnesses, not one: absent from the list (how it used to
    /// look) and `waitingFor: dialog open` (what the CLI says now). See
    /// `WaitingAtTests` for the rest of that pair.
    func testDialogBlockedAndGoneAreTheOnlyRefusals() {
        XCTAssertFalse(Readiness.notRegistered.canDispatch)
        XCTAssertFalse(Readiness.targetGone.canDispatch)
        XCTAssertFalse(Readiness.waiting("dialog open").canDispatch)
        XCTAssertTrue(Readiness.busy.canDispatch)
        XCTAssertTrue(Readiness.waiting(nil).canDispatch)
    }

    /// Back rooms don't get airtime. A `SubagentStop` is bookkeeping about a turn's
    /// fan-out, never something to speak: the parent turn's own `Stop` is the
    /// announcement. Two chokepoints enforce it — the hook drops SubagentStop at the
    /// source (hooks/tbase-hook.sh), and every announcement selection
    /// (`waitingSessions`, `latestStop`) filters on `hookEvent = 'Stop'` in SQL —
    /// and this test pins the second so neither can be loosened silently. It matters
    /// because the spool decoder DOES accept "SubagentStop" rows; if one ever gets
    /// past the hook, the queries must still keep it off the air.
    func testSubagentStopNeverSpeaksOnItsOwn() async throws {
        let speech = SilentSpeech()
        let coordinator = try makeCoordinator(speech: speech)
        try append(.subagentStop, at: 1_000, message: "a subagent finished")

        XCTAssertNil(try coordinator.nextToAnnounce(),
                     "a SubagentStop must never be offered for announcement")
        XCTAssertEqual(try coordinator.waitingCount(), 0, "and it never counts as waiting")
        guard case .nothingWaiting = try await coordinator.announceNext() else {
            return XCTFail("announcing with only a SubagentStop must find nothing")
        }
        XCTAssertTrue(speech.spoken.isEmpty, "back rooms don't get airtime")

        // It may ENRICH: once the parent Stop lands, the session is announceable
        // again — the subagent row changed nothing about what gets spoken.
        try append(.stop, at: 2_000, message: "the parent turn finished")
        XCTAssertEqual(try coordinator.nextToAnnounce()?.lastAssistantMessage,
                       "the parent turn finished")
    }

    func testReplyWithNoAnnouncementHasNowhereToGo() async throws {
        let coordinator = try makeCoordinator()
        guard case .noTarget = try await coordinator.submitReply(pcm16: silence()) else {
            return XCTFail("a reply with nothing to reply to must not be routed anywhere")
        }
    }

    /// A deep link names its session, and that beats "whatever you heard last".
    /// An HTML review page is ABOUT one session; its reply button must route there
    /// even if you listened to something else in between.
    func testTargetedReplyBeatsTheDerivedTarget() async throws {
        let transport = RecordingTransport()
        let coordinator = try makeCoordinator(tmuxTransport: transport)
        try append(.stop, session: "old", at: 1_000, message: "the page's session")
        try append(.stop, session: "sess-1", at: 2_000, message: "the one you heard")
        _ = try await coordinator.announceNext()   // hears sess-1
        XCTAssertEqual(try coordinator.replyTarget()?.sessionId, "sess-1")

        guard case .readyToSend(let utteranceId, _, _, let sessionId) =
            try await coordinator.submitReply(pcm16: silence(), to: "old")
        else { return XCTFail("expected a pending send") }
        XCTAssertEqual(sessionId, "old", "the link's addressing wins")

        guard case .dispatched(_, _, let sent, _) =
            try await coordinator.confirmAndSend(utteranceId: utteranceId)
        else { return XCTFail("expected dispatch") }
        XCTAssertEqual(sent, "old")
    }

    /// An unknown session id refuses rather than falling back to the derived
    /// target — a stale page must not route words into whatever you heard last.
    func testTargetedReplyToUnknownSessionRefuses() async throws {
        let coordinator = try makeCoordinator()
        try append()
        _ = try await coordinator.announceNext()

        guard case .noTarget = try await coordinator.submitReply(
            pcm16: silence(), to: "no-such-session")
        else { return XCTFail("an unknown target must refuse, not guess") }
    }

    /// The misrouting guard, restated as data. Words went to the wrong terminal once
    /// because the old rule scanned for the most recent `announced` row and stepped
    /// over a newer one that had failed. A cursor cannot step over anything.
    func testANewerTurnInvalidatesTheReplyTarget() async throws {
        let coordinator = try makeCoordinator()
        try append(.stop, at: 1_000, message: "the turn you heard")
        _ = try await coordinator.announceNext()
        XCTAssertEqual(try coordinator.replyTarget()?.sessionId, "sess-1")

        try append(.stop, at: 2_000, message: "a newer turn you have not heard")

        XCTAssertNil(try coordinator.replyTarget(),
                     "you have not heard the thing you would be answering")
    }

    /// A new agent that has not appeared in `claude agents --json` yet is waited
    /// for, not refused.
    ///
    /// Measured 19 Aug: session 0f327de7 registered at 00:21:34, bound to the
    /// card correctly, and came back `notRegistered` at 00:22:17 — so the reply
    /// was refused with "can't take this yet ... try again in a moment". Trying
    /// again is a loop, and the loop belongs here rather than in the user's
    /// hands.
    func testASessionThatArrivesLateIsWaitedForRatherThanRefused() async throws {
        let transport = RecordingTransport()
        let registry = EnrolmentRegistry(url: tmpDir.appendingPathComponent("late.json"))
        try registry.enrol(sessionId: "sess-1")
        let agents = LateAgents(appearsOnCall: 3, live: [
            LiveSession(pid: Int(ProcessInfo.processInfo.processIdentifier),
                        sessionId: "sess-1", cwd: "/tmp/p", status: "idle",
                        name: "p", waitingFor: nil)])
        let coordinator = Coordinator(
            store: store,
            summarizer: SummarizerChain(providers: [FixedSummary()]),
            speech: SpeechChain(preferred: SilentSpeech(), fallback: SilentSpeech()),
            gate: InterruptGate(minimumIdleSeconds: 0, signals: .quiescent),
            tmuxTransport: transport, enrolment: registry, agents: agents,
            recovery: RecoveryChain(
                providers: [FixedTranscript(text: "yes go ahead")],
                maxAttemptsPerProvider: 1, backoff: [0]),
            readinessGrace: 5,
            // Fabricated, not the real default: the fixture pid/cwd never
            // resolve a real tmux pane, and the point of this test is the
            // wait-for-late-arrival behavior, not resumeTwin itself — see
            // makeCoordinator's own default for the same reasoning.
            resumeTwin: { _, _ in
                TmuxPaneAddress(socketName: "tb", paneId: "%1",
                                sessionName: "tb-fixture", paneTty: "/dev/ttys999")
            })
        try append()
        // Addressed explicitly rather than through `announceNext`: the announce
        // path probes `claude agents --json` too, and this fake is about the
        // session being INVISIBLE at dispatch time, not unannounceable.
        guard case .readyToSend(let utteranceId, _, _, _) =
            try await coordinator.submitReply(pcm16: silence(), to: "sess-1")
        else { return XCTFail("expected a pending send") }

        let outcome = try await coordinator.confirmAndSend(utteranceId: utteranceId)
        guard case .dispatched = outcome else {
            return XCTFail("a late session must be waited for, got \(outcome)")
        }
        XCTAssertEqual(transport.sent.count, 1, "and the words were typed once")
        XCTAssertGreaterThan(agents.probes, 1, "which took more than one probe")
    }

    /// The other half: the grace is bounded, so an agent that never appears is
    /// still refused rather than holding the reply open.
    func testASessionThatNeverArrivesIsStillRefused() async throws {
        let transport = RecordingTransport()
        let registry = EnrolmentRegistry(url: tmpDir.appendingPathComponent("never.json"))
        try registry.enrol(sessionId: "sess-1")
        let coordinator = Coordinator(
            store: store,
            summarizer: SummarizerChain(providers: [FixedSummary()]),
            speech: SpeechChain(preferred: SilentSpeech(), fallback: SilentSpeech()),
            gate: InterruptGate(minimumIdleSeconds: 0, signals: .quiescent),
            tmuxTransport: transport, enrolment: registry,
            agents: LateAgents(appearsOnCall: .max, live: []),
            recovery: RecoveryChain(
                providers: [FixedTranscript(text: "yes go ahead")],
                maxAttemptsPerProvider: 1, backoff: [0]),
            readinessGrace: 1)
        try append()
        guard case .readyToSend(let utteranceId, _, _, _) =
            try await coordinator.submitReply(pcm16: silence(), to: "sess-1")
        else { return XCTFail("expected a pending send") }
        guard case .sessionNotReady = try await coordinator.confirmAndSend(utteranceId: utteranceId)
        else { return XCTFail("a session that never comes back must refuse") }
        XCTAssertTrue(transport.sent.isEmpty)
    }
}
