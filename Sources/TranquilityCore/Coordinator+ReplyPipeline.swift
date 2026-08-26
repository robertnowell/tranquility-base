import Foundation

/// The reply half of `Coordinator` — target resolution, submit/confirm/
/// cancel, and dispatch — split out 23 Aug for the same navigability
/// reason as `Coordinator+Announcer.swift`; see that file's doc comment.
extension Coordinator {
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
        // `pid` is the pid dispatch actually used — after an ownership
        // transfer (`resumeTwin`) this is the NEW process, not whatever was
        // live when the reply started. Carried so the caller can push it
        // back to the panel's own target (`StatusHUD.attachLivePid`); before
        // this, a successful dispatch through a transfer left GO TO AGENT
        // pointed at the pid the transfer had just, on purpose, ended
        // (found live, 23 Aug).
        case dispatched(text: String, latencyMs: Int, sessionId: String, pid: Int?)
        /// Typed into a session that was mid-turn; it sends when that turn ends.
        case queued(text: String, sessionId: String, pid: Int?)
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
    /// `utteranceId:` pre-mints the row's id (see `captureAndTranscribe`), so
    /// the panel's retry can retire the attempt this call created if a human
    /// supersedes it mid-transcription.
    public func submitReply(
        pcm16: Data, sampleRate: Double = 16000, to sessionId: String? = nil,
        streamed: TranscriptionResult? = nil, preWritten: URL? = nil,
        utteranceId: String? = nil
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
            streamed: streamed, preWritten: preWritten, utteranceId: utteranceId)

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

    /// `dispatch`'s Codex twin for `preferringTmuxOwned` — same question
    /// (is this session live, and which pane does it own), a different
    /// source, for the same reason `Coordinator+Announcer.swift`'s
    /// `waiting()` needed one (26 Aug): Codex is never in `agents`. The
    /// ownership record already carries a verified pid and, since 26 Aug,
    /// its pane — nothing here shells out or waits.
    private func codexResolved(_ sessionId: String) -> (session: LiveSession, pane: TmuxPaneAddress?)? {
        guard let record = ownership.verifiedCurrent(sessionId: sessionId),
              record.harness == CodexAdapter().id else { return nil }
        let session = LiveSession(pid: record.pid, sessionId: sessionId, cwd: record.cwd,
                                  status: "idle", name: nil, waitingFor: nil)
        return (session, record.pane)
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
        // `agents` never carries a Codex session — the SAME gap `waiting()`
        // had (its own 26 Aug doc comment), found here the same day by
        // asking one question further: a Codex session's greeting card now
        // correctly stays on stage, but the reply that answers it still
        // reaches THIS resolution, which would wait the full
        // `readinessGrace` doing nothing (Codex is never coming back from a
        // probe it was never in) and then refuse with "can't take this yet"
        // — a real, working session, telling the truth about its own
        // absence from a registry that was never going to carry it. Checked
        // first, not folded into the retry loop below: `ownership`'s record
        // already carries the pid and pane, so there is nothing to wait
        // for, unlike the grace period's actual job of tolerating Claude
        // Code's OWN transient registry gaps.
        // Which of the two sources answered — carried forward so the
        // `DispatchTarget` built below can ask `TmuxTransport.readiness(for:)`
        // the Codex-shaped question instead of the Claude Code-shaped one it
        // silently defaulted to before (see the doc comment on `dispatchTarget`
        // itself, added the same day this was found, 26 Aug).
        var isCodex = false
        var resolved = (agents.sessions() ?? [])
            .preferringTmuxOwned(sessionId: target.sessionId, trace: Coordinator.trace)
        if resolved == nil, let codex = codexResolved(target.sessionId) {
            resolved = codex
            isCodex = true
        }
        if resolved == nil {
            let deadline = Date().addingTimeInterval(readinessGrace)
            while resolved == nil, Date() < deadline {
                try? await Task.sleep(nanoseconds: 500_000_000)
                resolved = (agents.sessions() ?? [])
                    .preferringTmuxOwned(sessionId: target.sessionId, trace: Coordinator.trace)
            }
            if resolved != nil {
                Coordinator.trace?("dispatch: \(target.sessionId.prefix(8)) came back "
                    + "inside the readiness grace")
            }
        }
        guard let (fixedLive, resolvedPane) = resolved else {
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
        // Mutable only for the ownership-transfer branch below, which
        // re-resolves it after ending and replacing this exact process.
        var live = fixedLive

        // The transcript is resolved again here when the row has none. Delivery
        // is confirmed by watching our own text appear in it, so a missing path
        // is not a missing detail — it is a send that can only ever report
        // itself unconfirmed. Every event written by a hook carries one; the
        // one the APP writes (a launch greeting) is written before the session
        // has finished coming up, and a file that did not exist then usually
        // does by the time anyone replies.
        // A first-party background session has no tab and no supported input
        // channel (`claude --bg-pty-host`, PR #1). Typing at one routes into
        // nothing — Anthropic's own agent-teams shipped exactly that silent
        // drop (#58762) — so the refusal is loud and the reply stays queued.
        if live.isBackground {
            Coordinator.trace?("dispatch: \(target.sessionId.prefix(8)) is a background "
                + "session (no input channel); refusing")
            attachments.resolve(utteranceId: utterance.id, landed: false)
            utterance.status = .ready
            try store.update(utterance: utterance)
            return .sessionNotReady(.notRegistered)
        }

        // Ownership decides the transport, from live server inventory only.
        // The tty is recorded as an identity guard and a display fact; it is
        // never again an address (19 Aug misfire: dead Terminal windows held
        // a tty string the tmux server had recycled for this very pane).
        //
        // Reused from selection when duplicates forced a live lookup there —
        // a second `pane(forPid:)` call for the same pid, moments later, can
        // disagree with the first if a pane closes in between, and a row
        // chosen BECAUSE it was tmux-owned dispatching a beat later as
        // `.terminalApp` is the 19 Aug misfire's shape exactly. The common
        // single-row path never paid that lookup, so it resolves fresh here.
        var pane = resolvedPane
            ?? TmuxOwnership.pane(forSessionId: live.sessionId, pid: live.pid)

        // No tmux-owned row for this sessionId at all: a hand-started session
        // TB has never touched, on its FIRST dispatch. Resume it under tmux
        // now (via the injected `resumeTwin`, never a bare static call — see
        // its own doc comment for why) rather than falling to AppleScript,
        // which types straight into whatever the user may be looking at in
        // their own terminal — the exact splice `TmuxTransport`'s floor check
        // exists to prevent, and `TerminalAppTransport` cannot check for at
        // all (22 Aug, 2026-08-22-tb-terminal-architecture: the AppleScript
        // fallback here was never a real design choice, just unfinished
        // wiring next to a mechanism — `resumeTmux` — that already does this
        // exact job and was already live for Codex).
        //
        // The ORIGINAL process IS signalled now — reversed 23 Aug, the same
        // day as the line above it was true: this used to leave the
        // hand-started process running dual-live beside the tmux twin, on
        // the premise that Claude Code's own Remote Control would keep the
        // two in sync. It does not, in practice — nothing was watching the
        // hand-started terminal any more once dispatch started answering the
        // twin instead, so every reply after the first routed somewhere the
        // human had no way to see (found live, sessionId f37aaddd, this very
        // session). `resumeTwin`'s default implementation now ends the
        // hand-started process and confirms it is gone before resuming under
        // tmux, so there is exactly one live process per session afterward.
        // The bar is still that dispatch WORKS — lands, gets answered, and
        // TB reads the state back — it just no longer accepts "somewhere a
        // human can't see" as satisfying that bar. Every dispatch after this
        // one finds the twin already live in `agents --json` and
        // `preferringTmuxOwned` picks it deterministically, so this only
        // ever runs once per session.
        // Codex-only: `codexResolved` already carries the ownership record's
        // pane, so this branch is not reached for Codex in the normal case —
        // but a record with no pane saved must still refuse rather than run
        // `resumeTwin`, which is Claude Code's hand-started-process-adoption
        // concept and has no Codex meaning (Codex sessions are always
        // tmux-launched from the start; see `TmuxTransport.swift`'s own
        // audit note on this, 26 Aug).
        if pane == nil, !isCodex, let cwd = live.cwd {
            pane = resumeTwin(target.sessionId, cwd)
            if pane != nil {
                // The transfer just ended `live.pid`'s process on purpose
                // (ownership TRANSFER, not a parallel twin — see resumeTwin's
                // own doc comment) and started a fresh one under tmux.
                // Everything downstream that still reads `live.pid` —
                // DispatchTarget's own pid, the utterance's targetPid, and
                // ultimately the panel's GO TO AGENT — would otherwise carry
                // the pid this call just deliberately killed (found live, 23
                // Aug: GO TO AGENT read "couldn't find a terminal for
                // process 21081 — it may have exited", which was true and
                // was also the point). Re-resolve so they carry the pid that
                // is actually live now.
                if let refreshed = (agents.sessions() ?? [])
                    .first(where: { $0.sessionId == target.sessionId }) {
                    live = refreshed
                } else {
                    Coordinator.trace?("dispatch: \(target.sessionId.prefix(8)) transferred "
                        + "to tmux but hasn't reappeared in agents --json yet — pid may "
                        + "be stale downstream")
                }
            }
            Coordinator.trace?(pane != nil
                ? "dispatch: \(target.sessionId.prefix(8)) had no tmux twin — resumed one"
                : "dispatch: \(target.sessionId.prefix(8)) has no tmux twin and resuming "
                    + "one failed")
        }
        // tmux is the ONLY transport (single-transport cut, 23 Aug, on the
        // operator's own instruction: "I don't know why tmux would ever be
        // not available... is there really a situation where tmux would not
        // be available for us to still need Terminal app transport?" —
        // there wasn't one worth building a whole second, far-less-tested
        // transport around). A hand-started session with no tmux twin and a
        // failed transfer refuses cleanly here, rather than silently
        // rerouting through AppleScript the way `TerminalAppTransport` once
        // did.
        guard let pane else {
            attachments.resolve(utteranceId: utterance.id, landed: false)
            utterance.status = .ready
            try store.update(utterance: utterance)
            return .dispatchFailed(
                .injectionFailed("tmux is unavailable for this session"),
                utteranceId: utterance.id)
        }
        // Every field below `pane` used to default to Claude Code's own
        // shape (`readinessSource: .claudeAgents`, its `❯` glyph, its JSONL
        // transcript path) on EVERY dispatch, Codex included — there was no
        // branch here at all. Found live, 26 Aug, dispatching to a session
        // that had just registered and was sitting idle: `readiness(for:)`'s
        // `.claudeAgents` case asks `agents.sessions()`, which never carries
        // Codex, so it read `.notRegistered` and refused with "blocked on a
        // dialog or still starting up" — on a session that was neither. The
        // `.rolloutTail` case exists for exactly this and was already wired
        // through `TmuxTransport` and `tbase send`'s own CLI dispatch path
        // (`Sources/tbase/main.swift`); only THIS call site, the one real
        // voice-reply dispatch, never set it. `target.transcriptPath` is
        // Claude Code-shaped too (`TranscriptArchive`'s JSONL convention) and
        // is never trusted for Codex, matching `tbase send`'s own pattern —
        // `CodexRollout.rolloutPath` is computed fresh instead.
        let dispatchTarget = DispatchTarget(
            kind: .tmux,
            sessionId: target.sessionId,
            pid: live.pid,
            tty: ProcessProbe.tty(of: live.pid),
            pane: pane,
            transcriptPath: isCodex
                ? CodexRollout.rolloutPath(forSessionId: target.sessionId)
                : (target.transcriptPath
                    ?? TranscriptArchive.transcriptPath(forSessionId: target.sessionId)),
            label: target.projectLabel,
            readinessSource: isCodex ? .rolloutTail : .claudeAgents,
            promptGlyph: isCodex ? CodexAdapter().capabilities.promptGlyph : "❯",
            idlePlaceholder: isCodex ? CodexAdapter().trustPrompt?.settledBannerNeedle : nil,
            pasteChip: isCodex ? CodexAdapter().capabilities.pasteChipPrefix : "[Pasted text #")

        utterance.status = .dispatching
        utterance.targetKind = dispatchTarget.kind
        utterance.targetSessionId = target.sessionId
        utterance.targetPid = live.pid
        utterance.targetTty = dispatchTarget.tty
        utterance.dispatchAttempts += 1
        utterance.lastDispatchAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        try store.update(utterance: utterance)

        // The tray's fate rides the same exhaustive switch as the utterance's
        // status — one clear-site, not five. Landed (or possibly landed)
        // clears; everything else returns the files to the chips.
        switch await tmuxTransport.send(text: text, to: dispatchTarget) {
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
            return .queued(text: text, sessionId: target.sessionId, pid: dispatchTarget.pid)

        case .confirmed(let latencyMs):
            attachments.resolve(utteranceId: utterance.id, landed: true)
            utterance.status = .confirmed
            utterance.confirmedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            try store.update(utterance: utterance)

            try store.advanceCursor(sessionId: target.sessionId,
                                    heardThrough: target.latestId,
                                    dismissedThrough: target.latestId)
            return .dispatched(text: text, latencyMs: latencyMs, sessionId: target.sessionId,
                              pid: dispatchTarget.pid)

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
