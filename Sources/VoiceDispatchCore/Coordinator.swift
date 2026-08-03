import Foundation

/// The loop. Everything else in this package is a part; this is the assembly.
///
/// Deliberately UI-free so it can be driven from `vdctl` and from tests exactly as
/// the app drives it — the integration path and the tested path are the same code.
public struct Coordinator: Sendable {
    public let store: QueueStore
    public let summarizer: SummarizerChain
    public let speech: SpeechChain
    public let gate: InterruptGate
    public let transport: any DispatchTransport
    public let enrolment: EnrolmentRegistry
    public let agents: ClaudeAgentsReading
    /// Injected rather than defaulted at the call site, so tests can run the whole
    /// loop without touching the network. Left implicit, the coordinator's own tests
    /// were quietly uploading silence to a paid transcription API.
    public let recovery: RecoveryChain

    /// How long after speaking a session stays the reply target. Long enough to
    /// think, short enough that a reply can't land somewhere you've forgotten about.
    public let replyWindow: TimeInterval

    public init(
        store: QueueStore,
        summarizer: SummarizerChain = SummarizerChain(),
        speech: SpeechChain = SpeechChain(),
        gate: InterruptGate = InterruptGate(),
        transport: any DispatchTransport = TerminalAppTransport(),
        enrolment: EnrolmentRegistry = EnrolmentRegistry(),
        agents: ClaudeAgentsReading = ClaudeAgentsCLI(),
        recovery: RecoveryChain = RecoveryChain(),
        replyWindow: TimeInterval = 15 * 60
    ) {
        self.store = store
        self.summarizer = summarizer
        self.speech = speech
        self.gate = gate
        self.transport = transport
        self.enrolment = enrolment
        self.agents = agents
        self.recovery = recovery
        self.replyWindow = replyWindow
    }

    // MARK: - Intake

    @discardableResult
    public func intake() throws -> SpoolDrainer.DrainResult {
        try SpoolDrainer(store: store).drain()
    }

    /// Oldest first. A queue you walk should hand back what has been waiting
    /// longest, not the freshest thing — otherwise a busy project starves the rest.
    public func nextToAnnounce() throws -> QueuedEvent? {
        let waiting = try store.events(limit: 200).filter {
            $0.status == .new || $0.status == .summarized || $0.status == .held
        }
        return waiting.min { $0.createdAtMs < $1.createdAtMs }
    }

    // MARK: - Announce

    public struct Announcement: Sendable {
        public let event: QueuedEvent
        public let brief: SessionBrief
        public let spoken: SanitizedSpokenText
        public let via: String
    }

    public enum AnnounceOutcome: Sendable {
        case spoke(Announcement)
        /// The gate said not now. The item stays queued — a veto can only delay.
        case held(reason: String)
        case nothingWaiting
    }

    /// Speak the next waiting item. Summarization happens here rather than at intake
    /// so nothing is paid for that is never heard.
    /// `onWillSpeak` fires with the brief BEFORE the audio starts, and `onWord`
    /// reports progress during it. Without the first callback the UI could only
    /// render after `speak` returned — i.e. after you had already heard the whole
    /// thing, which is exactly when the text stops being useful.
    public func announceNext(
        ignoringGate: Bool = false,
        onWillSpeak: (@MainActor (Announcement) -> Void)? = nil,
        onWord: (@Sendable (Range<Int>) -> Void)? = nil
    ) async throws -> AnnounceOutcome {
        guard var event = try nextToAnnounce() else { return .nothingWaiting }

        if !ignoringGate {
            let decision = gate.evaluate()
            guard decision.allowed else {
                if event.status != .held {
                    event.status = .held
                    try store.update(event: event)
                }
                return .held(reason: decision.reason)
            }
        }

        let context = event.transcriptPath.map { TranscriptArchive.sessionContext(in: URL(fileURLWithPath: $0)) }
        let summary = await summarizer.summarize(SummaryRequest(
            lastAssistantMessage: event.lastAssistantMessage ?? "",
            projectLabel: event.projectLabel,
            firstUserMessage: context?.firstUserMessage,
            gitBranch: context?.gitBranch,
            cwd: event.cwd,
            hookEvent: event.hookEvent,
            notificationMatcher: event.notificationMatcher))

        event.summaryText = summary.spoken.text
        event.status = .announced
        event.announcedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        try store.update(event: event)

        let announcement = Announcement(
            event: event, brief: summary.brief, spoken: summary.spoken, via: speech.fallback.name)
        await onWillSpeak?(announcement)

        let via = await speech.speak(summary.spoken, onWord: onWord)
        return .spoke(Announcement(
            event: event, brief: summary.brief, spoken: summary.spoken, via: via))
    }

    // MARK: - Reply target
    //
    // Derived, never stored. The reply goes to the session that most recently spoke
    // to you, which is the only binding a person would intuit — and deriving it from
    // `announcedAtMs` means it survives an app restart for free, with no extra state
    // that could disagree with the queue.

    public func replyTarget() throws -> QueuedEvent? {
        let cutoff = Int64(Date().addingTimeInterval(-replyWindow).timeIntervalSince1970 * 1000)
        return try store.events(status: .announced, limit: 50)
            .filter { ($0.announcedAtMs ?? 0) >= cutoff }
            .max { ($0.announcedAtMs ?? 0) < ($1.announcedAtMs ?? 0) }
    }

    // MARK: - Reply

    public enum ReplyOutcome: Sendable {
        case dispatched(text: String, latencyMs: Int, sessionId: String)
        case transcriptionFailed(utteranceId: String)
        case noTarget
        case notEnrolled(sessionId: String)
        case sessionNotReady(Readiness)
        case dispatchFailed(DispatchFailure, utteranceId: String)
    }

    /// Persist the audio, transcribe it, and route the result to whichever session
    /// last spoke. Ordering is the same invariant as everywhere else: the recording
    /// is durable before anything else is attempted, so every failure below this
    /// line is recoverable rather than lossy.
    public func submitReply(pcm16: Data, sampleRate: Double = 16000) async throws -> ReplyOutcome {
        guard let target = try replyTarget() else { return .noTarget }

        var utterance = try await store.captureAndTranscribe(
            pcm16: pcm16, sampleRate: sampleRate, chain: recovery, eventId: target.id)

        guard utterance.status == .transcribed, let text = utterance.transcriptText else {
            return .transcriptionFailed(utteranceId: utterance.id)
        }

        guard enrolment.isEnrolled(sessionId: target.sessionId, cwd: target.cwd) else {
            utterance.status = .dispatchFailed
            utterance.lastError = "session not enrolled"
            try store.update(utterance: utterance)
            return .notEnrolled(sessionId: target.sessionId)
        }

        guard let live = agents.sessions().first(where: { $0.sessionId == target.sessionId }) else {
            // Absent from `claude agents --json` means blocked on a dialog or gone.
            // Injecting would answer the dialog, so we refuse and keep the audio.
            utterance.status = .ready
            try store.update(utterance: utterance)
            return .sessionNotReady(.notRegistered)
        }

        let dispatchTarget = DispatchTarget(
            sessionId: target.sessionId,
            pid: live.pid,
            tty: ProcessProbe.tty(of: live.pid),
            transcriptPath: target.transcriptPath,
            label: target.projectLabel)

        utterance.status = .dispatching
        utterance.targetKind = transport.kind
        utterance.targetSessionId = target.sessionId
        utterance.targetPid = live.pid
        utterance.targetTty = dispatchTarget.tty
        utterance.dispatchAttempts += 1
        utterance.lastDispatchAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        try store.update(utterance: utterance)

        switch await transport.send(text: text, to: dispatchTarget) {
        case .confirmed(let latencyMs):
            utterance.status = .confirmed
            utterance.confirmedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            try store.update(utterance: utterance)

            var answered = target
            answered.status = .answered
            try store.update(event: answered)
            return .dispatched(text: text, latencyMs: latencyMs, sessionId: target.sessionId)

        case .deferred(let readiness):
            utterance.status = .ready
            try store.update(utterance: utterance)
            return .sessionNotReady(readiness)

        case .failed(let failure):
            // Verification timeouts stay `dispatchedUnconfirmed`: the text may have
            // landed, and a retry could duplicate it. A human decides.
            utterance.status = failure == .verificationTimedOut ? .dispatchedUnconfirmed : .dispatchFailed
            utterance.lastError = "\(failure)"
            try store.update(utterance: utterance)
            return .dispatchFailed(failure, utteranceId: utterance.id)
        }
    }
}
