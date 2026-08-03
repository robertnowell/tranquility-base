import XCTest
@testable import VoiceDispatchCore

/// Proves the assembly, not the parts. Every component here is real except the ones
/// that would make noise or need a network — speech, summarization, and the terminal
/// itself are faked so the test can assert the *sequence*, which is the only thing
/// that has never been exercised.
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
            SessionBrief(
                topic: "Export refactor", happened: "tests pass",
                nextStep: "run the migration", branch: request.gitBranch,
                recap: "Fixing the export pipeline. Tests pass.",
                proposal: "Run the migration next. Proceed?")
        }
    }

    final class SilentSpeech: SpeechProvider, @unchecked Sendable {
        let name = "silent"
        let isConfigured = true
        var spoken: [String] = []
        var isSpeaking = false
        func speak(_ text: SanitizedSpokenText, onWord: (@Sendable (Range<Int>) -> Void)?) async throws {
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
        func sessions() -> [LiveSession] { live }
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
                ? [LiveSession(pid: Int(ProcessInfo.processInfo.processIdentifier),
                               sessionId: "sess-1", cwd: "/tmp/p", status: "idle",
                               name: "p", waitingFor: nil)]
                : []),
            recovery: RecoveryChain(
                providers: [FixedTranscript(text: "yes go ahead")],
                maxAttemptsPerProvider: 1, backoff: [0]))
    }

    private func seedEvent(promptId: String = "p1") throws {
        try store.insert(event: QueuedEvent(
            hookEvent: .stop, sessionId: "sess-1", promptId: promptId,
            cwd: "/tmp/p", lastAssistantMessage: "Refactored the export pipeline. All tests pass."))
    }

    private func silence(seconds: Double = 1) -> Data { Data(count: Int(seconds * 16000) * 2) }

    // MARK: - The full loop

    func testAnnounceThenReplyRoutesBackToTheSessionThatSpoke() async throws {
        let speech = SilentSpeech()
        let transport = RecordingTransport()
        let coordinator = try makeCoordinator(speech: speech, transport: transport)
        try seedEvent()

        // 1. It speaks the waiting item.
        guard case .spoke(let announcement) = try await coordinator.announceNext() else {
            return XCTFail("expected an announcement")
        }
        XCTAssertEqual(speech.spoken.count, 1)
        XCTAssertTrue(announcement.spoken.text.contains("Fixing the export pipeline"))
        XCTAssertTrue(announcement.spoken.text.contains("Proceed?"))

        // 2. That session becomes the reply target, derived rather than stored.
        XCTAssertEqual(try coordinator.replyTarget()?.sessionId, "sess-1")

        // 3. The reply is transcribed and routed there.
        // Transcription hands back a pending send rather than dispatching, so the
        // undo window has something to cancel.
        guard case .readyToSend(let utteranceId, _, _, _) = try await coordinator.submitReply(
            pcm16: silence(), sampleRate: 16000)
        else { return XCTFail("expected a pending send") }
        XCTAssertTrue(transport.sent.isEmpty, "nothing is typed while the window is open")

        let outcome = try await coordinator.confirmAndSend(utteranceId: utteranceId)
        guard case .dispatched(let text, _, let sessionId) = outcome else {
            return XCTFail("expected dispatch, got \(outcome)")
        }
        XCTAssertEqual(sessionId, "sess-1")
        XCTAssertEqual(transport.sent, [text])

        // 4. Both sides of the ledger close.
        XCTAssertEqual(try store.events().first?.status, .answered)
        XCTAssertEqual(try store.utterances().first?.status, .confirmed)
    }

    /// An announcement that never made a sound is still unread.
    func testAnnouncementThatNeverPlayedStaysUnread() async throws {
        final class InterruptingSpeech: SpeechProvider, @unchecked Sendable {
            let name = "interrupting"
            let isConfigured = true
            var isSpeaking = false
            func speak(_ text: SanitizedSpokenText, onWord: (@Sendable (Range<Int>) -> Void)?) async throws {
                // Never started: no audio reached the speakers.
                throw SpeechError.truncated(playedSeconds: 0, ofSeconds: 21)
            }
            func stop() {}
        }
        let registry = EnrolmentRegistry(url: tmpDir.appendingPathComponent("enrolled.json"))
        let cut = InterruptingSpeech()
        let coordinator = Coordinator(
            store: store, summarizer: SummarizerChain(providers: [FixedSummary()]),
            speech: SpeechChain(preferred: cut, fallback: cut),
            gate: InterruptGate(minimumIdleSeconds: 0, signals: .quiescent), transport: RecordingTransport(),
            enrolment: registry, agents: FakeAgents(live: []),
            recovery: RecoveryChain(providers: [], maxAttemptsPerProvider: 1, backoff: [0]))
        try seedEvent()

        guard case .interrupted = try await coordinator.announceNext() else {
            return XCTFail("expected an interrupted announcement")
        }
        XCTAssertEqual(try store.events().first?.status, .new, "still unread")
        XCTAssertNotNil(try store.events().first?.announcedAtMs,
                        "the attempt is still recorded, so nothing older can inherit the reply")
        XCTAssertNil(try coordinator.replyTarget(),
                     "you heard nothing, so there is nothing to reply to")
        XCTAssertNotNil(try coordinator.nextToAnnounce(), "offered again")
    }

    /// Audio that stops short with nobody asking is a fault, and must not be
    /// reported as a choice the user made.
    func testTruncatedPlaybackIsReportedAsAFailureNotAChoice() async throws {
        final class TruncatingSpeech: SpeechProvider, @unchecked Sendable {
            let name = "truncating"
            let isConfigured = true
            var isSpeaking = false
            func speak(_ text: SanitizedSpokenText, onWord: (@Sendable (Range<Int>) -> Void)?) async throws {
                throw SpeechError.truncated(playedSeconds: 3, ofSeconds: 19)
            }
            func stop() {}
        }
        let registry = EnrolmentRegistry(url: tmpDir.appendingPathComponent("enrolled.json"))
        let cut = TruncatingSpeech()
        let coordinator = Coordinator(
            store: store, summarizer: SummarizerChain(providers: [FixedSummary()]),
            speech: SpeechChain(preferred: cut, fallback: cut),
            gate: InterruptGate(minimumIdleSeconds: 0, signals: .quiescent), transport: RecordingTransport(),
            enrolment: registry, agents: FakeAgents(live: []),
            recovery: RecoveryChain(providers: [], maxAttemptsPerProvider: 1, backoff: [0]))
        try seedEvent()

        guard case .interrupted(let failure) = try await coordinator.announceNext() else {
            return XCTFail("expected an interrupted announcement")
        }
        XCTAssertNotNil(failure, "nobody asked for this stop — it is a fault")
        XCTAssertEqual(try store.events().first?.status, .new, "and it is still unread")
    }

    /// The regression that typed a reply into the wrong terminal.
    ///
    /// Session A is announced and heard. Session B is announced and fails. A reply
    /// must NOT go to A — it is no longer what the user was answering, and sending
    /// it there puts their words into a session they were not talking to.
    func testAFailedAnnouncementNeverHandsTheReplyToAnOlderSession() async throws {
        final class SwitchableSpeech: SpeechProvider, @unchecked Sendable {
            let name = "switchable"
            let isConfigured = true
            var isSpeaking = false
            var shouldFail = false
            func speak(_ text: SanitizedSpokenText, onWord: (@Sendable (Range<Int>) -> Void)?) async throws {
                if shouldFail { throw SpeechError.truncated(playedSeconds: 0, ofSeconds: 21) }
            }
            func stop() {}
        }
        let speech = SwitchableSpeech()
        let registry = EnrolmentRegistry(url: tmpDir.appendingPathComponent("enrolled.json"))
        try registry.enrol(sessionId: "sess-A")
        try registry.enrol(sessionId: "sess-B")
        let coordinator = Coordinator(
            store: store, summarizer: SummarizerChain(providers: [FixedSummary()]),
            speech: SpeechChain(preferred: speech, fallback: speech),
            gate: InterruptGate(minimumIdleSeconds: 0, signals: .quiescent), transport: RecordingTransport(),
            enrolment: registry, agents: FakeAgents(live: []),
            recovery: RecoveryChain(providers: [], maxAttemptsPerProvider: 1, backoff: [0]))

        try store.insert(event: QueuedEvent(
            createdAtMs: 1_000, hookEvent: .stop, sessionId: "sess-A", promptId: "a",
            cwd: "/tmp/a", lastAssistantMessage: "session A finished"))
        guard case .spoke = try await coordinator.announceNext() else {
            return XCTFail("A should be heard")
        }
        XCTAssertEqual(try coordinator.replyTarget()?.sessionId, "sess-A")

        // B finishes and its announcement fails — nothing is heard.
        speech.shouldFail = true
        try store.insert(event: QueuedEvent(
            createdAtMs: 9_000, hookEvent: .stop, sessionId: "sess-B", promptId: "b",
            cwd: "/tmp/b", lastAssistantMessage: "session B finished"))
        guard case .interrupted = try await coordinator.announceNext() else {
            return XCTFail("B should have failed to play")
        }

        XCTAssertNil(try coordinator.replyTarget(),
                     "A must not inherit the reply — the user never heard B, and a "
                     + "refusal is recoverable where a misrouted reply is not")
    }

    /// Half an announcement tells you half of what happened, so stopping part-way
    /// leaves it waiting. Only hearing it out, or dismissing it, marks it read.
    func testStoppingPartWayLeavesItWaiting() async throws {
        final class HalfSpoken: SpeechProvider, @unchecked Sendable {
            let name = "half"
            let isConfigured = true
            var isSpeaking = false
            func speak(_ text: SanitizedSpokenText, onWord: (@Sendable (Range<Int>) -> Void)?) async throws {
                throw SpeechError.truncated(playedSeconds: 4, ofSeconds: 19)
            }
            func stop() {}
        }
        let registry = EnrolmentRegistry(url: tmpDir.appendingPathComponent("enrolled.json"))
        let half = HalfSpoken()
        let coordinator = Coordinator(
            store: store, summarizer: SummarizerChain(providers: [FixedSummary()]),
            speech: SpeechChain(preferred: half, fallback: half),
            gate: InterruptGate(minimumIdleSeconds: 0, signals: .quiescent), transport: RecordingTransport(),
            enrolment: registry, agents: FakeAgents(live: []),
            recovery: RecoveryChain(providers: [], maxAttemptsPerProvider: 1, backoff: [0]))
        try seedEvent()

        guard case .interrupted = try await coordinator.announceNext() else {
            return XCTFail("expected a part-way stop")
        }
        XCTAssertEqual(try store.events().first?.status, .new, "still waiting")
        XCTAssertNotNil(try coordinator.nextToAnnounce(), "offered again")
        XCTAssertNil(try coordinator.replyTarget(),
                     "you did not hear it out, so there is nothing to answer yet")
    }

    /// Dismiss means gone: out of the queue, not merely off the screen.
    func testDismissRemovesTheItemFromTheQueue() async throws {
        let coordinator = try makeCoordinator()
        try seedEvent()
        let event = try XCTUnwrap(store.events().first)

        try coordinator.dismiss(eventId: event.id)

        XCTAssertEqual(try store.events().first?.status, .dismissed)
        XCTAssertNil(try coordinator.nextToAnnounce())
        XCTAssertEqual(try store.pendingCount(), 0)
    }

    /// Tapping again must reach a different session. Stopping leaves an item
    /// unread and it is also the newest, so newest-first replayed it forever.
    func testStoppedItemDoesNotBlockTheRest() async throws {
        try store.insert(event: QueuedEvent(
            createdAtMs: 9_000, hookEvent: .stop, sessionId: "sess-1", promptId: "newest",
            cwd: "/tmp/a", lastAssistantMessage: "newest"))
        try store.insert(event: QueuedEvent(
            createdAtMs: 5_000, hookEvent: .stop, sessionId: "sess-2", promptId: "older",
            cwd: "/tmp/b", lastAssistantMessage: "older"))
        let coordinator = try makeCoordinator()

        XCTAssertEqual(try coordinator.nextToAnnounce()?.promptId, "newest")

        // Offered, then stopped: still unread, but no longer the thing to offer.
        var offered = try XCTUnwrap(store.events().first { $0.promptId == "newest" })
        offered.announcedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        try store.update(event: offered)

        XCTAssertEqual(try coordinator.nextToAnnounce()?.promptId, "older",
                       "a stopped item must not monopolise the queue")
    }

    /// Replying while it is still talking is the normal case — you answer as soon
    /// as you have heard enough. Stopping playback to record must not revert the
    /// announcement, or the reply has nowhere to go and is thrown away.
    func testReplyingDuringPlaybackKeepsItsTarget() async throws {
        let transport = RecordingTransport()
        let coordinator = try makeCoordinator(transport: transport)
        try seedEvent()
        _ = try await coordinator.announceNext()
        let event = try XCTUnwrap(store.events().first)

        // What the app does when a reply begins mid-announcement.
        try coordinator.markHeard(eventId: event.id)

        // What the announce task then does to an interrupted item.
        var reverted = try XCTUnwrap(store.events().first)
        reverted.status = .new
        try store.update(event: reverted)

        // And the app's re-apply, which runs after the revert.
        try coordinator.markHeard(eventId: event.id)

        XCTAssertEqual(try coordinator.replyTarget()?.sessionId, "sess-1",
                       "the announcement you are answering must still be the target")
        guard case .readyToSend = try await coordinator.submitReply(pcm16: silence())
        else { return XCTFail("the reply must have somewhere to go") }
    }

    /// Saying it again during the send window replaces the reply rather than
    /// queueing a second one — and the rejected recording is kept, not deleted.
    func testSayingItAgainReplacesThePendingReply() async throws {
        let transport = RecordingTransport()
        let coordinator = try makeCoordinator(transport: transport)
        try seedEvent()
        _ = try await coordinator.announceNext()

        guard case .readyToSend(let firstId, _, _, _) =
            try await coordinator.submitReply(pcm16: silence())
        else { return XCTFail("expected a pending send") }

        try coordinator.cancelSend(utteranceId: firstId)

        guard case .readyToSend(let secondId, _, _, _) =
            try await coordinator.submitReply(pcm16: silence())
        else { return XCTFail("the second attempt must also be sendable") }
        XCTAssertNotEqual(firstId, secondId)

        guard case .dispatched = try await coordinator.confirmAndSend(utteranceId: secondId)
        else { return XCTFail("the newer reply is the one that goes") }

        XCTAssertEqual(transport.sent.count, 1, "exactly one reply reaches the session")
        let statuses = try store.utterances().reduce(into: [String: UtteranceStatus]()) {
            $0[$1.id] = $1.status
        }
        XCTAssertEqual(statuses[firstId], .discarded, "kept, but out of the sendable set")
        XCTAssertEqual(statuses[secondId], .confirmed)
        XCTAssertNotNil(try store.utterances().first { $0.id == firstId }?.audioPath,
                        "you rejected the words, not the recording")
    }

    /// Two voices talking over each other is the worst thing this app can do, and
    /// the slow path is exactly when a second press happens. A stop must silence
    /// what is coming as well as what is already playing.
    func testStopBeforeFallbackSpeaksNothing() async throws {
        final class SlowFailing: SpeechProvider, @unchecked Sendable {
            let name = "slow"
            let isConfigured = true
            var isSpeaking = false
            func speak(_ text: SanitizedSpokenText, onWord: (@Sendable (Range<Int>) -> Void)?) async throws {
                try? await Task.sleep(nanoseconds: 100_000_000)
                throw SpeechError.synthesisFailed("network")  // would fall back
            }
            func stop() {}
        }
        final class CountingVoice: SpeechProvider, @unchecked Sendable {
            let name = "counting"
            let isConfigured = true
            var isSpeaking = false
            var spoke = 0
            func speak(_ text: SanitizedSpokenText, onWord: (@Sendable (Range<Int>) -> Void)?) async throws {
                spoke += 1
            }
            func stop() {}
        }
        let fallback = CountingVoice()
        let chain = SpeechChain(preferred: SlowFailing(), fallback: fallback)
        let text = SpokenTextSanitizer().sanitize("This should never be read aloud.")

        async let spoken = chain.speak(text)
        try await Task.sleep(nanoseconds: 20_000_000)
        chain.stop()   // pressed again while the first was still fetching
        let result = await spoken

        XCTAssertEqual(fallback.spoke, 0,
                       "a cancelled announcement must not reappear in the system voice")
        XCTAssertFalse(result.completed)
    }

    /// A session mid-turn still takes input. Claude Code holds typed text in the
    /// input box and sends it when the turn ends, which is exactly what a person
    /// does, so refusing was a self-imposed limit rather than a safety property.
    func testMidTurnSessionsStillAcceptReplies() async throws {
        let transport = RecordingTransport()
        transport.readinessValue = .busy
        transport.outcome = .queued
        let coordinator = try makeCoordinator(transport: transport)
        try seedEvent()
        _ = try await coordinator.announceNext()

        guard case .readyToSend(let utteranceId, _, _, _) =
            try await coordinator.submitReply(pcm16: silence())
        else { return XCTFail("expected a pending send") }

        guard case .queued = try await coordinator.confirmAndSend(utteranceId: utteranceId)
        else { return XCTFail("a busy session must still receive the reply") }

        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual(try store.utterances().first?.status, .confirmed,
                       "the words are in the tab; nothing else is required of anyone")
        XCTAssertEqual(try store.events().first?.status, .answered)
    }

    /// The one state that must still refuse: alive but absent from the agents API
    /// means blocked on a modal, where typed text would answer the dialog.
    func testDialogBlockedSessionsStillRefuse() async throws {
        XCTAssertFalse(Readiness.notRegistered.canDispatch)
        XCTAssertFalse(Readiness.targetGone.canDispatch)
        XCTAssertTrue(Readiness.busy.canDispatch)
        XCTAssertTrue(Readiness.waiting(nil).canDispatch)
    }

    /// Nothing waiting means nothing waiting. Catch-up used to run automatically
    /// once the unread was empty, so every press replayed something already heard
    /// and new arrivals were indistinguishable from old ones being read again.
    /// History is still reachable, but only by asking for it.
    func testHistoryIsNotReplayedAutomatically() async throws {
        let coordinator = try makeCoordinator()
        try seedEvent()

        guard case .spoke = try await coordinator.announceNext() else {
            return XCTFail("expected the unread item")
        }
        guard case .nothingWaiting = try await coordinator.announceNext() else {
            return XCTFail("with nothing unread, pressing again must do nothing")
        }
        XCTAssertNotNil(try coordinator.nextForCatchUp(),
                        "history still exists for the waiting list to offer")
    }

    /// Catching up must not resurface what a session has already replaced, what you
    /// answered, or what you dismissed.
    func testCatchUpSkipsSupersededAnsweredAndDismissed() async throws {
        let coordinator = try makeCoordinator()
        for (index, status) in [EventStatus.superseded, .answered, .dismissed].enumerated() {
            var event = QueuedEvent(
                createdAtMs: Int64(1_000 + index), hookEvent: .stop, sessionId: "s\(index)",
                promptId: "p\(index)", cwd: "/tmp", lastAssistantMessage: "m")
            event.status = status
            event.summaryText = "a summary"
            event.announcedAtMs = 1_000
            _ = try store.insert(event: event)
            try store.update(event: event)
        }

        XCTAssertNil(try coordinator.nextForCatchUp(),
                     "history is what you have not dealt with, not everything that happened")
    }

    /// Nothing is announced twice AS NEW. It can come back as catch-up once the
    /// unread is exhausted, which is a different claim and a deliberate one: the
    /// badge and the "new" framing must only ever mean genuinely unheard.
    /// Typing into a session yourself means the agent is no longer the last turn
    /// there, so it is not waiting on you and must not come back in catch-up.
    func testTypingIntoASessionRemovesItFromHistoryToo() async throws {
        let coordinator = try makeCoordinator()
        try seedEvent()
        guard case .spoke = try await coordinator.announceNext() else {
            return XCTFail("expected an announcement")
        }
        XCTAssertNotNil(try coordinator.nextForCatchUp(), "heard, and replayable")

        _ = try coordinator.invalidatePending(sessionId: "sess-1")

        XCTAssertNil(try coordinator.nextForCatchUp(),
                     "you answered it yourself, so there is nothing to catch up on")
    }

    /// Headless runs are machine-driven and unanswerable, and because every run
    /// gets a new session id, supersession cannot collapse them: a daily job adds a
    /// near-identical unread row every day until the queue is nothing else.
    func testHeadlessRunsAreNeverOfferedOrCounted() async throws {
        let coordinator = try makeCoordinator()
        try store.insert(event: QueuedEvent(
            createdAtMs: 9_000, hookEvent: .stop, sessionId: "cron-1", promptId: "h1",
            cwd: "/tmp/job", lastAssistantMessage: "a nightly job finished", tty: "??"))
        try store.insert(event: QueuedEvent(
            createdAtMs: 1_000, hookEvent: .stop, sessionId: "human-1", promptId: "i1",
            cwd: "/tmp/work", lastAssistantMessage: "your session finished", tty: "ttys012"))

        XCTAssertEqual(try coordinator.nextToAnnounce()?.promptId, "i1",
                       "the human session wins even though the job is newer")
        XCTAssertEqual(try store.pendingCount(), 1, "and the badge agrees")
        XCTAssertEqual(try coordinator.waiting().count, 1)
    }

    /// A row written before the terminal was recorded is unknown, not headless.
    /// Treating unknown as headless would silently stop announcing real sessions.
    func testUnknownTerminalIsNotTreatedAsHeadless() async throws {
        let coordinator = try makeCoordinator()
        try store.insert(event: QueuedEvent(
            hookEvent: .stop, sessionId: "old-row", promptId: "o1",
            cwd: "/tmp", lastAssistantMessage: "written before tty was recorded"))

        XCTAssertNotNil(try coordinator.nextToAnnounce())
        XCTAssertEqual(try store.pendingCount(), 1)
    }

    /// Skipping must actually skip. Reverting a stopped item to unread left it as
    /// the newest, so the stack handed it straight back and pressing again replayed
    /// what you had just skipped, with no way past it.
    func testDismissingWhileSpeakingReachesTheNextItem() async throws {
        let coordinator = try makeCoordinator()
        try store.insert(event: QueuedEvent(
            createdAtMs: 9_000, hookEvent: .stop, sessionId: "s-new", promptId: "newer",
            cwd: "/tmp/a", lastAssistantMessage: "the newer one"))
        try store.insert(event: QueuedEvent(
            createdAtMs: 1_000, hookEvent: .stop, sessionId: "s-old", promptId: "older",
            cwd: "/tmp/b", lastAssistantMessage: "the older one"))

        guard case .spoke(let first) = try await coordinator.announceNext() else {
            return XCTFail("expected the newest")
        }
        XCTAssertEqual(first.event.promptId, "newer")

        // What ⌃⌥ now does before announcing again.
        try coordinator.dismiss(eventId: first.event.id)

        XCTAssertEqual(try coordinator.nextToAnnounce()?.promptId, "older",
                       "the skipped item must not be handed back")
        XCTAssertNil(try store.events().first { $0.promptId == "newer" }
                        .flatMap { $0.status == .dismissed ? nil : $0 },
                     "and it is retired, not merely reordered")
    }

    /// A dismissal during playback must survive the interrupt handler.
    ///
    /// The handler reverted a stopped announcement to unread by writing back a copy
    /// captured before the audio started. That copy did not know about the
    /// dismissal, so it resurrected the row and the next press replayed the item
    /// that had just been retired, word for word, forever.
    func testDismissDuringPlaybackIsNotResurrected() async throws {
        final class Interrupting: SpeechProvider, @unchecked Sendable {
            let name = "interrupting"
            let isConfigured = true
            var isSpeaking = false
            var onSpeak: (@Sendable () -> Void)?
            func speak(_ text: SanitizedSpokenText, onWord: (@Sendable (Range<Int>) -> Void)?) async throws {
                onSpeak?()                       // the user presses next, mid-audio
                throw SpeechError.interrupted
            }
            func stop() {}
        }
        let speech = Interrupting()
        let registry = EnrolmentRegistry(url: tmpDir.appendingPathComponent("enrolled.json"))
        let coordinator = Coordinator(
            store: store, summarizer: SummarizerChain(providers: [FixedSummary()]),
            speech: SpeechChain(preferred: speech, fallback: speech),
            gate: InterruptGate(minimumIdleSeconds: 0, signals: .quiescent),
            transport: RecordingTransport(), enrolment: registry,
            agents: FakeAgents(live: []),
            recovery: RecoveryChain(providers: [], maxAttemptsPerProvider: 1, backoff: [0]))
        try seedEvent()
        let eventId = try XCTUnwrap(store.events().first).id
        speech.onSpeak = { [store] in
            var event = try! store!.events().first { $0.id == eventId }!
            event.status = .dismissed
            try! store!.update(event: event)
        }

        _ = try await coordinator.announceNext()

        XCTAssertEqual(try store.events().first?.status, .dismissed,
                       "the dismissal stands; the stale copy must not overwrite it")
        XCTAssertNil(try coordinator.nextToAnnounce(), "and it is not offered again")
    }

    /// The ordinary conversation, which was completely broken.
    ///
    /// You type, the agent works, the agent finishes. That finished turn is a reply
    /// to you and is exactly what you want to hear. Retiring everything for the
    /// session when you typed meant the reply was retired the moment you sent your
    /// next message, so an active session could never have anything waiting.
    func testATurnThatArrivesAfterYouTypedIsStillOffered() async throws {
        let coordinator = try makeCoordinator()

        // You type at t=1000.
        try store.insert(event: QueuedEvent(
            createdAtMs: 1_000, hookEvent: .stop, sessionId: "sess-1", promptId: "before",
            cwd: "/tmp", lastAssistantMessage: "an older turn you never got to"))
        XCTAssertEqual(try store.supersedePending(
            sessionId: "sess-1", before: 1_000, includeAnnounced: true), 0)

        // The agent replies at t=2000.
        try store.insert(event: QueuedEvent(
            createdAtMs: 2_000, hookEvent: .stop, sessionId: "sess-1", promptId: "after",
            cwd: "/tmp", lastAssistantMessage: "the reply to what you just typed"))
        _ = try store.supersedePending(sessionId: "sess-1", before: 1_000, includeAnnounced: true)

        XCTAssertEqual(try coordinator.nextToAnnounce()?.promptId, "after",
                       "the reply to your message must survive your message")
    }

    func testNothingIsAnnouncedTwiceAsNew() async throws {
        let speech = SilentSpeech()
        let coordinator = try makeCoordinator(speech: speech)
        try seedEvent()

        guard case .spoke(let first) = try await coordinator.announceNext() else {
            return XCTFail("expected an announcement")
        }
        XCTAssertFalse(first.isCatchUp)
        XCTAssertNil(try coordinator.nextToAnnounce(), "no longer unread")
        XCTAssertEqual(try store.pendingCount(), 0, "and the badge says so")

        guard case .nothingWaiting = try await coordinator.announceNext() else {
            return XCTFail("an announced item is not offered again unprompted")
        }
        _ = first
    }

    /// A session speaks for itself in the present tense. Four turns back is not a
    /// backlog to work through — it is a description of a state the session has
    /// already left, and reading it out is actively misleading.
    func testOnlyTheNewestTurnOfASessionIsOffered() async throws {
        try store.insert(event: QueuedEvent(
            createdAtMs: 1_000, hookEvent: .stop, sessionId: "sess-1", promptId: "old",
            cwd: "/tmp/old", lastAssistantMessage: "older"))
        try store.insert(event: QueuedEvent(
            createdAtMs: 9_000, hookEvent: .stop, sessionId: "sess-1", promptId: "new",
            cwd: "/tmp/new", lastAssistantMessage: "newer"))

        let coordinator = try makeCoordinator()
        XCTAssertEqual(try coordinator.nextToAnnounce()?.promptId, "new")

        let statuses = try store.events().reduce(into: [String: EventStatus]()) {
            if let id = $1.promptId { $0[id] = $1.status }
        }
        XCTAssertEqual(statuses["old"], .superseded, "the stale turn is retired, not queued behind")
    }

    /// Sessions do not queue behind each other either — each keeps its own slot,
    /// and the most recently finished one is what you hear.
    func testEachSessionKeepsItsOwnSlot() async throws {
        try store.insert(event: QueuedEvent(
            createdAtMs: 1_000, hookEvent: .stop, sessionId: "sess-1", promptId: "a",
            cwd: "/tmp/a", lastAssistantMessage: "session one"))
        try store.insert(event: QueuedEvent(
            createdAtMs: 5_000, hookEvent: .stop, sessionId: "sess-2", promptId: "b",
            cwd: "/tmp/b", lastAssistantMessage: "session two"))

        let coordinator = try makeCoordinator()
        XCTAssertEqual(try coordinator.nextToAnnounce()?.promptId, "b")

        let statuses = try store.events().reduce(into: [String: EventStatus]()) {
            if let id = $1.promptId { $0[id] = $1.status }
        }
        XCTAssertEqual(statuses["a"], .new, "another session's turn is not superseded by yours")
    }

    /// You typed into that session yourself, so you already know. Reading out a
    /// summary of the state you just moved past is worse than saying nothing.
    func testTypingIntoASessionRetiresWhatWasWaitingForIt() async throws {
        try seedEvent()
        let coordinator = try makeCoordinator()
        XCTAssertNotNil(try coordinator.nextToAnnounce())

        XCTAssertEqual(try coordinator.invalidatePending(sessionId: "sess-1"), 1)

        XCTAssertNil(try coordinator.nextToAnnounce())
        XCTAssertEqual(try store.events().first?.status, .superseded)
    }

    // MARK: - The gate can only delay

    func testGateVetoLeavesTheItemQueuedRatherThanDroppingIt() async throws {
        let speech = SilentSpeech()
        // A gate that always vetoes: nothing is idle for a negative duration.
        let coordinator = try makeCoordinator(
            speech: speech,
            // Says it plainly: you are mid-keystroke, and the gate wants eight
            // seconds of quiet. Expressing the veto through a real signal rather
            // than an impossible threshold is also what the gate does in life.
            gate: InterruptGate(
                minimumIdleSeconds: 8,
                signals: .init(idleSeconds: { 0 }, frontmostApp: { nil },
                               screenLocked: { false })))
        try seedEvent()

        guard case .held = try await coordinator.announceNext() else {
            return XCTFail("expected the gate to hold it")
        }
        XCTAssertTrue(speech.spoken.isEmpty)
        XCTAssertEqual(try store.events().first?.status, .held)

        // Still offered once the veto lifts — a held item is delayed, never lost.
        XCTAssertNotNil(try coordinator.nextToAnnounce())
        guard case .spoke = try await coordinator.announceNext(ignoringGate: true) else {
            return XCTFail("a held item must still be announceable")
        }
    }

    // MARK: - Refusals

    /// Transcribing must never type anything by itself, enrolled or not. Dispatch
    /// happens only once the undo window has closed.
    func testTranscribingNeverTypesAnything() async throws {
        let transport = RecordingTransport()
        let coordinator = try makeCoordinator(transport: transport, enrolled: false)
        try seedEvent()
        _ = try await coordinator.announceNext()

        let outcome = try await coordinator.submitReply(pcm16: silence())

        guard case .readyToSend = outcome else { return XCTFail("expected a pending send, got \(outcome)") }
        XCTAssertTrue(transport.sent.isEmpty, "nothing is typed before the window closes")
        XCTAssertNotNil(try store.utterances().first?.audioPath, "the recording is kept")
    }

    /// Stopping it must actually stop it — and must not leave the recording looking
    /// sendable, or a later sweep could deliver words you rejected.
    func testCancellingLeavesNothingSendable() async throws {
        let transport = RecordingTransport()
        let coordinator = try makeCoordinator(transport: transport)
        try seedEvent()
        _ = try await coordinator.announceNext()

        guard case .readyToSend(let utteranceId, _, _, _) =
            try await coordinator.submitReply(pcm16: silence())
        else { return XCTFail("expected a pending send") }

        try coordinator.cancelSend(utteranceId: utteranceId)

        XCTAssertTrue(transport.sent.isEmpty)
        XCTAssertEqual(try store.utterances().first?.status, .discarded)
        XCTAssertNotEqual(try store.events().first?.status, .answered,
                          "the session is still owed an answer")
    }

    /// Absent from `claude agents --json` means blocked on a dialog. Injecting would
    /// answer that dialog, so we refuse — and keep the audio for a later attempt.
    func testSessionMissingFromTheAgentsApiIsRefusedNotGuessed() async throws {
        let transport = RecordingTransport()
        let coordinator = try makeCoordinator(transport: transport, sessionLive: false)
        try seedEvent()
        _ = try await coordinator.announceNext()

        guard case .readyToSend(let utteranceId, _, _, _) =
            try await coordinator.submitReply(pcm16: silence())
        else { return XCTFail("expected a pending send") }

        let outcome = try await coordinator.confirmAndSend(utteranceId: utteranceId)
        guard case .sessionNotReady(.notRegistered) = outcome else {
            return XCTFail("expected refusal, got \(outcome)")
        }
        XCTAssertTrue(transport.sent.isEmpty)
        XCTAssertEqual(try store.utterances().first?.status, .ready, "kept, ready to retry")
    }

    func testAmbiguousDispatchIsNeverMarkedConfirmedOrRetried() async throws {
        let transport = RecordingTransport()
        transport.outcome = .failed(.verificationTimedOut)
        let coordinator = try makeCoordinator(transport: transport)
        try seedEvent()
        _ = try await coordinator.announceNext()

        guard case .readyToSend(let utteranceId, _, _, _) =
            try await coordinator.submitReply(pcm16: silence())
        else { return XCTFail("expected a pending send") }

        let outcome = try await coordinator.confirmAndSend(utteranceId: utteranceId)
        guard case .dispatchFailed(.verificationTimedOut, _) = outcome else {
            return XCTFail("expected an ambiguous result, got \(outcome)")
        }
        XCTAssertEqual(try store.utterances().first?.status, .dispatchedUnconfirmed,
                       "must not claim success, and must not silently resend")
        XCTAssertEqual(transport.sent.count, 1, "exactly one attempt — a duplicate is worse than a drop")
        XCTAssertNotEqual(try store.events().first?.status, .answered)
    }

    /// The summary is written before it is asked for, so pressing plays audio
    /// rather than starting a model call you have to wait through.
    func testPreparedSummaryIsUsedInsteadOfSummarizingOnDemand() async throws {
        final class CountingSummary: SummaryProvider, @unchecked Sendable {
            let name = "counting"
            let isConfigured = true
            var calls = 0
            func brief(for request: SummaryRequest) async throws -> SessionBrief {
                calls += 1
                return SessionBrief(topic: "T", happened: "H", recap: "R", proposal: "P")
            }
        }
        let counting = CountingSummary()
        let registry = EnrolmentRegistry(url: tmpDir.appendingPathComponent("enrolled.json"))
        let coordinator = Coordinator(
            store: store, summarizer: SummarizerChain(providers: [counting]),
            speech: SpeechChain(preferred: SilentSpeech(), fallback: SilentSpeech()),
            gate: InterruptGate(minimumIdleSeconds: 0, signals: .quiescent), transport: RecordingTransport(),
            enrolment: registry, agents: FakeAgents(live: []),
            recovery: RecoveryChain(providers: [], maxAttemptsPerProvider: 1, backoff: [0]))
        try seedEvent()

        try await coordinator.prepareNext()
        XCTAssertEqual(counting.calls, 1)

        try await coordinator.prepareNext()
        XCTAssertEqual(counting.calls, 1, "already-prepared work is not repeated")

        guard case .spoke = try await coordinator.announceNext() else {
            return XCTFail("expected the prepared summary to be spoken")
        }
        XCTAssertEqual(counting.calls, 1, "announcing must not summarize again")
    }

    /// An unenrolled session is no longer a dead end: the transcript is kept ready
    /// and the undo window closing sends it.
    func testUnenrolledReplyStaysSendableAndSendsWhenTheWindowCloses() async throws {
        let transport = RecordingTransport()
        let coordinator = try makeCoordinator(transport: transport, enrolled: false)
        try seedEvent()
        _ = try await coordinator.announceNext()

        guard case .readyToSend(let utteranceId, _, _, _) =
            try await coordinator.submitReply(pcm16: silence())
        else { return XCTFail("expected a pending send") }
        XCTAssertEqual(try store.utterances().first?.status, .ready, "still sendable")
        XCTAssertTrue(transport.sent.isEmpty)

        // Letting the window close enrols the session — choosing not to stop it is
        // the consent, so a first reply needs no separate approval.
        guard case .dispatched = try await coordinator.confirmAndSend(utteranceId: utteranceId)
        else { return XCTFail("letting it send must dispatch the recording already made") }
        XCTAssertEqual(transport.sent.count, 1, "no re-recording required")
        XCTAssertEqual(try store.utterances().first?.status, .confirmed)
    }

    func testReplyWithNoAnnouncementHasNowhereToGo() async throws {
        let coordinator = try makeCoordinator()
        guard case .noTarget = try await coordinator.submitReply(pcm16: silence()) else {
            return XCTFail("a reply with nothing to reply to must not be routed anywhere")
        }
    }

    func testReplyTargetExpires() async throws {
        let coordinator = try makeCoordinator()
        try seedEvent()
        _ = try await coordinator.announceNext()
        XCTAssertNotNil(try coordinator.replyTarget())

        // Age the announcement past the window.
        var event = try XCTUnwrap(store.events().first)
        event.announcedAtMs = Int64(Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1000)
        try store.update(event: event)

        XCTAssertNil(try coordinator.replyTarget(),
                     "a stale announcement must not silently capture a later reply")
    }
}
