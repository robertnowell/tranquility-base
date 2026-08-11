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
        func speak(_ text: SanitizedSpokenText, onWord: (@Sendable (Range<Int>) -> Void)?) async throws {
            if interrupt { throw SpeechError.interrupted }
            spoken.append(text.text)
        }
        func stop() {}
    }

    final class RecordingTransport: DispatchTransport, @unchecked Sendable {
        let kind = TransportKind.terminalApp
        var sent: [String] = []
        var outcome: DispatchOutcome = .confirmed(latencyMs: 42)
        var readinessValue: Readiness = .ready
        func readiness(for target: DispatchTarget) async -> Readiness { readinessValue }
        func send(text: String, to target: DispatchTarget) async -> DispatchOutcome {
            sent.append(text)
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
        transport: RecordingTransport = RecordingTransport(),
        enrolled: Bool = true,
        sessionLive: Bool = true,
        gate: InterruptGate = InterruptGate(minimumIdleSeconds: 0, signals: .quiescent)
    ) throws -> Coordinator {
        let registry = EnrolmentRegistry(url: tmpDir.appendingPathComponent("enrolled.json"))
        if enrolled { try registry.enrol(sessionId: "sess-1") }
        return Coordinator(
            store: store,
            summarizer: SummarizerChain(providers: [FixedSummary()]),
            speech: SpeechChain(preferred: speech, fallback: speech),
            gate: gate,
            transport: transport,
            enrolment: registry,
            agents: FakeAgents(live: sessionLive
                ? ["sess-1", "old", "new", "human", "cron", "waiting-one"].map {
                    LiveSession(pid: Int(ProcessInfo.processInfo.processIdentifier),
                                sessionId: $0, cwd: "/tmp/p", status: "idle",
                                name: "p", waitingFor: nil)
                  }
                : []),
            recovery: RecoveryChain(
                providers: [FixedTranscript(text: "yes go ahead")],
                maxAttemptsPerProvider: 1, backoff: [0]))
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

    // MARK: - The full loop

    func testAnnounceThenReplyRoutesBackToTheSessionThatSpoke() async throws {
        let speech = SilentSpeech()
        let transport = RecordingTransport()
        let coordinator = try makeCoordinator(speech: speech, transport: transport)
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

        guard case .dispatched(let text, _, let sessionId) =
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

    /// Stopping half way must not consume the turn: half an announcement tells you
    /// half of what happened. Nothing is written before the audio, so there is no
    /// stale copy for a later handler to write back over a dismissal.
    func testStoppingPartWayLeavesItWaitingAndWritesNothing() async throws {
        let speech = SilentSpeech()
        speech.interrupt = true
        let coordinator = try makeCoordinator(speech: speech)
        try append()

        guard case .interrupted = try await coordinator.announceNext() else {
            return XCTFail("expected an interrupted announcement")
        }
        XCTAssertNotNil(try coordinator.nextToAnnounce(), "still waiting")
        XCTAssertNil(try store.cursor(for: "sess-1")?.heardThrough,
                     "hearing it through is the only thing that advances the cursor")
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
            transport: RecordingTransport(), enrolment: registry,
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
            transport: RecordingTransport(), enrolment: registry,
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
        let coordinator = try makeCoordinator(transport: transport, enrolled: false)
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
        let live = try makeCoordinator(transport: transport)
        try append()
        _ = try await live.announceNext()
        guard case .readyToSend(let utteranceId, _, _, _) =
            try await live.submitReply(pcm16: silence())
        else { return XCTFail("expected a pending send") }

        let coordinator = try makeCoordinator(transport: transport, sessionLive: false)

        guard case .sessionNotReady(.notRegistered) =
            try await coordinator.confirmAndSend(utteranceId: utteranceId)
        else { return XCTFail("expected a refusal") }
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testAmbiguousDispatchIsNeverMarkedConfirmedOrRetried() async throws {
        let transport = RecordingTransport()
        transport.outcome = .failed(.verificationTimedOut)
        let coordinator = try makeCoordinator(transport: transport)
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

    /// A session mid-turn still takes input; Claude Code queues it.
    func testMidTurnSessionsStillAcceptReplies() async throws {
        let transport = RecordingTransport()
        transport.readinessValue = .busy
        transport.outcome = .queued
        let coordinator = try makeCoordinator(transport: transport)
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
            transport: RecordingTransport(), enrolment: registry,
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
            transport: transport, enrolment: registry,
            agents: FailingAgents(),
            recovery: RecoveryChain(
                providers: [FixedTranscript(text: "yes go ahead")],
                maxAttemptsPerProvider: 1, backoff: [0]))
        try append()
        _ = try await coordinator.announceNext()

        guard case .readyToSend(let utteranceId, _, _, _) =
            try await coordinator.submitReply(pcm16: silence())
        else { return XCTFail("expected a pending send") }
        guard case .sessionNotReady = try await coordinator.confirmAndSend(utteranceId: utteranceId)
        else { return XCTFail("an unverifiable session must refuse injection") }
        XCTAssertTrue(transport.sent.isEmpty, "and nothing was typed")
    }

    func testDialogBlockedAndGoneAreTheOnlyRefusals() {
        XCTAssertFalse(Readiness.notRegistered.canDispatch)
        XCTAssertFalse(Readiness.targetGone.canDispatch)
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
        let coordinator = try makeCoordinator(transport: transport)
        try append(.stop, session: "old", at: 1_000, message: "the page's session")
        try append(.stop, session: "sess-1", at: 2_000, message: "the one you heard")
        _ = try await coordinator.announceNext()   // hears sess-1
        XCTAssertEqual(try coordinator.replyTarget()?.sessionId, "sess-1")

        guard case .readyToSend(let utteranceId, _, _, let sessionId) =
            try await coordinator.submitReply(pcm16: silence(), to: "old")
        else { return XCTFail("expected a pending send") }
        XCTAssertEqual(sessionId, "old", "the link's addressing wins")

        guard case .dispatched(_, _, let sent) =
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
}
