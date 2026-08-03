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
        let outcome = try await coordinator.submitReply(
            pcm16: silence(),
            sampleRate: 16000)

        guard case .dispatched(let text, _, let sessionId) = outcome else {
            return XCTFail("expected dispatch, got \(outcome)")
        }
        XCTAssertEqual(sessionId, "sess-1")
        XCTAssertEqual(transport.sent, [text])

        // 4. Both sides of the ledger close.
        XCTAssertEqual(try store.events().first?.status, .answered)
        XCTAssertEqual(try store.utterances().first?.status, .confirmed)
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

    func testUnenrolledSessionIsNeverInjectedInto() async throws {
        let transport = RecordingTransport()
        let coordinator = try makeCoordinator(transport: transport, enrolled: false)
        try seedEvent()
        _ = try await coordinator.announceNext()

        let outcome = try await coordinator.submitReply(pcm16: silence())

        guard case .notEnrolled = outcome else { return XCTFail("expected refusal, got \(outcome)") }
        XCTAssertTrue(transport.sent.isEmpty, "nothing may be typed into an unenrolled session")
        XCTAssertNotNil(try store.utterances().first?.audioPath, "the recording is still kept")
    }

    /// Absent from `claude agents --json` means blocked on a dialog. Injecting would
    /// answer that dialog, so we refuse — and keep the audio for a later attempt.
    func testSessionMissingFromTheAgentsApiIsRefusedNotGuessed() async throws {
        let transport = RecordingTransport()
        let coordinator = try makeCoordinator(transport: transport, sessionLive: false)
        try seedEvent()
        _ = try await coordinator.announceNext()

        let outcome = try await coordinator.submitReply(pcm16: silence())

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

        let outcome = try await coordinator.submitReply(pcm16: silence())

        guard case .dispatchFailed(.verificationTimedOut, _) = outcome else {
            return XCTFail("expected an ambiguous result, got \(outcome)")
        }
        XCTAssertEqual(try store.utterances().first?.status, .dispatchedUnconfirmed,
                       "must not claim success, and must not silently resend")
        XCTAssertEqual(transport.sent.count, 1, "exactly one attempt — a duplicate is worse than a drop")
        XCTAssertNotEqual(try store.events().first?.status, .answered)
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
