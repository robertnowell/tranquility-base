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
        guard let session = try nextToAnnounce() else { return }
        guard await !prepared.has(session.sessionId) else { return }
        await prepared.put(await summarize(session), for: session.sessionId)
    }

    /// The newest session waiting on you.
    ///
    /// A stack: the newest turn is the state that is actually true, and everything
    /// older is history. There is no supersession pass and no retirement sweep,
    /// because both were describing "not the latest", which the query already knows.
    public func nextToAnnounce() throws -> WaitingSession? {
        try waiting().first
    }

    /// Everything waiting, newest first, for a UI that shows rather than describes.
    public func waiting() throws -> [WaitingSession] {
        // Announcing fails OPEN. If the probe cannot answer, every session is
        // treated as live: the worst outcome is announcing a job that already
        // exited, which costs one keypress. The old collapse of failure into []
        // hid every waiting session the moment the CLI hiccuped — real work,
        // silently gone, which is the one failure this app must never have.
        guard let sessions = agents.sessions() else {
            Coordinator.trace?("liveness probe failed; failing open")
            return try store.waitingSessions()
        }
        let live = Set(sessions.map(\.sessionId))
        return try store.waitingSessions().filter { session in
            // Machine-driven runs exit the moment they finish, so by the time we
            // would announce, they are gone from the agents API. An interactive
            // session persists while its tab is open. This is also the honest
            // definition: if the session is gone there is no tab to open and nobody
            // to answer.
            //
            // Measured rather than assumed: all five sessions with recent turns were
            // present, including the one being typed in; the finished content-engine
            // run was absent.
            //
            // The limit, stated: a headless run still executing IS live, so a long
            // job could be announced. That is noise, and noise is recoverable —
            // unlike the tty filter this replaces, which hid real conversations.
            let isLive = live.contains(session.sessionId)
            if !isLive {
                Coordinator.trace?("skipping \(session.projectLabel): session is gone")
            }
            return isLive
        }
    }

    /// The badge. Shares the predicate with what a keypress will play, so the two
    /// cannot disagree.
    public func waitingCount() throws -> Int { try waiting().count }

    /// You heard it through to the end.
    ///
    /// Advances the cursor rather than mutating the event. Stopping half way must
    /// NOT call this: half an announcement tells you half of what happened.
    public func markHeard(sessionId: String, through eventId: Int64) throws {
        try store.advanceCursor(sessionId: sessionId, heardThrough: eventId)
    }

    /// You are done with it without hearing it.
    ///
    /// A watermark, not a flag. The next turn from this session arrives with a
    /// higher id and revives it by construction — which is what Android does, and
    /// what a boolean cannot do.
    public func dismiss(sessionId: String, through eventId: Int64) throws {
        try store.advanceCursor(sessionId: sessionId, dismissedThrough: eventId)
    }

    // MARK: - Announce

    public struct Announcement: Sendable {
        public let event: WaitingSession
        public let brief: SessionBrief
        public let spoken: SanitizedSpokenText
        public let via: String
        /// Set when the preferred voice failed and the system voice covered for it,
        /// carrying the reason. A downgrade the user cannot see is a downgrade they
        /// will assume is just how the app sounds now.
        public var degraded: String?
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
        only sessionId: String? = nil,
        ignoringGate: Bool = false,
        onWillSpeak: (@MainActor (Announcement) -> Void)? = nil,
        onWord: (@Sendable (Range<Int>) -> Void)? = nil
    ) async throws -> AnnounceOutcome {
        let candidate: WaitingSession?
        if let sessionId {
            // Explicitly chosen — from the waiting list or a deep link — so neither
            // the ordering nor the unheard filter applies. "Read me this session's
            // last summary" stays answerable after you have heard it, dismissed it,
            // or typed since; the strictness belongs to the automatic path only.
            candidate = try store.latestStop(for: sessionId)
        } else {
            candidate = try nextToAnnounce()
        }
        guard let session = candidate else { return .nothingWaiting }

        if !ignoringGate {
            let decision = gate.evaluate()
            guard decision.allowed else {
                // Held writes nothing. It was a status before, which meant a veto
                // mutated the log; now it is simply a decision not to speak yet, and
                // the session stays waiting because it still is.
                return .held(reason: decision.reason)
            }
        }

        if let ready = await prepared.take(session.sessionId) {
            return try await speak(ready, for: session, onWillSpeak: onWillSpeak, onWord: onWord)
        }
        let summary = await summarize(session)
        return try await speak(summary, for: session, onWillSpeak: onWillSpeak, onWord: onWord)
    }

    private func summarize(_ event: WaitingSession) async -> Summary {
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
        _ summary: Summary, for session: WaitingSession,
        onWillSpeak: (@MainActor (Announcement) -> Void)?,
        onWord: (@Sendable (Range<Int>) -> Void)?
    ) async throws -> AnnounceOutcome {
        // Nothing is written before the audio. Marking it announced up front is what
        // let a stray tap spend a session's turn on something never heard, and what
        // let an interrupt handler write a stale copy back over a dismissal.
        let announcement = Announcement(
            event: session, brief: summary.brief, spoken: summary.spoken,
            via: speech.fallback.name)
        await onWillSpeak?(announcement)

        let spoken = await speech.speak(summary.spoken, onWord: onWord)

        // Hearing it through is the only thing that advances the cursor. Anything
        // short of that leaves the session waiting, because it still is: half an
        // announcement tells you half of what happened.
        //
        // There is nothing to revert. Nothing was written before the audio, so a
        // stopped announcement needs no undo — which is what makes the resurrection
        // bug unrepresentable rather than fixed.
        guard spoken.completed else {
            await prepared.put(summary, for: session.sessionId)
            return .interrupted(failure: spoken.failure)
        }

        try store.advanceCursor(sessionId: session.sessionId, heardThrough: session.latestId)
        return .spoke(Announcement(
            event: session, brief: summary.brief, spoken: summary.spoken,
            via: spoken.provider, degraded: spoken.degraded))
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
    public func replyTarget() throws -> WaitingSession? {
        // The session you last heard from, and only while that is still true.
        //
        // This used to scan for the most recent `announced` row, which silently
        // stepped over a NEWER announcement that had failed — and routed a reply
        // into a terminal the user was not talking to. Now it is the cursor: the
        // last thing heard through to the end, valid only while it is still that
        // session's latest event. If a newer turn has arrived since, there is no
        // target, because you have not heard the thing you would be answering.
        let cutoff = Int64(Date().addingTimeInterval(-replyWindow).timeIntervalSince1970 * 1000)
        return try store.mostRecentlyHeard(since: cutoff)
    }

    // MARK: - Reply

    public enum ReplyOutcome: Sendable {
        case dispatched(text: String, latencyMs: Int, sessionId: String)
        /// Typed into a session that was mid-turn; it sends when that turn ends.
        case queued(text: String, sessionId: String)
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
    /// `to:` overrides the derived target for replies that arrive with their own
    /// addressing — a deep link from an HTML review page names the session it is
    /// about, and that beats "whatever you heard last". The session must still
    /// exist in the log; an unknown id refuses rather than guessing.
    public func submitReply(
        pcm16: Data, sampleRate: Double = 16000, to sessionId: String? = nil
    ) async throws -> ReplyOutcome {
        let target: WaitingSession?
        if let sessionId {
            target = try store.waitingSessionsIncludingHeard()
                .first { $0.sessionId == sessionId }
        } else {
            target = try replyTarget()
        }
        guard let target else { return .noTarget }

        var utterance = try await store.captureAndTranscribe(
            pcm16: pcm16, sampleRate: sampleRate, chain: recovery, eventId: nil)

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
        utterance.targetSessionId = target.sessionId
        try store.update(utterance: utterance)
        Coordinator.trace?(
            "replyTarget resolved: session=\(target.sessionId) label=\(target.projectLabel) "
            + "cwd=\(target.cwd ?? "-") event=\(target.latestId)")
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
              let sessionId = utterance.targetSessionId,
              let target = try store.waitingSessionsIncludingHeard()
                  .first(where: { $0.sessionId == sessionId })
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
        utterance: inout Utterance, text: String, target: WaitingSession
    ) async throws -> ReplyOutcome {
        // Typing fails CLOSED: probe failure and genuine absence refuse alike,
        // because injecting into a session we cannot verify could answer a dialog.
        guard let live = (agents.sessions() ?? [])
            .first(where: { $0.sessionId == target.sessionId }) else {
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
        case .queued:
            // Delivered into a session that is mid-turn. It will send itself when
            // that turn ends. Treated as answered, because it is: the words are in
            // the tab and nobody has to do anything else.
            utterance.status = .confirmed
            utterance.confirmedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            utterance.lastError = "queued behind the current turn"
            try store.update(utterance: utterance)

            try store.advanceCursor(sessionId: target.sessionId, heardThrough: target.latestId)
            return .queued(text: text, sessionId: target.sessionId)

        case .confirmed(let latencyMs):
            utterance.status = .confirmed
            utterance.confirmedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            try store.update(utterance: utterance)

            try store.advanceCursor(sessionId: target.sessionId, heardThrough: target.latestId)
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
