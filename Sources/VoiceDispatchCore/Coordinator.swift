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
        self.prepared = PreparedSummaries()
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

    /// Set by the app. Routing decisions are logged because the one failure that
    /// cannot be undone — words typed into a session you were not talking to —
    /// otherwise leaves no evidence at all.
    public nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    @discardableResult
    public func intake() throws -> SpoolDrainer.DrainResult {
        try SpoolDrainer(store: store).drain()
    }

    /// Summaries computed in memory, ahead of being asked for.
    ///
    /// Summarizing on demand meant every single use began with a wait for a model
    /// call — the whole point is to hear a session while your attention is
    /// elsewhere, and a four-second pause after you press is the tax that makes
    /// you stop pressing. Only the newest turn per session is prepared, which is
    /// also the only one that can be announced, so nothing is paid for twice.
    /// An actor because `Coordinator` is a value type and preparation happens on a
    /// background task while announcement may read it from another.
    actor PreparedSummaries {
        private var byEventID: [String: Summary] = [:]
        func has(_ id: String) -> Bool { byEventID[id] != nil }
        func put(_ summary: Summary, for id: String) { byEventID[id] = summary }
        /// Removing on read keeps a summary from being spoken twice.
        func take(_ id: String) -> Summary? { byEventID.removeValue(forKey: id) }
    }

    private let prepared: PreparedSummaries

    /// Prepare whatever is currently announceable. Cheap to call repeatedly:
    /// anything already prepared is skipped.
    public func prepareNext() async throws {
        guard let event = try nextToAnnounce() else { return }
        guard await !prepared.has(event.id) else { return }
        await prepared.put(await summarize(event), for: event.id)
    }

    /// The newest unread turn, and only ever one per session.
    ///
    /// This was a FIFO queue, which is wrong for the job. Sessions are not work
    /// items: a session that ended four turns ago has already superseded itself
    /// three times over, and hearing the oldest first means hearing something
    /// twenty minutes stale while the thing that just finished waits behind it.
    /// What you want to know is what each session is saying *now*, so an older
    /// turn from the same session is not a backlog entry — it is a dead letter.
    public func nextToAnnounce() throws -> QueuedEvent? {
        try supersedeStaleTurns()
        let waiting = try store.events(limit: 200).filter {
            $0.status == .new || $0.status == .summarized || $0.status == .held
        }

        // Never-offered items first, newest of those first. Then anything you have
        // already been offered and did not finish, least recently offered first.
        //
        // Plain newest-first looped: stopping an announcement leaves it unread AND
        // it is still the newest, so the next tap replayed it forever and there was
        // no way to reach anything else.
        return waiting.min { a, b in
            let aOffered = a.announcedAtMs ?? 0
            let bOffered = b.announcedAtMs ?? 0
            if (aOffered == 0) != (bOffered == 0) { return aOffered == 0 }
            if aOffered == 0 { return a.createdAtMs > b.createdAtMs }
            return aOffered < bOffered
        }
    }

    /// Collapse each session's unread turns down to its most recent one.
    ///
    /// Run before every selection rather than only at intake, so rows written
    /// while the app was closed are collapsed too.
    @discardableResult
    public func supersedeStaleTurns() throws -> Int {
        let waiting = try store.events(limit: 500).filter {
            $0.status == .new || $0.status == .summarized || $0.status == .held
        }
        var newest: [String: Int64] = [:]
        for event in waiting {
            newest[event.sessionId] = max(newest[event.sessionId] ?? .min, event.createdAtMs)
        }
        var superseded = 0
        for (sessionId, latest) in newest {
            superseded += try store.supersedePending(sessionId: sessionId, before: latest)
        }
        _ = waiting
        return superseded
    }

    /// The user typed into that session themselves, so whatever was waiting to be
    /// read out has been overtaken by them doing the thing. Announcing it now is
    /// worse than useless — it reports a state they have already moved past.
    @discardableResult
    public func invalidatePending(sessionId: String) throws -> Int {
        try store.supersedePending(sessionId: sessionId)
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
        /// Never made a sound, so it is still unread. `failure` is nil when you
        /// stopped it before it started and set when it stopped itself.
        case interrupted(failure: String?)
    }

    /// Speak the next waiting item.
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
        // A Notification payload carries no assistant message, so those rows used to
        // be summarized from nothing but the folder name — "promotions. idle and
        // waiting on you." said three times over. The transcript is in the payload;
        // read the real message so a prompt can say what it is actually waiting on.
        let lastMessage = event.lastAssistantMessage?.isEmpty == false
            ? event.lastAssistantMessage!
            : (event.transcriptPath
                .flatMap { TranscriptArchive.lastAssistantMessage(in: URL(fileURLWithPath: $0)) } ?? "")

        if let ready = await prepared.take(event.id) {
            return try await speak(ready, for: &event, onWillSpeak: onWillSpeak, onWord: onWord)
        }

        let summary = await summarize(event)
        return try await speak(summary, for: &event, onWillSpeak: onWillSpeak, onWord: onWord)
    }

    private func summarize(_ event: QueuedEvent) async -> Summary {
        let context = event.transcriptPath.map {
            TranscriptArchive.sessionContext(in: URL(fileURLWithPath: $0))
        }
        let lastMessage = event.lastAssistantMessage?.isEmpty == false
            ? event.lastAssistantMessage!
            : (event.transcriptPath
                .flatMap { TranscriptArchive.lastAssistantMessage(in: URL(fileURLWithPath: $0)) } ?? "")

        return await summarizer.summarize(SummaryRequest(
            lastAssistantMessage: lastMessage,
            projectLabel: event.projectLabel,
            firstUserMessage: context?.firstUserMessage,
            gitBranch: context?.gitBranch,
            cwd: event.cwd,
            hookEvent: event.hookEvent,
            notificationMatcher: event.notificationMatcher))
    }

    private func speak(
        _ summary: Summary, for event: inout QueuedEvent,
        onWillSpeak: (@MainActor (Announcement) -> Void)?,
        onWord: (@Sendable (Range<Int>) -> Void)?
    ) async throws -> AnnounceOutcome {
        event.summaryText = summary.spoken.text
        event.status = .announced
        event.announcedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        try store.update(event: event)

        let announcement = Announcement(
            event: event, brief: summary.brief, spoken: summary.spoken, via: speech.fallback.name)
        await onWillSpeak?(announcement)

        let spoken = await speech.speak(summary.spoken, onWord: onWord)

        // Interrupting an announcement must not consume it. Marking it announced up
        // front is what makes the reply target derivable, but a stray second tap
        // then silently spent a session's only unread turn on audio you never heard.
        // Put it back and re-prepare it, so the next tap plays it again.
        // Hearing it through is what marks it read. Anything short of that leaves it
        // waiting: half an announcement tells you half of what happened, and a
        // system that quietly retires those is one you cannot trust to have shown
        // you everything. The other way to mark something read is to dismiss it,
        // which is deliberate and explicit.
        //
        // announcedAtMs survives the revert: it records that this session was the
        // most recent thing we tried to say, which is what stops an older
        // announcement from inheriting the reply.
        guard spoken.completed else {
            event.status = .new
            try store.update(event: event)
            await prepared.put(summary, for: event.id)
            return .interrupted(failure: spoken.failure)
        }

        return .spoke(Announcement(
            event: event, brief: summary.brief, spoken: summary.spoken, via: spoken.provider))
    }

    /// Take an item out of the queue without answering it. This is what Dismiss
    /// means, and it means only this.
    public func dismiss(eventId: String) throws {
        guard var event = try store.events(limit: 500).first(where: { $0.id == eventId })
        else { return }
        event.status = .dismissed
        try store.update(event: event)
    }

    // MARK: - Reply target
    //
    // Derived, never stored. The reply goes to the session that most recently spoke
    // to you, which is the only binding a person would intuit — and deriving it from
    // `announcedAtMs` means it survives an app restart for free, with no extra state
    // that could disagree with the queue.

    /// The session you last actually heard from — never merely the last one we
    /// tried to read out.
    ///
    /// This routed a reply into the wrong terminal. The old rule took the most
    /// recent event whose status was `announced`, which silently skipped over any
    /// newer announcement that had failed or been cut off. So a failed announcement
    /// for session B left session A — minutes older, and no longer what you were
    /// answering — as the target, and your words were typed into it.
    ///
    /// The rule now: take the most recent announcement ATTEMPT, whether or not it
    /// succeeded, and offer it only if it was heard through to the end. A failed
    /// attempt therefore blocks replies rather than deferring to a stale one.
    /// Refusing is recoverable; typing into the wrong session is not.
    public func replyTarget() throws -> QueuedEvent? {
        let cutoff = Int64(Date().addingTimeInterval(-replyWindow).timeIntervalSince1970 * 1000)
        let attempts = try store.events(limit: 500)
            .filter { ($0.announcedAtMs ?? 0) >= cutoff }
        guard let latestAttempt = attempts.max(by: {
            ($0.announcedAtMs ?? 0) < ($1.announcedAtMs ?? 0)
        }) else { return nil }

        return latestAttempt.status == .announced ? latestAttempt : nil
    }

    // MARK: - Reply

    public enum ReplyOutcome: Sendable {
        case dispatched(text: String, latencyMs: Int, sessionId: String)
        case transcriptionFailed(utteranceId: String)
        case noTarget
        /// Transcribed and about to be sent unless the user intervenes.
        case readyToSend(utteranceId: String, text: String, label: String, sessionId: String)
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

        // Stop here. Dispatch is the caller's next step, after an undo window.
        //
        // A confirmation you must approve is a toll on the common case, where the
        // transcript is fine and you want it sent. An undo window costs nothing
        // when it is right and everything it needs to when it is wrong — and it
        // subsumes enrolment, since choosing to let it send IS the consent.
        utterance.status = .ready
        try store.update(utterance: utterance)
        Coordinator.trace?(
            "replyTarget resolved: session=\(target.sessionId) label=\(target.projectLabel) "
            + "cwd=\(target.cwd ?? "-") announcedAt=\(target.announcedAtMs ?? -1)")
        return .readyToSend(
            utteranceId: utterance.id, text: text, label: target.projectLabel,
            sessionId: target.sessionId)
    }

    /// Confirm this session and send the reply already recorded for it.
    ///
    /// Consent belongs at the moment it means something — you have heard the
    /// summary, spoken an answer, and been shown which tab it is going to. One
    /// button there is a real gate. A command in another window is not.
    @discardableResult
    public func confirmAndSend(utteranceId: String) async throws -> ReplyOutcome {
        guard var utterance = try store.utterances(limit: 500).first(where: { $0.id == utteranceId }),
              let text = utterance.transcriptText,
              let eventId = utterance.eventId,
              let target = try store.events(limit: 500).first(where: { $0.id == eventId })
        else { return .noTarget }

        try enrolment.enrol(sessionId: target.sessionId)
        return try await dispatch(utterance: &utterance, text: text, target: target)
    }

    /// The user said no. Keep the audio and transcript — they are evidence of what
    /// was heard — but take it out of the sendable set so nothing resends it later.
    public func cancelSend(utteranceId: String) throws {
        guard var utterance = try store.utterances(limit: 500).first(where: { $0.id == utteranceId })
        else { return }
        utterance.status = .discarded
        try store.update(utterance: utterance)
    }

    private func dispatch(
        utterance: inout Utterance, text: String, target: QueuedEvent
    ) async throws -> ReplyOutcome {
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
