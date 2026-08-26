import Foundation

/// The announce half of `Coordinator`, split out 23 Aug (Coordinator-split
/// rider) purely for navigability — `Coordinator.swift` had grown past 1,300
/// lines and mixed three concerns (announcing, replying, sweeping) in one
/// file. No behavior changed and no public API moved: this is still
/// `Coordinator`'s own announce logic, in its own file. `SessionSweep`
/// (the third of the three) went further, into a real injectable type —
/// see its own doc comment for why that one was worth the bigger move and
/// this one wasn't (yet): sweep's state was already isolated behind a
/// narrow interface, while announce and reply share `prepared`, `store`,
/// and most of `Coordinator`'s other stored properties throughout.
extension Coordinator {
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
            sweep.noteProbeFailure(trace: Coordinator.trace)
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
        //
        // `sessions` only ever answers for Claude Code — `agents` is
        // `claude agents --json`, harness-specific by construction, and a
        // Codex session is never in it, registered or not. Found live, 26
        // Aug: a fresh Codex launch's greeting card read as "gone" the
        // instant this function first polled it, seconds after it had
        // actually registered. `liveNonRegistrySessions()` is `ownership`'s
        // own recorded pid — the only other liveness fact this app has for
        // a harness with no registry — factored out once (26 Aug) after the
        // same gap turned up at roughly thirty call sites, not just this one.
        let live = Set(sessions.map(\.sessionId))
            .union(ownership.liveNonRegistrySessions().map(\.sessionId))
        let all = yours(try store.waitingSessions())
        sweep.sweep(all, live: live, trace: Coordinator.trace)
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
    //
    // Extracted into its own injectable type, `SessionSweep` (23 Aug,
    // Coordinator-split rider) — see its doc comment for the five rules
    // and why the state moved out of a set of Coordinator's own statics.
    // `waiting()`, above, is the only caller.

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
        // subprocess cost it already pays. Codex names, from `ownership`, ride
        // along too (26 Aug) — cosmetic on its own (a name capitalized wrong
        // in speech, not a functional break), fixed anyway since a full audit
        // means closing the small instances too, not just the loud ones.
        let liveSessions: [LiveSession]? = agents.sessions().map { $0 + ownership.liveNonRegistrySessions() }

        // A7: the rolling lexicon joins the per-message allowlist, so a name
        // recent sessions established survives speech even when this one
        // message did not capitalize it.
        let lexicon = Lexicon.harvest(
            store: store, liveSessionNames: liveSessions?.compactMap(\.name) ?? [])

        let summary = await summarizer.summarize(SummaryRequest(
            lastAssistantMessage: lastMessage,
            projectLabel: event.projectLabel,
            firstUserMessage: context?.firstUserMessage,
            // The transcript first, then the working directory. A session
            // whose own cwd is not a repository records "HEAD" for every
            // entry while doing all of its work inside worktrees that are each
            // on a real branch — and the hub keys pull requests on the branch,
            // so "HEAD" means a hub with nothing on it. Read at turn end,
            // which is when this fires, so it is that turn's branch.
            // The goal this session is already carrying, so the model keeps it
            // instead of writing its seventeenth restatement (measured 19 Aug:
            // 59 sessions, 17 turns each, 17 distinct goals each).
            previousGoal: try? store.carriedGoal(for: event.sessionId),
            gitBranch: Coordinator.branch(transcript: context?.gitBranch, cwd: event.cwd),
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
        // A cancelled announce speaks nothing. Without this gate, a ⌃⌥ home
        // during summarize sailed straight on: the summarizer chain read the
        // cancellation as a model failure and degraded to the deterministic
        // floor, the speech chain read it as a voice failure and degraded to
        // the system voice — and an announcement already dismissed spoke
        // anyway, cut short and in the wrong voice (app.log 20 Aug 14:13:49).
        // A real summary goes back to `prepared` so the next press speaks it
        // instantly; the "none" husk a cancelled summarize leaves is dropped,
        // and that press re-summarizes fresh.
        guard !Task.isCancelled else {
            if summary.provider != "none" {
                await prepared.put(summary, for: session.sessionId, latest: session.latestId)
            }
            return .interrupted(failure: nil)
        }
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

        // On the record which brief is about to be heard: `deterministic-fallback`
        // here is the floor excerpt standing in for a model summary, and how often
        // that happens was unanswerable from the logs when it mattered (20 Aug —
        // the store only keeps the final brief, so the spoken one vanished).
        Coordinator.trace?("announce: brief by \(summary.provider) "
            + "for \(session.sessionId.prefix(8))")

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

    /// "HEAD" is not a branch — it is what git reports for a detached checkout
    /// and what Claude Code records when the session's own directory is not a
    /// repository. Treated as absent, so the working directory gets its turn.
    static func branch(transcript: String?, cwd: String?) -> String? {
        if let transcript, !transcript.isEmpty, transcript != "HEAD" { return transcript }
        guard let cwd else { return nil }
        return GitRemote.currentBranch(cwd: cwd)
    }
}
