import AppKit
import CryptoKit
import TranquilityCore

/// AppDelegate's reply half -- dispatch, dismissal, the drop target, the
/// waiting badge -- split out of main.swift (App-lane P7, 24 Aug); see
/// AppDelegate+Permissions.swift's doc comment for why.

extension AppDelegate {
    /// Dispatch a transcript whose undo window has closed, and say exactly what
    /// happened. "Couldn't send it" hid a `try?` that swallowed the real outcome —
    /// including the one case that matters most, where the text may have landed but
    /// the read-back could not confirm it.
    func send(utteranceId: String, label: String, sessionId: String) {
        guard let coordinator else { return }
        let mine = replyGeneration
        Task { @MainActor in
            // The second half of the delivery window (see DeliveryInFlight):
            // the capture handed it to the countdown, the countdown handed it
            // here, and it closes on the outcome however that outcome reads.
            // Same discipline as the first half — one defer, not seven cases.
            defer { delivering.finished(sessionId: sessionId) }
            guard mine == replyGeneration else {
                // Superseded between the timer firing and this running.
                try? coordinator.cancelSend(utteranceId: utteranceId)
                return
            }
            // The countdown completing was the confirmation; a "Sending…" card
            // after it is a second wait the user already served. Ready comes back
            // immediately — you can talk again or move on while the dispatch and
            // its read-back verification run behind the scenes. Only repaint if
            // the stage is actually free: on a ⌃⌥ commit-and-advance the next
            // announcement is already preparing, and this must not stomp it.
            // The undo window closed, which is the moment the user CONFIRMED the
            // send. Ruled 18 Aug: "dispatch means turn done" — so this is the
            // closure cue, and it is the only falling figure in the set.
            Earcons.play(.dispatched, gate: earconGate())
            lastStatusLine = "sending to \(label)…"
            // The whisper (ruled 06 Aug): the words are on their way, said
            // without taking the stage from whatever is on it.
            hud.showReceipt(.sending(label))
            if hud.canSurfaceAmbiently {
                showIdleGrid()
            }
            // A dispatch that reaches any of the failure branches below (in the
            // switch or the catch) was typed at, or attempted against, a target
            // this app just talked to — `about`'s pid used to be structurally
            // absent (the tuple carried none), so GO TO AGENT could never grow
            // on a failure card even when the session was undeniably alive,
            // which is the ordinary case for `sessionNotReady`/
            // `verificationTimedOut`. One lookup, reused everywhere below;
            // naturally nil for the "tab is gone" branches, where nil is right.
            // `agents` alone missed a live Codex session every time (26 Aug) —
            // `liveNonRegistrySessions()` adds ownership's own answer for a
            // harness with no registry of its own.
            let pid = ((ClaudeAgentsCLI().sessions() ?? [])
                + FileSessionOwnershipStore.shared.liveNonRegistrySessions())
                .first(where: { $0.sessionId == sessionId })?.pid
            do {
                let outcome = try await coordinator.confirmAndSend(utteranceId: utteranceId)
                Permissions.log("confirmAndSend -> \(outcome)")
                // The confirm round-trip can outlive the user's attention: they may
                // already be listening to the NEXT session when this lands. The
                // stage arbiter handles that now — a success receipt asking to
                // paint over live speech or a capture is refused inside
                // showResult, and the REFUSED transition log is its receipt.
                // Failures always surface: they are the case with work left to do.
                switch outcome {
                // Success says nothing: the countdown already confirmed, the
                // status line and log carry the receipt, and a third card for a
                // thing that went right was indistinguishable noise (user report,
                // 05 Aug — "two further states, all saying different things").
                case .queued(_, _, let dispatchedPid):
                    hud.showReceipt(.queued)
                    lastStatusLine = "queued in \(label), sends when its turn finishes"
                    Permissions.log("send: queued in \(label)")
                    // A queued/dispatched reply can have gone through an
                    // ownership transfer (resumeTwin ends the hand-started
                    // process and resumes fresh under tmux) — the pid this
                    // outcome actually landed on is not necessarily the one
                    // the card was bound to when it was first shown. Syncs
                    // GO TO AGENT the same way `attachLivePid` already does
                    // for a revive that lands on a decision (found live, 23
                    // Aug: without this, the button kept pointing at the pid
                    // the transfer had just, on purpose, ended).
                    if let dispatchedPid {
                        hud.rebindLivePid(dispatchedPid, sessionId: sessionId)
                    }
                case .dispatched(_, _, _, let dispatchedPid):
                    hud.showReceipt(.sent)
                    lastStatusLine = "sent to \(label)"
                    Permissions.log("send: confirmed to \(label)")
                    if let dispatchedPid {
                        hud.rebindLivePid(dispatchedPid, sessionId: sessionId)
                    }
                case .sessionNotReady(let readiness):
                    // Sanctioned change (b): the actual condition in plain words,
                    // not the enum case's name. Mapping documented in
                    // StateLegend.plainWords(for:).
                    Earcons.play(.needsYou, gate: earconGate())
                    hud.showResult(
                        "\(label) can't take this yet, \(StateLegend.plainWords(for: readiness)). "
                        + "Your words are kept. Try again in a moment.",
                        about: (sessionId: sessionId, pid: pid, label: label))
                // ── Every branch below is a FAILURE, and every one of them puts
                // the words on the clipboard. Ruled 25 Aug: "when dispatch to an
                // agent fails, it should copy transcript text to clipboard."
                // Two of these branches already did, and the reasoning written
                // for them — "kept must mean usable, not archived" — was never
                // specific to a missing tab. A person who has just spoken a
                // paragraph and been told it failed should be one ⌘V from
                // sending it by hand, whatever the failure was.
                case .dispatchFailed(.verificationTimedOut, _):
                    // Documented as ambiguous and never auto-retried: only a human
                    // can decide whether to repeat themselves. That is needs-you.
                    Earcons.play(.needsYou, gate: earconGate())
                    hud.showResult(
                        "Typed it into \(label), but couldn't confirm it landed. "
                        + "Check the tab before repeating yourself. "
                        + wordsKept(utteranceId: utteranceId),
                        about: (sessionId: sessionId, pid: pid, label: label))
                case .dispatchFailed(.tabNotFound, let utteranceId),
                     .dispatchFailed(.targetGone, let utteranceId):
                    // The destination no longer exists — "kept" must mean usable,
                    // not archived. The words go to the clipboard, plainly said.
                    Earcons.play(.needsYou, gate: earconGate())
                    let copied = copyTranscriptToClipboard(utteranceId: utteranceId)
                    hud.showResult(
                        StateLegend.tabGoneRescueMessage(label: label, copied: copied),
                        about: (sessionId: sessionId, pid: pid, label: label))
                case .dispatchFailed(let failure, _):
                    Earcons.play(.needsYou, gate: earconGate())
                    hud.showResult("Couldn't type into \(label): \(failure). "
                                   + wordsKept(utteranceId: utteranceId),
                                   about: (sessionId: sessionId, pid: pid, label: label))
                case .noTarget:
                    Earcons.play(.needsYou, gate: earconGate())
                    hud.showResult("That reply lost its agent. "
                                   + wordsKept(utteranceId: utteranceId),
                                   about: (sessionId: sessionId, pid: pid, label: label))
                default:
                    Earcons.play(.needsYou, gate: earconGate())
                    hud.showResult("Unexpected result: \(outcome). "
                                   + wordsKept(utteranceId: utteranceId),
                                   about: (sessionId: sessionId, pid: pid, label: label))
                }
            } catch {
                Permissions.log("confirmAndSend threw: \(error)")
                Earcons.play(.needsYou, gate: earconGate())
                hud.showResult("Send failed: \(error). "
                               + wordsKept(utteranceId: utteranceId),
                               about: (sessionId: sessionId, pid: pid, label: label))
            }
            rebuildMenu()
        }
    }

    /// Dismiss whatever the panel is showing, through its latest event.
    func dismissCurrent(_ sessionId: String) {
        guard let coordinator else { return }
        guard let latest = try? coordinator.waiting().first(where: { $0.sessionId == sessionId })
        else { return }
        try? coordinator.dismiss(sessionId: sessionId, through: latest.latestId)
        Permissions.log("dismissed \(sessionId.prefix(8)) through event \(latest.latestId)")
    }

    /// Who the next reply would go to, resolved BEFORE the microphone opens.
    ///
    /// Every mic-opening path runs through this, for two reasons. First, the panel
    /// must name the session and terminal while you talk — addressing you cannot
    /// see is addressing you cannot check, and one misroute already proved it.
    /// Second, if there is no target, the honest move is refusing to record, not
    /// transcribing a reply in order to discover it has nowhere to go.
    /// Where the words you are about to speak will go. The decision, and only
    /// the decision — `ReplyRouting.destination` in Core owns the ladder, is
    /// pure, and is unit tested; this supplies the three facts it reads.
    ///
    /// Called at mic-open and nowhere else. The send addresses what this
    /// returned; it never asks again. Re-deriving at send time is how the HTML
    /// button's reply reached the wrong session.
    func replyDestinationNow() -> ReplyDestination {
        ReplyRouting.destination(
            launch: pendingLaunch,
            conversationNow: activeConversation?.sessionId,
            lastHeard: (try? coordinator?.replyTarget() ?? nil)?.sessionId)
    }

    /// What we know about a session we have already decided to address.
    ///
    /// Split from the decision deliberately (24 Aug). This needs a subprocess
    /// probe, and tangling the probe with the choice is what kept the most
    /// consequential decision the app makes in the layer that has no unit tests.
    func describe(session id: String) -> (sessionId: String, pid: Int?, label: String, cwd: String?) {
        let live = ((ClaudeAgentsCLI().sessions() ?? [])
            + FileSessionOwnershipStore.shared.liveNonRegistrySessions()).first { $0.sessionId == id }
        if let conversation = activeConversation, conversation.sessionId == id {
            return (id, live?.pid, conversation.label, conversation.cwd)
        }
        guard let target = try? coordinator?.replyTarget() ?? nil, target.sessionId == id else {
            return (id, live?.pid, live?.name ?? id, nil)
        }
        // One displayed identity (re-ruled 05 Aug): the tab's string,
        // checkable at a glance — see tabDisplayName.
        return (id, live?.pid, tabDisplayName(for: target, live: live), target.cwd)
    }

    /// Adopt a decided destination: paint it, and remember it for the send.
    func beginCapture(to destination: ReplyDestination) {
        recordingDestination = destination
        switch destination {
        case .session(let id):
            let d = describe(session: id)
            hud.adoptTarget(sessionId: d.sessionId, pid: d.pid, label: d.label, cwd: d.cwd)
        case .launch:
            // Nothing to adopt: the card is already the launch's, and the words
            // wait for the agent at submit time.
            break
        case .dictation:
            hud.dictationDestination = FocusedInput.focusedEditableApp()
                .map { StateLegend.destination($0) } ?? StateLegend.clipboardDestination
        }
    }

    /// Recompute who a dropped file would go to.
    ///
    /// Literally the same ladder your voice walks, not a copy of it — this
    /// comment used to claim "the same ladder `resolveReplyContext` walks"
    /// while walking a hand-written second one beside it. Two ladders that
    /// agree today is the arrangement that produced the 24 Aug misroute, so
    /// this calls the one in Core. A file must land where your voice would, or
    /// the panel is naming one destination and using another.
    ///
    /// A launch with no id yet has nowhere to stage a file, so it is no target
    /// — honest, and strictly better than the previous answer, which was the
    /// agent you were talking to BEFORE you pressed + NEW AGENT.
    func refreshDropTarget() {
        switch replyDestinationNow() {
        case .session(let id):
            if let conversation = activeConversation, conversation.sessionId == id {
                dropTarget = (id, conversation.label)
            } else if let target = try? coordinator?.replyTarget() ?? nil, target.sessionId == id {
                dropTarget = (id, target.callsign ?? target.projectLabel)
            } else {
                dropTarget = (id, id)
            }
        case .launch, .dictation:
            dropTarget = nil
        }
    }

    /// A dragged image with no file behind it, written somewhere durable.
    ///
    /// Content-hashed rather than timestamped: dropping the same screenshot
    /// twice is one chip and one file, and a session that reads the path
    /// later finds the bytes it was told about. Beside the audio archive,
    /// under app support — a temp dir would be swept out from under a
    /// session that had not read it yet.
    static func persistDroppedImage(_ data: Data, ext: String) -> String? {
        let dir = QueueStore.supportDirectory.appendingPathComponent("dropped",
                                                                     isDirectory: true)
        try? PrivateStorage.createDirectory(at: dir)
        let digest = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }
            .joined().prefix(16)
        let url = dir.appendingPathComponent("drop-\(digest).\(ext)")
        if FileManager.default.fileExists(atPath: url.path) { return url.path }
        do {
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            Permissions.log("drop: write failed — \(error)")
            return nil
        }
    }

    /// The badge, from the same predicate a keypress uses.
    func waitingNow() -> Int { (try? coordinator?.waitingCount()) ?? 0 }
}
