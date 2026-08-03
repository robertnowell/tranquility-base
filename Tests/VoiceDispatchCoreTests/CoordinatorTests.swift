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
        gate: InterruptGate = InterruptGate(minimumIdleSeconds: 0)
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
            gate: InterruptGate(minimumIdleSeconds: 0), transport: RecordingTransport(),
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
            gate: InterruptGate(minimumIdleSeconds: 0), transport: RecordingTransport(),
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
            gate: InterruptGate(minimumIdleSeconds: 0), transport: RecordingTransport(),
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
            gate: InterruptGate(minimumIdleSeconds: 0), transport: RecordingTransport(),
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

    func testNothingIsAnnouncedTwice() async throws {
        let speech = SilentSpeech()
        let coordinator = try makeCoordinator(speech: speech)
        try seedEvent()

        _ = try await coordinator.announceNext()
        let second = try await coordinator.announceNext()

        guard case .nothingWaiting = second else {
            return XCTFail("an announced event must not be offered again")
        }
        XCTAssertEqual(speech.spoken.count, 1)
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
            speech: speech, gate: InterruptGate(minimumIdleSeconds: .greatestFiniteMagnitude))
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
            gate: InterruptGate(minimumIdleSeconds: 0), transport: RecordingTransport(),
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
