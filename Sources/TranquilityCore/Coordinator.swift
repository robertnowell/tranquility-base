import Foundation

/// The loop. Everything else in this package is a part; this is the assembly.
///
/// Deliberately UI-free so it can be driven from `tbase` and from tests exactly as
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
    /// Files staged by drag-and-drop to ride the next voice reply (the drop
    /// tray). A reference alongside a value-type Coordinator, like
    /// PreparedSummaries — the panel reads chips synchronously in render().
    public let attachments: AttachmentStore

    /// How long after speaking a session stays the reply target. Long enough to
    /// think, short enough that a reply can't land somewhere you've forgotten about.
    public let replyWindow: TimeInterval

    /// How long a dispatch waits for a session that is not in
    /// `claude agents --json` yet. A brand-new agent can register, bind, and
    /// then briefly drop out again before it has taken any input; without this
    /// the reply was refused and the user was told to try again by hand.
    /// Zero in tests that assert the refusal itself.
    public let readinessGrace: TimeInterval

    public init(
        store: QueueStore,
        summarizer: SummarizerChain = SummarizerChain(),
        speech: SpeechChain = SpeechChain(),
        gate: InterruptGate = InterruptGate(),
        transport: any DispatchTransport = TerminalAppTransport(),
        enrolment: EnrolmentRegistry = EnrolmentRegistry(),
        agents: ClaudeAgentsReading = ClaudeAgentsCLI(),
        recovery: RecoveryChain = RecoveryChain(),
        attachments: AttachmentStore = AttachmentStore(),
        replyWindow: TimeInterval = 15 * 60,
        readinessGrace: TimeInterval = 12
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
        self.attachments = attachments
        self.replyWindow = replyWindow
        self.readinessGrace = readinessGrace
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
        /// Keyed by session, VALID only for one specific latest event.
        ///
        /// Keying by session alone played a stale summary aloud: one prepared for
        /// the Cloudflare-token turn survived while the session moved two turns on,
        /// and the announcement spoke about work the user had already answered. A
        /// summary is a summary OF an event, so the event id is part of its
        /// identity — a mismatch discards rather than serves.
        private var bySession: [String: (latestId: Int64, summary: Summary)] = [:]
        func has(_ id: String, latest: Int64) -> Bool { bySession[id]?.latestId == latest }
        func put(_ summary: Summary, for id: String, latest: Int64) {
            bySession[id] = (latest, summary)
        }
        /// Read WITHOUT consuming — for warming the audio of something already
        /// prepared. `take` is the announcement path and must stay destructive;
        /// this one must not be, or a prefetch would eat the summary it is
        /// trying to make faster.
        func peek(_ id: String, latest: Int64) -> Summary? {
            guard let entry = bySession[id], entry.latestId == latest else { return nil }
            return entry.summary
        }
        /// Removing on read keeps a summary from being spoken twice.
        func take(_ id: String, latest: Int64) -> Summary? {
            guard let entry = bySession.removeValue(forKey: id),
                  entry.latestId == latest else { return nil }
            return entry.summary
        }
    }

    private let prepared: PreparedSummaries

    /// Prepare whatever is currently announceable. Cheap to call repeatedly:
    /// anything already prepared is skipped.
    ///
    /// Takes the delivery overlay for the same reason the speaking path does,
    /// though the symptom here is cost rather than noise: without it, the
    /// prefetch summarises and renders audio for the session you are mid-reply
    /// to — a model call and an ElevenLabs round trip spent on an announcement
    /// that must not play.
    public func prepareNext(excluding inFlight: DeliveryInFlight = DeliveryInFlight()) async throws {
        guard let session = try nextToAnnounce(excluding: inFlight) else { return }
        guard await !prepared.has(session.sessionId, latest: session.latestId) else {
            // Text already in hand, but the VOICE may not be: a summary restored
            // from the store, or prepared before the roster resolved, leaves the
            // clip unrendered. Cheap to re-assert — `prewarm` returns immediately
            // on a hit — and it closes the window where the second press of a
            // backlog paid full price for audio it could have had.
            if let ready = await prepared.peek(session.sessionId, latest: session.latestId) {
                await prewarmAnnouncement(ready, for: session)
            }
            return
        }
        // A stored brief for this exact event (written before a restart) is the
        // same summary this call would regenerate — load it instead of paying
        // for a model call twice.
        let summary: Summary
        if let restored = restoredSummary(for: session) {
            summary = restored
        } else {
            summary = await summarize(session)
        }
        await prepared.put(summary, for: session.sessionId, latest: session.latestId)
        // Text AND audio, both before the press (ruled 08 Aug). Writing the
        // summary ahead of time already removed the model call from the critical
        // path; the ElevenLabs round trip was the half still on it, and it is the
        // half with the ugly tail — measured p50 1s but an 11s maximum, spent
        // staring at a card of grey text with nothing moving on it.
        await prewarmAnnouncement(summary, for: session)
    }

    /// The announcement's own clip, in the session's own voice. Only the main
    /// summary — the ⌃⌃ ladder is deliberately NOT rendered here: a rung is
    /// ~1.4x the length of the announcement and three of them is ~4x, spent on a
    /// pull that 28% of announcements never get. The ladder warms lazily from the
    /// app layer once you are actually listening.
    private func prewarmAnnouncement(_ summary: Summary, for session: WaitingSession) async {
        await speech.prewarm(summary.spoken, voice: voiceId(for: session.sessionId))
    }

    /// The newest session waiting on you — that you are not already answering.
    ///
    /// A stack: the newest turn is the state that is actually true, and everything
    /// older is history. There is no supersession pass and no retirement sweep,
    /// because both were describing "not the latest", which the query already knows.
    ///
    /// `excluding` applies the delivery overlay, and it is the whole reason this
    /// is not simply `waiting().first` (ruled 10 Aug). `waiting()` answers what
    /// the AGENT claims it needs, sourced from the store and the liveness probe.
    /// A reply of ours in flight says nothing about that claim — it says what WE
    /// are doing about it — so it must not be folded into `waiting()`, which
    /// every other caller reads as the agent's own word. It belongs here, in the
    /// question "what should we say next", which is a different question.
    ///
    /// The grid's lamp already composed these two correctly; this selector was
    /// still `waiting().first`, so ⌃⌥ handed back the session you had just
    /// replied to — visibly blue in the grid and still first in line to the
    /// keyboard. Reported 10 Aug: "I hit next and the old session starts talking
    /// again." The predicate is `supersedesWaiting`, deliberately the SAME one
    /// the lamp uses, so the two cannot drift into disagreeing again.
    ///
    /// A newer turn arriving while the reply is in flight still wins: that turn
    /// is genuinely unread, `supersedesWaiting` returns false for it, and it is
    /// announced. Only the turn being answered is held back.
    ///
    /// The default is an empty overlay — "nothing in flight" — so a caller that
    /// has no delivery state to offer gets exactly the old behaviour.
    public func nextToAnnounce(
        excluding inFlight: DeliveryInFlight = DeliveryInFlight()
    ) throws -> WaitingSession? {
        // `!heard` is the WHOLE difference between the announce queue and the
        // waiting list: one list, one bit, filtered here at the only site that
        // cares. A heard session stays in waiting() — still lit, still owed —
        // it just isn't read out twice.
        try waiting().first {
            !$0.heard && !inFlight.supersedesWaiting($0.sessionId, latestId: $0.latestId)
        }
    }

    /// What ⌃⌥ plays when nothing is unopened: the next waiting row AFTER the
    /// one you just heard, wrapping at the end. Anything green always plays
    /// (ruled 13 Aug) — a registered press that silently returns to the grid
    /// is indistinguishable from a dead app, and it shipped: with every
    /// waiting row already opened, four ⌃⌥ presses in a row visibly did
    /// nothing (app.log 13 Aug 14:26).
    ///
    /// `after` is what makes this a WALK rather than a constant function, and
    /// its absence was the second bug on the same keypress: the first fix
    /// replayed `waiting().first`, which is the same session every time — five
    /// presses, five `replaying 4394c0ec` (app.log 16 Aug 01:04). ⌃⌥ means
    /// "next", so an opened stack advances through itself; the wrap is what
    /// keeps the LAST row from being a dead end, which is the same silent
    /// press wearing a different hat.
    ///
    /// The delivery overlay still applies — a turn you are mid-reply to must
    /// not be read back at you even as a replay — and a wrap that lands back
    /// on `after` is honest: one green row replays itself, because that is
    /// genuinely the only thing there is to play.
    public func nextToReplay(
        after: String? = nil,
        excluding inFlight: DeliveryInFlight = DeliveryInFlight()
    ) throws -> WaitingSession? {
        let stack = try waiting().filter {
            !inFlight.supersedesWaiting($0.sessionId, latestId: $0.latestId)
        }
        guard let after, let mark = stack.firstIndex(where: { $0.sessionId == after })
        else { return stack.first }
        // Rotate: everything after the mark, then everything up to it. The
        // mark itself lands last, so it replays only when nothing else can.
        return (stack[(mark + 1)...] + stack[..<mark]).first ?? stack[mark]
    }

    /// Everything waiting ON THE USER — undismissed, heard or not — newest
    /// first, for a UI that shows rather than describes. Each row carries
    /// `heard`; the announce path (nextToAnnounce) is the only consumer that
    /// filters on it.
    public func waiting() throws -> [WaitingSession] {
        // Announcing fails OPEN. If the probe cannot answer, every session is
        // treated as live: the worst outcome is announcing a job that already
        // exited, which costs one keypress. The old collapse of failure into []
        // hid every waiting session the moment the CLI hiccuped — real work,
        // silently gone, which is the one failure this app must never have.
        guard let sessions = agents.sessions() else {
            Coordinator.noteProbeFailure()
            return yours(try store.waitingSessions())
        }
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
        let live = Set(sessions.map(\.sessionId))
        let all = yours(try store.waitingSessions())
        Coordinator.sweep(all, live: live)
        return all.filter { live.contains($0.sessionId) }
    }

    /// Sessions a person started, which is the only kind worth announcing.
    ///
    /// Liveness used to do this job by accident and the comment above says so:
    /// "machine-driven runs exit the moment they finish, so by the time we
    /// would announce, they are gone from the agents API." That works right up
    /// until the probe fails — and then the guard above returns the store's set
    /// UNFILTERED, which on this machine is 502 sessions over a week, 460 of
    /// them cron jobs and replay runs. One CLI hiccup and the panel reads a
    /// syndit worker out loud.
    ///
    /// `entrypoint` is the honest instrument for the question liveness was
    /// standing in for. It is written into the transcript by Claude Code, it
    /// never changes, and it survives the process — so it answers the same way
    /// whether the session is running, finished, or long gone, which is exactly
    /// what stops the announcer and the grid from telling different stories.
    ///
    /// Fails OPEN by construction: only a positive `sdk-cli` excludes anything.
    /// See `SessionDiscovery.isHeadless`.
    ///
    /// Applied BEFORE the sweep on purpose. The sweep's own header records what
    /// the unfiltered population cost: "dead sessions accumulate forever — 200
    /// here, 157 of them from a single afternoon of prompt-replay runs" and
    /// 2.3GB of log in five days. Those 157 were headless. They stop being
    /// swept at all now.
    private func yours(_ sessions: [WaitingSession]) -> [WaitingSession] {
        sessions.filter { !SessionDiscovery.isHeadless(transcriptPath: $0.transcriptPath) }
    }

    // MARK: - The sweep

    /// What is gone, what is retired, and what is worth saying about it.
    ///
    /// Dead sessions accumulate forever — 200 here, 157 of them from a single
    /// afternoon of prompt-replay runs — and the sweep touched every one on every
    /// poll, writing a line each time: ~250 lines/second, 38.5M lines, 2.3 GB in
    /// five days. A log that large buries the diagnostics it exists to provide.
    ///
    /// Five rules, in the order they matter:
    ///
    /// 1. **Liveness governs.** A session is retired only while the agents API says
    ///    it is gone, and the instant it reappears it is un-retired and said out
    ///    loud. Nothing else may retire a session — not age, not silence, not event
    ///    count — because nothing else is evidence that no one is there to answer.
    ///    This is the rule that keeps the tty filter's failure from repeating: that
    ///    one inferred "nobody is here" from a proxy, and hid real conversations.
    ///    Measured while designing this: every replay session carries a tty,
    ///    inherited from the terminal that launched the harness.
    /// 2. **Retirement is timed, not counted.** The liveness probe is cached for six
    ///    seconds, so consecutive polls can be one observation; counting them would
    ///    retire a session on a single probe wearing three hats.
    /// 3. **Only observed absence ages a session.** A gap in sweeping — a probe
    ///    outage, a laptop asleep, the app paused — is not evidence, so a gap longer
    ///    than `gapTolerance` restarts every absence clock. Without this the wall
    ///    clock did the ageing: two observations five minutes apart across an outage
    ///    retired a session that had been watched exactly twice.
    /// 4. **What is said is symmetric.** Anything announced gone is announced again
    ///    when it returns, retired or not. A log that says a session died and never
    ///    retracts it sends the next debugger down a hole.
    /// 5. **State is in memory, so a restart forgets.** Deliberate: the worst case is
    ///    re-observing sessions already known dead, the same fail-open posture as the
    ///    probe. Persisted, a bug here could bury a live session across restarts.
    ///
    /// Durations use a monotonic clock. These are elapsed times, and a wall clock
    /// steps — an NTP correction backwards froze retirement and silenced the
    /// heartbeat for the length of the step.
    typealias Instant = ContinuousClock.Instant

    /// One record per session. Unified rather than an `absent` map beside a `retired`
    /// set, because two structures describing one lifecycle drift: the pair could say
    /// a session was both retired and freshly absent.
    private struct Watch {
        var since: Instant       // start of the CURRENT observed absence
        var lastSeen: Instant    // last sweep that saw this session at all
        var announced = false    // "gone" has been said, so say "back" if it returns
        var retired = false
    }
    private nonisolated(unsafe) static var watched: [String: Watch] = [:]
    private nonisolated(unsafe) static var lastSweep: Instant?
    private nonisolated(unsafe) static var lastHeartbeat: Instant?
    private nonisolated(unsafe) static var probeFailingSince: Instant?
    private static let sweepLock = NSLock()

    /// Long enough that a slow probe or a tab being cycled cannot retire a session
    /// someone is using; short enough that a finished batch run stops being swept
    /// while you are still in the same coffee.
    private static let retirementDelay: Duration = .seconds(120)
    /// 288 lines a day. The transitions say what changed; this says what IS.
    private static let heartbeatInterval: Duration = .seconds(300)
    /// Normal polling is every 1–5s, so a longer gap means the app was not watching.
    private static let gapTolerance: Duration = .seconds(30)
    /// `waitingSessions()` is `LIMIT 200`, so a session can leave the result set
    /// without leaving the queue. Forgetting on that basis re-announced older dead
    /// sessions every time a newer one was dismissed and slid one back into view,
    /// and retirement never converged. Records expire on their own clock instead.
    private static let watchRetention: Duration = .seconds(3600)

    /// Tests share this process, and the sweep's memory is static — without a reset
    /// one test's retirements would leak into the next and the failure would look
    /// like a logic bug rather than a fixture one.
    static func resetSweepStateForTesting() {
        sweepLock.lock()
        defer { sweepLock.unlock() }
        watched = [:]
        lastSweep = nil
        lastHeartbeat = nil
        probeFailingSince = nil
    }

    /// Retired right now, for assertions. Not used in production.
    static func retiredSessionsForTesting() -> Set<String> {
        sweepLock.lock()
        defer { sweepLock.unlock() }
        return Set(watched.filter(\.value.retired).keys)
    }

    /// The probe could not answer. Said on the way in and then at heartbeat cadence,
    /// never per poll: `sessions()` caches only successes, so during an outage every
    /// single call re-spawns the subprocess AND wrote a line — the 2.3 GB shape again
    /// on the branch beside the one that caused it.
    static func noteProbeFailure(now: Instant = .now) {
        var line: String?
        do {
            sweepLock.lock()
            defer { sweepLock.unlock() }
            if let since = probeFailingSince {
                if now - (lastHeartbeat ?? since) >= heartbeatInterval {
                    lastHeartbeat = now
                    line = "liveness probe still failing after "
                         + "\(Int((now - since).components.seconds))s; failing open, "
                         + "\(watched.count) sessions unwatched"
                }
            } else {
                probeFailingSince = now
                lastHeartbeat = now
                line = "liveness probe failed; failing open (every session treated as live)"
            }
        }
        if let line { trace?(line) }
    }

    static func sweep(_ all: [WaitingSession], live: Set<String>, now: Instant = .now) {
        // Collected under the lock, spoken after it. `trace` writes to app.log with a
        // synchronous open/write/close, and every caller of `waiting()` is on the main
        // actor — so lines emitted in place are file I/O on the UI thread. That is the
        // same stall this app already learned from the liveness probe, which had to be
        // moved off-main because "called synchronously from the main actor it froze the
        // UI on every tick". Two hundred writes in one sweep is that mistake again.
        var gone: [String] = []
        var retiredNow: [String] = []
        var revived: [String] = []
        var longestGone = 0
        var recovered: String?
        var heartbeat: String?

        do {
            sweepLock.lock()
            defer { sweepLock.unlock() }

            if let failingSince = probeFailingSince {
                recovered = "liveness probe recovered after "
                          + "\(Int((now - failingSince).components.seconds))s"
                probeFailingSince = nil
            }
            // Rule 3: a gap means nobody was watching, so no absence observed across
            // it may count toward retirement.
            let blind = lastSweep.map { now - $0 > gapTolerance } ?? true
            lastSweep = now

            for session in all {
                let id = session.sessionId
                guard !live.contains(id) else {
                    // Answerable now, whatever it was a moment ago. Rule 4: if we said
                    // it was gone, we say it is back — retired or merely absent.
                    if let watch = watched.removeValue(forKey: id), watch.announced {
                        revived.append(session.projectLabel)
                    }
                    continue
                }
                var watch = watched[id] ?? Watch(since: now, lastSeen: now)
                if blind { watch.since = now }        // the gap is not evidence
                watch.lastSeen = now
                defer { watched[id] = watch }

                guard !watch.retired else { continue }   // accounted for; say nothing
                if !watch.announced {
                    gone.append(session.projectLabel)
                    watch.announced = true
                }
                let elapsed = now - watch.since
                if elapsed >= retirementDelay {
                    watch.retired = true
                    retiredNow.append(session.projectLabel)
                    longestGone = max(longestGone, Int(elapsed.components.seconds))
                }
            }

            // Records expire on their own clock, NOT on absence from a truncated
            // query — see `watchRetention`.
            watched = watched.filter { now - $0.value.lastSeen < watchRetention }

            // Nil means this is the first sweep, which is exactly when the state is
            // most worth stating — so it beats immediately rather than in five minutes.
            if lastHeartbeat.map({ now - $0 >= heartbeatInterval }) ?? true {
                lastHeartbeat = now
                let liveCount = all.count { live.contains($0.sessionId) }
                let retiredCount = watched.count(where: \.value.retired)
                heartbeat = "sweep: \(liveCount) live, \(retiredCount) retired, "
                          + "\(watched.count - retiredCount) going, "
                          + "\(all.count) in the newest-200 window"
            }
        }

        if let recovered { trace?(recovered) }
        // Both shapes lead with "skipping" so one grep finds every skip, whether it
        // was a lone session or two hundred collapsed into a count.
        if let line = phrase(gone, one: { "skipping \($0): session is gone" },
                             many: { "skipping \($0) sessions, all gone: \($1)" }) {
            trace?(line)
        }
        if let line = phrase(retiredNow,
                             one: { "retired \($0) after \(longestGone)s gone" },
                             many: { "retired \($0) sessions after \(longestGone)s gone: \($1)" }) {
            trace?(line)
        }
        if let line = phrase(revived, one: { "\($0) is live again" },
                             many: { "\($0) sessions live again: \($1)" }) { trace?(line) }
        if let heartbeat { trace?(heartbeat) }
    }

    /// One line whether it is one session or two hundred.
    ///
    /// At scale the information is *which projects and how many*, not two hundred
    /// repetitions of the same sentence — and since each line is a synchronous write
    /// on the main thread, collapsing them is a latency fix as much as a legibility
    /// one. A single session still reads as a sentence, because that is the case you
    /// are usually actually debugging.
    private static func phrase(_ labels: [String],
                               one: (String) -> String,
                               many: (Int, String) -> String) -> String? {
        guard let first = labels.first else { return nil }
        guard labels.count > 1 else { return one(first) }
        let counts = Dictionary(grouping: labels, by: { $0 })
            .map { (label: $0.key, count: $0.value.count) }
            .sorted { ($0.count, $1.label) > ($1.count, $0.label) }
        let shown = counts.prefix(5).map { "\($0.label)×\($0.count)" }.joined(separator: ", ")
        let hidden = counts.count - min(5, counts.count)
        return many(labels.count, hidden > 0 ? "\(shown), +\(hidden) more" : shown)
    }


    /// The badge. Shares the predicate with what a keypress will play, so the two
    /// cannot disagree.
    public func waitingCount() throws -> Int { try waiting().count }

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

        /// A2 hail, Core half. DORMANT twice over now: `announceNext` never
        /// spoke this, the app's spoken hail died on 10 Aug ("it never once
        /// announced successfully" — a chime carries the same information), and
        /// the spoken callsign itself died on 18 Aug. Kept as the one place
        /// that still knows how to say a session's name out loud, for whoever
        /// brings attribution back.
        public var hailText: String {
            event.callsign ?? Callsign.directoryWord(cwd: event.cwd)
        }
    }

    public enum AnnounceOutcome: Sendable {
        case spoke(Announcement)
        /// The gate said not now. The item stays queued — a veto can only delay.
        case held(reason: String)
        case nothingWaiting
        /// The audio did not reach its natural end. Whether the turn still
        /// counts as read is the cursor's business, settled in `speak`: any
        /// audio plus a user stop is OPENED and advances it; `failure` set
        /// (it stopped itself) or no sound at all leaves it unread.
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
        excluding inFlight: DeliveryInFlight = DeliveryInFlight(),
        onWillSpeak: (@MainActor (Announcement) -> Bool)? = nil,
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
            // The automatic path, and the one the bug was on: only here does the
            // delivery overlay apply. An explicitly named session (above) is a
            // direct request and keeps answering after you have replied to it.
            candidate = try nextToAnnounce(excluding: inFlight)
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

        if let ready = await prepared.take(session.sessionId, latest: session.latestId) {
            return try await speak(ready, for: session, onWillSpeak: onWillSpeak, onWord: onWord)
        }
        // Prepared miss — usually a restart. The brief for this exact event may
        // be durable (v6), in which case catch-up needs no model call and the
        // card fields survive. Only a genuine store miss re-summarizes.
        if let restored = restoredSummary(for: session) {
            return try await speak(restored, for: session, onWillSpeak: onWillSpeak, onWord: onWord)
        }
        let summary = await summarize(session)
        return try await speak(summary, for: session, onWillSpeak: onWillSpeak, onWord: onWord)
    }

    /// The session's durable voice, resolvable by anything that speaks on a
    /// session's behalf — the ⌃⌃ pull must sound like the announcement it
    /// deepens, not like the narrator. The cast is the persisted, user-edited
    /// VoiceRoster (was a hardcoded array here; re-ruled 05 Aug when the
    /// settings pane became the roster editor).
    public func voiceId(for sessionId: String) -> String? {
        (try? store.voiceId(for: sessionId, roster: VoiceRoster.load())) ?? nil
    }

    private func summarize(_ event: WaitingSession) async -> Summary {
        let context = event.transcriptPath.map {
            TranscriptArchive.sessionContext(in: URL(fileURLWithPath: $0))
        }
        let lastMessage = event.lastAssistantMessage?.isEmpty == false
            ? event.lastAssistantMessage!
            : (event.transcriptPath
                .flatMap { TranscriptArchive.lastAssistantMessage(in: URL(fileURLWithPath: $0)) } ?? "")

        // One agents probe serves both the lexicon's live names and the label
        // stripping in `strippingModelLabels` — summarizing must not double the
        // subprocess cost it already pays.
        let liveSessions = agents.sessions()

        // A7: the rolling lexicon joins the per-message allowlist, so a name
        // recent sessions established survives speech even when this one
        // message did not capitalize it.
        let lexicon = Lexicon.harvest(
            store: store, liveSessionNames: liveSessions?.compactMap(\.name) ?? [])

        let summary = await summarizer.summarize(SummaryRequest(
            lastAssistantMessage: lastMessage,
            projectLabel: event.projectLabel,
            firstUserMessage: context?.firstUserMessage,
            gitBranch: context?.gitBranch,
            cwd: event.cwd,
            hookEvent: event.hookEvent,
            notificationMatcher: event.notificationMatcher),
            lexicon: lexicon.allowlistTerms)

        if summary.provider == "empty-source" {
            Coordinator.trace?("summary skipped for empty source: event \(event.latestId) "
                + "session \(event.sessionId.prefix(8))")
        }
        if summary.provider.hasSuffix("+digit-scrubbed") {
            Coordinator.trace?("digit grounding scrubbed ungrounded number(s): "
                + "event \(event.latestId) session \(event.sessionId.prefix(8))")
        }
        let composed = strippingModelLabels(summary, for: event, liveSessions: liveSessions)
        persistBrief(composed, for: event)
        return composed
    }

    /// Write the generated brief to the store (v6 `brief` table) so a restart
    /// no longer loses the card fields. Same "successful summary" rule as
    /// callsign minting: the failure floors are not worth remembering — a
    /// restart re-summarizes those exactly as before. Persisting best-effort;
    /// a failed write degrades restart catch-up, never the announcement.
    private func persistBrief(_ summary: Summary, for event: WaitingSession) {
        let failedProviders: Set<String> = ["deterministic-fallback", "empty-source", "none"]
        guard !failedProviders.contains(summary.provider) else { return }
        do {
            try store.saveBrief(
                summary.brief, sessionId: event.sessionId, eventRowid: event.latestId,
                provider: summary.provider,
                callsign: event.callsign ?? ((try? store.callsign(for: event.sessionId)) ?? nil))
            // The hub catches up the moment the brief exists, not the moment a
            // turn is SPOKEN. Riding the announcement path alone meant a
            // session whose turns were read but never played kept a stale hub
            // — or none at all — and its card never grew the OPEN HTML door
            // (measured 15 Aug: this very repo's investigating session, four
            // briefs stored, zero hub writes). Preparation already runs off
            // the main actor, and a failure here is logged and dropped for
            // the same reason as at announcement: the page must never cost a
            // turn.
            do {
                _ = try HomeBase.write(sessionId: event.sessionId, store: store)
            } catch {
                Coordinator.trace?("homebase at persist failed for "
                    + "\(event.sessionId.prefix(8)): \(error)")
            }
        } catch {
            Coordinator.trace?("brief persist failed for event \(event.latestId): \(error)")
        }
    }

    /// The read-through behind `PreparedSummaries`: after a restart the memory
    /// is gone, but the brief for this exact event may be in the store. Rebuild
    /// the Summary from it — same mechanical callsign pass, same sanitizer,
    /// zero model calls — and tag the provider `+stored` so a restored
    /// announcement is distinguishable from a fresh one. Nil when the store has
    /// nothing for this event, in which case the caller summarizes as before.
    private func restoredSummary(for event: WaitingSession) -> Summary? {
        guard let stored = try? store.storedBrief(
            sessionId: event.sessionId, eventRowid: event.latestId) else { return nil }
        let brief = stored.brief

        // Same allowlist recipe as a fresh summarize, so a lexicon-established
        // name that survived generation is not re-redacted on restore.
        let lexicon = Lexicon.harvest(store: store)
        let speakable = SpokenTextSanitizer
            .speakableTerms(in: event.lastAssistantMessage ?? "")
            .union(lexicon.allowlistTerms)

        // Same strip as a fresh summary (`strippingModelLabels`) and for the
        // same reason: a restored brief is the model's words, and the model
        // opens with a label most of the time. It cannot reach the live-session
        // probe from here, so it strips the two labels it has.
        let labels = [event.projectLabel, stored.callsign, event.callsign].compactMap { $0 }
        let spoken = summarizer.sanitizer.strippingLeadingLabels(
            labels,
            from: summarizer.sanitizer.sanitize(brief.spokenText(), allowing: speakable))
        return Summary(spoken: spoken, brief: brief,
                       provider: stored.provider + "+stored", latencyMs: 0)
    }

    // MARK: - Attribution

    /// The recap starts with the recap. Ruled 18 Aug 2026.
    ///
    /// The spoken callsign is dead — the LAST of its jobs, after the grid took
    /// its column on 12 Aug and the hub page took its byline on 16 Aug ("on a
    /// page it read as a third identity competing with the two real ones").
    /// Two measurements ended it, both the operator's:
    ///
    ///  - **The project half names nothing.** Attribution by directory assumes
    ///    sessions are spread across directories and they are not — 23 of 127
    ///    minted signs begin "promotions", because that is where the work is.
    ///  - **The voice already says who.** `session_voice` assigns round-robin
    ///    from a 14-voice roster, and fewer than fourteen sessions are ever
    ///    live at once, so the voice is a distinct identity per speaker for
    ///    every case that actually occurs.
    ///
    /// And the topic half was indefensible on its own terms. Nothing chose it:
    /// the model wrote a topic sentence and `candidateTopicWords` took the
    /// LONGEST word in it, ties broken by position, as a proxy for
    /// distinctiveness. That is how a session came to be called "promotions
    /// stlth". The vowel gate added the same morning does not rescue it — it
    /// admits "b6y9z" and it admits "stealthy", which is wrong in a way no
    /// filter can see. A name is a context problem, not a validation problem,
    /// and the mechanism that would fix it (ask the model for a NAME, telling
    /// it the name is to be said out loud) is not worth building for a name
    /// with no remaining listener.
    ///
    /// What still has to happen is the STRIP. The tuned prompt asks the model
    /// to open with the project label and it complies 65/71, so without this
    /// the recap would open with a label-like prefix on most turns — chosen by
    /// the model, and wrong on the miss (brand-substitution: "Kopi:" from a
    /// promotions session whose CONTENT was about Kopi). Prepending is what
    /// stopped; stripping is what the prepending was hiding.
    ///
    /// Nothing is deleted to bring it back: `Callsign` still mints on demand,
    /// `session_callsign` keeps every name it has, and the stored ones still
    /// seed the recogniser's lexicon and still name a session in the grid
    /// until its tab has a title. Re-speaking it is this function again.
    private func strippingModelLabels(
        _ summary: Summary, for event: WaitingSession, liveSessions: [LiveSession]?
    ) -> Summary {
        let liveName = liveSessions?
            .first(where: { $0.sessionId == event.sessionId })?.name
        // The session's own stored callsign is stripped along with the labels:
        // a sign minted before today can still be echoed back by a model that
        // saw it in the transcript, and hearing the dead name is worse than
        // hearing it deliberately.
        let stored = event.callsign ?? ((try? store.callsign(for: event.sessionId)) ?? nil)
        let labels = [event.projectLabel, liveName, stored].compactMap { $0 }
        let spoken = summarizer.sanitizer.strippingLeadingLabels(labels, from: summary.spoken)
        return Summary(spoken: spoken, brief: summary.brief,
                       provider: summary.provider, latencyMs: summary.latencyMs)
    }

    private func speak(
        _ summary: Summary, for session: WaitingSession,
        onWillSpeak: (@MainActor (Announcement) -> Bool)?,
        onWord: (@Sendable (Range<Int>) -> Void)?
    ) async throws -> AnnounceOutcome {
        // Nothing is written before the audio. Marking it announced up front is what
        // let a stray tap spend a session's turn on something never heard, and what
        // let an interrupt handler write a stale copy back over a dismissal.
        let announcement = Announcement(
            event: session, brief: summary.brief, spoken: summary.spoken,
            via: speech.fallback.name)
        // The stage has to be TAKEN before anything is spoken into it.
        //
        // This callback used to return Void, so a refusal was invisible from here
        // and the announcement played anyway — for ten seconds, into an open
        // microphone, and then advanced the heard cursor because the audio had
        // "completed" (app.log 07 Aug 23:03:48: REFUSED listening -> speaking,
        // then twenty-one highlight callbacks and a cursor write). The panel was
        // authoritative for the pixels and for nothing behind them.
        //
        // Refusal is the same outcome as an interruption, and deliberately so:
        // the summary goes back to `prepared` and the cursor does not move, so
        // the session stays waiting, because it is.
        if let onWillSpeak, await onWillSpeak(announcement) == false {
            await prepared.put(summary, for: session.sessionId, latest: session.latestId)
            return .interrupted(failure: nil)
        }

        // The session's durable voice (ruled 05 Aug): assigned round-robin from
        // the roster on first announce, then identical for the session's life
        // across runs — the ear binds a voice to a stream of work faster than a
        // name, and two sessions on the same subject stop being confusable.
        let spoken = await speech.speak(
            summary.spoken, voice: voiceId(for: session.sessionId), onWord: onWord)

        // OPENED advances the cursor, not heard-to-the-end (re-ruled 13 Aug:
        // "honestly I never listen to the whole thing"). Audio started and the
        // user stopped it — they triaged the turn, and the next ⌃⌥ must move
        // on, not read the same message at someone who already walked out of
        // it. `heardAny` has carried exactly this distinction since it was
        // written ("starting to talk counts as read"); this is the first
        // consumer to honor it. Audio that never made a sound, or that stopped
        // itself (`failure` set), stays unread — a silent failure must not
        // consume a turn, which is the safety the old completed-only rule
        // existed for and the part of it that survives.
        //
        // Still nothing written BEFORE the audio, so a refusal or a pre-audio
        // stop needs no undo — the resurrection bug stays unrepresentable.
        if spoken.heardAny && spoken.failure == nil {
            try store.advanceCursor(sessionId: session.sessionId, heardThrough: session.latestId)
        }
        guard spoken.completed else {
            // Back into `prepared` either way: an opened turn is still
            // replayable on request (a grid-row tap, or ⌃⌥ once nothing is
            // unopened), and the replay must not pay for a second model call.
            await prepared.put(summary, for: session.sessionId, latest: session.latestId)
            return .interrupted(failure: spoken.failure)
        }
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
    /// succeeded, and offer it only if it was OPENED — audio reached you and
    /// either finished or you stopped it (13 Aug; "to the end" before that).
    /// Stopping part-way and replying is the normal gesture, and the session
    /// you just walked out of is exactly the one your words belong to. A
    /// failed attempt — no sound, or audio that stopped itself — still blocks
    /// replies rather than deferring to a stale one. Refusing is recoverable;
    /// typing into the wrong session is not.
    public func replyTarget() throws -> WaitingSession? {
        // The session you last heard from, and only while that is still true.
        //
        // This used to scan for the most recent `announced` row, which silently
        // stepped over a NEWER announcement that had failed — and routed a reply
        // into a terminal the user was not talking to. Now it is the cursor: the
        // last thing opened, valid only while it is still that
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
    /// `streamed:` is an optional live-transcription final captured while the
    /// user was speaking (`StreamedUtterance.finish`). Nil — the only value the
    /// app passes until streaming is wired — keeps this path byte-identical to
    /// before; a trustworthy final skips the recovery pass, nothing else changes.
    public func submitReply(
        pcm16: Data, sampleRate: Double = 16000, to sessionId: String? = nil,
        streamed: TranscriptionResult? = nil, preWritten: URL? = nil
    ) async throws -> ReplyOutcome {
        let target: WaitingSession?
        if let sessionId {
            target = try store.allKnownSessions()
                .first { $0.sessionId == sessionId }
        } else {
            target = try replyTarget()
        }
        guard let target else { return .noTarget }

        var utterance = try await store.captureAndTranscribe(
            pcm16: pcm16, sampleRate: sampleRate, chain: recovery, eventId: nil,
            streamed: streamed, preWritten: preWritten)

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
        // The drop tray's capture close: staged files bind to THIS utterance
        // and leave the chips. The text the undo window shows is the text
        // that will be typed — quoted paths included — so the disclosure IS
        // the message. Composed here and again at confirm, never by mutating
        // the transcript: transcriptText stays the record of what was heard,
        // and a cancel has nothing to restore because nothing was overwritten.
        let carrying = attachments.snapshot(
            session: target.sessionId, utteranceId: utterance.id)
        if !carrying.isEmpty {
            Coordinator.trace?("tray: \(carrying.count) file(s) riding \(utterance.id.prefix(8))")
        }
        return .readyToSend(
            utteranceId: utterance.id,
            text: AttachmentTray.compose(transcript: text, paths: carrying),
            label: target.projectLabel,
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
              let target = try store.allKnownSessions()
                  .first(where: { $0.sessionId == sessionId })
        else {
            // A confirm with nowhere to go: whatever this utterance was
            // carrying goes back to the chips rather than riding a ghost.
            attachments.resolve(utteranceId: utteranceId, landed: false)
            return .noTarget
        }

        try enrolment.enrol(sessionId: target.sessionId)
        // Same composition as readyToSend showed, from the same riding set —
        // the user confirms exactly the text that dispatches.
        let outgoing = AttachmentTray.compose(
            transcript: text, paths: attachments.riding(utteranceId: utteranceId))
        return try await dispatch(utterance: &utterance, text: outgoing, target: target)
    }

    /// The user said no. Keep the audio and transcript — they are evidence of what
    /// was heard — but take it out of the sendable set so nothing resends it later.
    public func cancelSend(utteranceId: String) throws {
        // The message definitely did not land, so its files return to the
        // chips untouched (ruled 15 Aug: not sending never clobbers).
        attachments.resolve(utteranceId: utteranceId, landed: false)
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
        // A session that has JUST registered can drop back out of
        // `claude agents --json` before it has taken any input — measured
        // 19 Aug: 0f327de7 registered at 00:21:34, bound correctly, and came
        // back `notRegistered` at 00:22:17, which surfaced as "can't take this
        // yet — try again in a moment". Trying again is a loop, and a loop is
        // the machine's job. So the wait happens here, once, rather than being
        // handed to the user as an instruction.
        //
        // Bounded and short: `notRegistered` also means blocked on a trust
        // dialog, where no amount of waiting helps and the refusal below is the
        // honest answer. This buys the booting case and costs the blocked case
        // a few seconds it was going to lose anyway.
        var live = (agents.sessions() ?? [])
            .first(where: { $0.sessionId == target.sessionId })
        if live == nil {
            let deadline = Date().addingTimeInterval(readinessGrace)
            while live == nil, Date() < deadline {
                try? await Task.sleep(nanoseconds: 500_000_000)
                live = (agents.sessions() ?? [])
                    .first(where: { $0.sessionId == target.sessionId })
            }
            if live != nil {
                Coordinator.trace?("dispatch: \(target.sessionId.prefix(8)) came back "
                    + "inside the readiness grace")
            }
        }
        guard let live else {
            // Absent from `claude agents --json` means blocked on a dialog or gone.
            // Injecting would answer the dialog, so we refuse and keep the audio.
            // The files did not land either; back to the chips. A later
            // re-confirm of this utterance therefore goes without them — they
            // ride the next reply instead, which can never duplicate.
            attachments.resolve(utteranceId: utterance.id, landed: false)
            utterance.status = .ready
            try store.update(utterance: utterance)
            return .sessionNotReady(.notRegistered)
        }

        // The transcript is resolved again here when the row has none. Delivery
        // is confirmed by watching our own text appear in it, so a missing path
        // is not a missing detail — it is a send that can only ever report
        // itself unconfirmed. Every event written by a hook carries one; the
        // one the APP writes (a launch greeting) is written before the session
        // has finished coming up, and a file that did not exist then usually
        // does by the time anyone replies.
        let dispatchTarget = DispatchTarget(
            sessionId: target.sessionId,
            pid: live.pid,
            tty: ProcessProbe.tty(of: live.pid),
            transcriptPath: target.transcriptPath
                ?? TranscriptArchive.transcriptPath(forSessionId: target.sessionId),
            label: target.projectLabel)

        utterance.status = .dispatching
        utterance.targetKind = transport.kind
        utterance.targetSessionId = target.sessionId
        utterance.targetPid = live.pid
        utterance.targetTty = dispatchTarget.tty
        utterance.dispatchAttempts += 1
        utterance.lastDispatchAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        try store.update(utterance: utterance)

        // The tray's fate rides the same exhaustive switch as the utterance's
        // status — one clear-site, not five. Landed (or possibly landed)
        // clears; everything else returns the files to the chips.
        switch await transport.send(text: text, to: dispatchTarget) {
        case .queued:
            // Delivered into a session that is mid-turn. It will send itself when
            // that turn ends. Treated as answered, because it is: the words are in
            // the tab and nobody has to do anything else.
            attachments.resolve(utteranceId: utterance.id, landed: true)
            utterance.status = .confirmed
            utterance.confirmedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            utterance.lastError = "queued behind the current turn"
            try store.update(utterance: utterance)

            // A delivered reply is what answers: both cursors advance, the row
            // unlights. Hearing alone never does this (read is not answered).
            try store.advanceCursor(sessionId: target.sessionId,
                                    heardThrough: target.latestId,
                                    dismissedThrough: target.latestId)
            return .queued(text: text, sessionId: target.sessionId)

        case .confirmed(let latencyMs):
            attachments.resolve(utteranceId: utterance.id, landed: true)
            utterance.status = .confirmed
            utterance.confirmedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            try store.update(utterance: utterance)

            try store.advanceCursor(sessionId: target.sessionId,
                                    heardThrough: target.latestId,
                                    dismissedThrough: target.latestId)
            return .dispatched(text: text, latencyMs: latencyMs, sessionId: target.sessionId)

        case .deferred(let readiness):
            attachments.resolve(utteranceId: utterance.id, landed: false)
            utterance.status = .ready
            try store.update(utterance: utterance)
            return .sessionNotReady(readiness)

        case .failed(let failure):
            // Verification timeouts stay `dispatchedUnconfirmed`: the text may have
            // landed, and a retry could duplicate it. A human decides.
            // The tray follows the same doctrine: a timeout's files count as
            // landed (keeping them staged would make the next reply a
            // possible double-send, and a duplicate is worse than a drop).
            attachments.resolve(utteranceId: utterance.id,
                                landed: failure == .verificationTimedOut)
            utterance.status = failure == .verificationTimedOut ? .dispatchedUnconfirmed : .dispatchFailed
            utterance.lastError = "\(failure)"
            try store.update(utterance: utterance)
            return .dispatchFailed(failure, utteranceId: utterance.id)
        }
    }
}
